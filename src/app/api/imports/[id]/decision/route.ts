import { NextResponse } from "next/server";
import { z } from "zod";

import { daysForNaturalKeys, daysForWorkoutIds, enqueueTrainingDays } from "@/lib/analytics/rollup";
import { createClient } from "@/lib/supabase/server";
import { createServiceClient } from "@/lib/supabase/service";

/**
 * The retirement decision (v3 section 4.1).
 *
 *   confirmed        retire exactly the plan's key set
 *   skipped          the append-only fallback: complete the import having
 *                    added and updated, retiring nothing. One click.
 *   cancelled        abandon the import
 *
 * The decision itself is recorded with the USER'S own credentials, through the
 * column-level UPDATE grant that covers decision, decided_at and decided_reason
 * and nothing else. The impact figures and the retirement key set the user was
 * shown are not writable from here, so a confirmation cannot be made to apply
 * to a larger retirement than the one presented.
 *
 * Execution then runs on the elevated connection. Every row it touches still
 * passes the database's own retirement guard: a confirmed, non-blocked,
 * non-stale plan that names that row, and never a manual-origin row (G9).
 */

const bodySchema = z.object({
  planId: z.string().uuid(),
  decision: z.enum(["confirmed", "skipped", "cancelled"]),
  reason: z.string().max(500).optional(),
  /** Required to proceed past an overridable guard: the typed retire count. */
  typedConfirmation: z.string().max(50).optional(),
  overrideGuardId: z.enum(["G4", "G6"]).optional(),
});

export async function POST(request: Request, context: { params: Promise<{ id: string }> }) {
  const { id } = await context.params;
  const supabase = await createClient();
  const { data: auth } = await supabase.auth.getUser();
  if (!auth.user) return NextResponse.json({ error: "unauthenticated" }, { status: 401 });

  const parsed = bodySchema.safeParse(await request.json());
  if (!parsed.success) {
    return NextResponse.json({ error: "invalid request", issues: parsed.error.issues }, { status: 400 });
  }
  const body = parsed.data;

  const { data: plan, error } = await supabase
    .from("reconciliation_plans")
    .select("*")
    .eq("id", body.planId)
    .eq("import_id", id)
    .single();
  if (error || !plan) return NextResponse.json({ error: "plan not found" }, { status: 404 });

  if (body.decision === "confirmed" && plan.verdict === "blocked") {
    // The database refuses this too. Refusing here as well means the user gets
    // an explanation rather than a constraint violation.
    return NextResponse.json(
      {
        error: "this plan is blocked and cannot be confirmed",
        verdict: plan.verdict,
        guards: plan.guard_results,
        appendOnlyAvailable: true,
      },
      { status: 409 },
    );
  }

  if (body.overrideGuardId) {
    if (body.typedConfirmation !== String(plan.retire_count)) {
      return NextResponse.json(
        { error: `type the retire count (${plan.retire_count}) to override ${body.overrideGuardId}` },
        { status: 400 },
      );
    }
    const { error: overrideError } = await supabase.from("retirement_overrides").insert({
      user_id: auth.user.id,
      plan_id: plan.id,
      guard_id: body.overrideGuardId,
      typed_confirmation: body.typedConfirmation,
    });
    if (overrideError) {
      return NextResponse.json({ error: `override: ${overrideError.message}` }, { status: 400 });
    }
  }

  const { error: decisionError } = await supabase
    .from("reconciliation_plans")
    .update({
      decision: body.decision,
      decided_at: new Date().toISOString(),
      decided_reason: body.reason ?? null,
    })
    .eq("id", plan.id);
  if (decisionError) {
    return NextResponse.json({ error: `decision: ${decisionError.message}` }, { status: 400 });
  }

  const service = createServiceClient();

  if (body.decision === "cancelled") {
    await service.from("data_imports").update({ status: "cancelled" }).eq("id", id).eq("user_id", auth.user.id);
    return NextResponse.json({ decision: "cancelled", retired: 0 });
  }

  if (body.decision === "skipped") {
    // Append-only fallback. Nothing is retired; the import simply completes.
    // The normalize stage already enqueued the days this file wrote to; this
    // covers the case where the decision is what finally makes them count.
    await enqueueAffectedDays(service, auth.user.id, plan);
    await service
      .from("data_imports")
      .update({
        status: Number(plan.unchanged_count) >= 0 ? "completed" : "completed",
        records_retired: 0,
        imported_at: new Date().toISOString(),
      })
      .eq("id", id)
      .eq("user_id", auth.user.id);
    return NextResponse.json({ decision: "skipped", retired: 0, appendOnly: true });
  }

  // Confirmed. Retire exactly the persisted key set, never a recomputed one.
  await service.from("data_imports").update({ status: "retiring" }).eq("id", id).eq("user_id", auth.user.id);

  const keys = (plan.retire_natural_keys as string[]) ?? [];
  const { data: retired, error: retireError } = await service
    .from("strength_workouts")
    .update({ retired_at: new Date().toISOString(), retired_by_import_id: id })
    .eq("user_id", auth.user.id)
    .in("natural_key", keys)
    .is("retired_at", null)
    .select("id");

  if (retireError) {
    await service.from("data_imports").update({ status: "failed" }).eq("id", id);
    return NextResponse.json({ error: `retire refused: ${retireError.message}` }, { status: 409 });
  }

  // Retirement changes what the analytics layer may count, on exactly the days
  // the retired workouts sat on. Those days are dirty now (ADR-19). The ids are
  // read back from the UPDATE, so the scope is what was actually retired rather
  // than what the plan proposed.
  await enqueueRetiredDays(service, auth.user.id, (retired ?? []).map((r) => r.id as string));

  await service
    .from("data_imports")
    .update({
      status: "completed",
      records_retired: (retired ?? []).length,
      imported_at: new Date().toISOString(),
    })
    .eq("id", id)
    .eq("user_id", auth.user.id);

  return NextResponse.json({ decision: "confirmed", retired: (retired ?? []).length });
}

/**
 * Analytics enqueue failures must not fail a decision the user already made.
 * Derived metrics are a regenerable leaf; a retirement is not. The scope stays
 * dirty and the next enqueue or rebuild picks it up.
 */
async function enqueueAffectedDays(
  service: ReturnType<typeof createServiceClient>,
  userId: string,
  plan: { retire_natural_keys: unknown },
): Promise<void> {
  try {
    const keys = (plan.retire_natural_keys as string[]) ?? [];
    const dates = await daysForNaturalKeys(service, userId, keys);
    await enqueueTrainingDays(service, userId, dates, "retirement");
  } catch (cause) {
    console.error("rollup enqueue after decision:", cause instanceof Error ? cause.message : cause);
  }
}

async function enqueueRetiredDays(
  service: ReturnType<typeof createServiceClient>,
  userId: string,
  workoutIds: string[],
): Promise<void> {
  try {
    const dates = await daysForWorkoutIds(service, userId, workoutIds);
    await enqueueTrainingDays(service, userId, dates, "retirement");
  } catch (cause) {
    console.error("rollup enqueue after retirement:", cause instanceof Error ? cause.message : cause);
  }
}
