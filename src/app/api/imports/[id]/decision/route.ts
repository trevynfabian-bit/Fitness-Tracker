import { NextResponse } from "next/server";
import { z } from "zod";

import { daysForNaturalKeys, daysForWorkoutIds, enqueueTrainingDays } from "@/lib/analytics/rollup";
import {
  OVERRIDE_MIN_REASON_LENGTH,
  blockingGuards,
  overrideAvailability,
  type GuardResult,
} from "@/lib/import/reconciliation";
import { createClient } from "@/lib/supabase/server";
import { createServiceClient } from "@/lib/supabase/service";

/**
 * The retirement decision (v3 section 4.1, Phase 5.1).
 *
 *   confirmed        retire exactly the plan's key set
 *   skipped          the append-only fallback: complete the import having
 *                    added and updated, retiring nothing. One click.
 *   cancelled        abandon the import
 *
 * A plan whose guards blocked it can still be confirmed, but only by an owner
 * who explicitly overrides every guard that blocked it. That is Phase 5.1's
 * resolution: G4 is a safety gate, not a prohibition. What the override buys is
 * exactly one thing — permission to proceed past a blocked verdict. It does not
 * relax G9, the persisted key set, plan immutability, or anything else.
 *
 * THE CLIENT CANNOT TALK ITS WAY PAST THIS. It does not choose which guard to
 * override: the blocking guards are read from the persisted plan. Every
 * override requirement is re-enforced by the database when the override row is
 * written, and again when the decision is recorded, so a caller that skips this
 * route entirely gains nothing.
 *
 * The decision itself is recorded with the USER'S own credentials, through the
 * column-level UPDATE grant that covers decision, decided_at and decided_reason
 * and nothing else. The impact figures and the retirement key set the user was
 * shown are not writable from here, so a confirmation cannot be made to apply
 * to a larger retirement than the one presented.
 *
 * Execution then runs on the elevated connection. Every row it touches still
 * passes the database's own retirement guard.
 */

const bodySchema = z.object({
  planId: z.string().uuid(),
  decision: z.enum(["confirmed", "skipped", "cancelled"]),
  reason: z.string().max(500).optional(),
  /**
   * Present only when the user is deliberately overriding a blocked plan.
   * Its absence on a blocked plan is a refusal, not a default.
   */
  override: z
    .object({
      acknowledged: z.literal(true),
      typedConfirmation: z.string().max(50),
      reason: z.string().min(OVERRIDE_MIN_REASON_LENGTH).max(500),
    })
    .optional(),
});

