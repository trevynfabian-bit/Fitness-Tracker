import { NextResponse } from "next/server";
import { z } from "zod";

import { recordMeasurements } from "@/lib/manual/entry";
import { createClient } from "@/lib/supabase/server";
import { createServiceClient } from "@/lib/supabase/service";

/**
 * Record one or more measurements by hand (Phase 6).
 *
 * The body says what was measured; it never says who measured it. The user id
 * comes from the authenticated session, so a caller cannot record a
 * measurement against another account, and the elevated connection this then
 * uses is scoped by that id.
 *
 * A correction is the same request with supersedesNaturalKey set. The route
 * checks the caller owns that observation before it will record anything
 * against it — RLS makes the check honest, because a key belonging to someone
 * else simply is not there.
 */

const measurementSchema = z.object({
  metricKey: z.string().min(1).max(100),
  value: z.string().min(1).max(50),
  unit: z.string().min(1).max(20),
  measuredAt: z.string().min(10).max(40),
  qualifier: z.string().max(100).nullish(),
  supersedesNaturalKey: z.string().length(64).nullish(),
});

const bodySchema = z.object({
  measurements: z.array(measurementSchema).min(1).max(20),
});

export async function POST(request: Request) {
  const supabase = await createClient();
  const { data: auth } = await supabase.auth.getUser();
  if (!auth.user) return NextResponse.json({ error: "unauthenticated" }, { status: 401 });

  const parsed = bodySchema.safeParse(await request.json());
  if (!parsed.success) {
    return NextResponse.json({ error: "invalid request", issues: parsed.error.issues }, { status: 400 });
  }

  // Only a metric the registry marks as manually recordable. Without this a
  // caller could type a value for a derived aggregate — training volume, say —
  // and create a second, unreconcilable source of truth for a figure the
  // rollup already computes from canonical data.
  const requestedKeys = [...new Set(parsed.data.measurements.map((m) => m.metricKey.trim()))];
  const { data: recordable, error: registryError } = await supabase
    .from("metric_definitions")
    .select("key")
    .in("key", requestedKeys)
    .eq("manual_entry", true)
    .eq("is_active", true);
  if (registryError) {
    return NextResponse.json({ error: `metric registry: ${registryError.message}` }, { status: 400 });
  }
  const allowed = new Set((recordable ?? []).map((row) => row.key as string));
  const refused = requestedKeys.filter((key) => !allowed.has(key));
  if (refused.length > 0) {
    return NextResponse.json(
      {
        error: "these metrics cannot be recorded by hand",
        metrics: refused,
      },
      { status: 422 },
    );
  }

  // A correction must name something the caller actually has. Read through the
  // user's own session so ownership is established by row level security
  // rather than by a filter this route has to remember to write.
  const superseded = parsed.data.measurements
    .map((m) => m.supersedesNaturalKey)
    .filter((key): key is string => Boolean(key));

  if (superseded.length > 0) {
    const { data: targets, error } = await supabase
      .from("v_metrics")
      .select("natural_key")
      .in("natural_key", superseded);
    if (error) {
      return NextResponse.json({ error: `correction target: ${error.message}` }, { status: 400 });
    }
    const found = new Set((targets ?? []).map((t) => t.natural_key as string));
    const missing = superseded.filter((key) => !found.has(key));
    if (missing.length > 0) {
      return NextResponse.json(
        { error: "the measurement being corrected does not exist in your account", missing },
        { status: 404 },
      );
    }
  }

  try {
    const result = await recordMeasurements(
      createServiceClient(),
      auth.user.id,
      parsed.data.measurements,
    );
    if (result.invalid > 0 || result.errors.length > 0) {
      // The raw records are written and keep their normalize_error, so the
      // entry is recoverable: fixing the cause and re-normalizing needs no
      // re-entry. But the caller is told plainly that nothing landed.
      return NextResponse.json(
        { error: "the measurement could not be normalized", ...result },
        { status: 422 },
      );
    }
    return NextResponse.json(result, { status: 201 });
  } catch (cause) {
    const message = cause instanceof Error ? cause.message : String(cause);
    return NextResponse.json({ error: message }, { status: 400 });
  }
}