type ServiceClient = ReturnType<typeof createServiceClient>;

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

  // Read through the user's own session: RLS is what establishes ownership, so
  // a plan belonging to somebody else is simply not found.
  const { data: plan, error } = await supabase
    .from("reconciliation_plans")
    .select("*")
    .eq("id", body.planId)
    .eq("import_id", id)
    .single();
  if (error || !plan) return NextResponse.json({ error: "plan not found" }, { status: 404 });

  // Idempotency, first line. A decision is final once recorded, so a repeat
  // submission reports what was decided rather than attempting it again. The
  // retired count is read from the import, which is what actually happened,
  // not from the plan, which is what was proposed.
  if (plan.decision !== null) {
    return NextResponse.json(await alreadyDecided(supabase, id, plan.decision as string));
  }

  const guards = (plan.guard_results as GuardResult[]) ?? [];
  const blocking = blockingGuards(guards);
  const availability = overrideAvailability(guards);

  if (body.decision === "confirmed" && blocking.length > 0) {
    if (!availability.available) {
      // A non-overridable guard blocked this plan. G9 is the case this exists
      // for, and the database refuses it independently: an override row cannot
      // be written for a guard outside the overridable set at all.
      return NextResponse.json(
        {
          error: "this plan is blocked by a guard that has no override",
          verdict: plan.verdict,
          blockedBy: blocking.map((g) => g.id),
          nonOverridable: availability.nonOverridable,
          guards: plan.guard_results,
          appendOnlyAvailable: true,
        },
        { status: 409 },
      );
    }

    if (!body.override) {
      // Gate A. Automatic retirement stays blocked: confirming a blocked plan
      // without explicit override intent is refused, and the safe fallback is
      // named in the response so the caller is not left guessing.
      return NextResponse.json(
        {
          error:
            "this plan is blocked and cannot be confirmed without an explicit override of every guard that blocked it",
          verdict: plan.verdict,
          blockedBy: blocking.map((g) => g.id),
          overridableBy: availability.overridable,
          guards: plan.guard_results,
          overrideRequired: true,
          appendOnlyAvailable: true,
        },
        { status: 409 },
      );
    }

    if (body.override.typedConfirmation.trim() !== String(plan.retire_count)) {
      return NextResponse.json(
        {
          error: `type the retire count (${plan.retire_count}) to confirm the override`,
        },
        { status: 400 },
      );
    }

    // One audit row per blocking guard, written with the user's own
    // credentials so attribution comes from the authenticated session and
    // never from the request body. The database validates each one and derives
    // the guard evidence from the plan itself.
    for (const guard of blocking) {
      const { error: overrideError } = await supabase.from("retirement_overrides").insert({
        user_id: auth.user.id,
        plan_id: plan.id,
        guard_id: guard.id,
        typed_confirmation: body.override.typedConfirmation.trim(),
        acknowledged: true,
        reason: body.override.reason,
      });
      // A duplicate is a retry, not a second override: the unique index on
      // (plan_id, guard_id) is the idempotency key.
      if (overrideError && overrideError.code !== "23505") {
        return NextResponse.json(
          { error: `override refused: ${overrideError.message}` },
          { status: 400 },
        );
      }
    }
  }

  if (body.decision === "confirmed" && blocking.length === 0 && body.override) {
    // Recording an override against a plan nothing blocked would leave an
    // audit row implying a safety gate was bypassed when none fired.
    return NextResponse.json(
      { error: "no guard blocked this plan, so there is nothing to override" },
      { status: 400 },
    );
  }

  // Compare and swap: only an undecided plan may be decided. Two concurrent
  // submissions therefore produce one decision, and the loser reports it
  // rather than retrying the retirement.
  const decidedReason =
    body.decision === "confirmed" && body.override ? body.override.reason : body.reason ?? null;

  const { data: decided, error: decisionError } = await supabase
    .from("reconciliation_plans")
    .update({
      decision: body.decision,
      decided_at: new Date().toISOString(),
      decided_reason: decidedReason,
    })
    .eq("id", plan.id)
    .is("decision", null)
    .select("id");

  if (decisionError) {
    return NextResponse.json({ error: `decision: ${decisionError.message}` }, { status: 409 });
  }
  if ((decided ?? []).length === 0) {
    // Another submission of the same decision won the race. Report its outcome
    // rather than executing the retirement a second time.
    const { data: current } = await supabase
      .from("reconciliation_plans")
      .select("decision")
      .eq("id", plan.id)
      .single();
    return NextResponse.json(await alreadyDecided(supabase, id, (current?.decision as string) ?? null));
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
        status: "completed",
        records_retired: 0,
        imported_at: new Date().toISOString(),
      })
      .eq("id", id)
      .eq("user_id", auth.user.id);
    return NextResponse.json({ decision: "skipped", retired: 0, appendOnly: true });
  }

  // Confirmed. Retire exactly the persisted key set, never a recomputed one.
  // This is the same execution path whether the plan passed its guards or was
  // overridden: Phase 5.1 adds no second retirement implementation.
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

  return NextResponse.json({
    decision: "confirmed",
    retired: (retired ?? []).length,
    overridden: blocking.length > 0,
    overriddenGuards: blocking.map((g) => g.id),
  });
}

/** The outcome of a decision that was already taken, for a repeated request. */
async function alreadyDecided(
  supabase: Awaited<ReturnType<typeof createClient>>,
  importId: string,
  decision: string | null,
) {
  const { data } = await supabase
    .from("data_imports")
    .select("records_retired")
    .eq("id", importId)
    .single();
  return {
    decision,
    retired: Number(data?.records_retired ?? 0),
    alreadyDecided: true,
  };
}

/**
 * Analytics enqueue failures must not fail a decision the user already made.
 * Derived metrics are a regenerable leaf; a retirement is not. The scope stays
 * dirty and the next enqueue or rebuild picks it up.
 */
async function enqueueAffectedDays(
  service: ServiceClient,
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
  service: ServiceClient,
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
