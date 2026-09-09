import { NextResponse } from "next/server";

import { createClient } from "@/lib/supabase/server";

/**
 * Progress reporting and the import summary (v2 section 5.2).
 *
 * Read with the user's own credentials throughout, so what this returns is
 * exactly what row level security permits that user to see. The provenance
 * counts at the end are the summary's evidence: every canonical row reachable
 * from a raw record, and every raw record from this import's file.
 */
export async function GET(_request: Request, context: { params: Promise<{ id: string }> }) {
  const { id } = await context.params;
  const supabase = await createClient();
  const { data: auth } = await supabase.auth.getUser();
  if (!auth.user) return NextResponse.json({ error: "unauthenticated" }, { status: 401 });

  const { data: record, error } = await supabase.from("data_imports").select("*").eq("id", id).single();
  if (error || !record) return NextResponse.json({ error: "import not found" }, { status: 404 });

  const [jobs, rawCount, invalidRaw, workouts, plans] = await Promise.all([
    supabase.from("import_jobs").select("stage, state, cursor, attempts, last_error").eq("import_id", id).order("created_at"),
    supabase.from("raw_records").select("id", { count: "exact", head: true }).eq("import_id", id),
    supabase.from("raw_records").select("id, row_number, normalize_error").eq("import_id", id).eq("normalize_status", "invalid").limit(20),
    supabase.from("v_strength_workouts").select("id, natural_key, local_date, title").eq("import_id", id).order("local_date"),
    supabase.from("reconciliation_plans").select("*").eq("import_id", id).order("computed_at", { ascending: false }),
  ]);

  const workoutIds = (workouts.data ?? []).map((w) => w.id as string);
  const [exercises, sets] = await Promise.all([
    workoutIds.length
      ? supabase.from("v_strength_exercises").select("id, workout_id").in("workout_id", workoutIds)
      : Promise.resolve({ data: [], error: null }),
    supabase.from("v_strength_sets").select("id, raw_record_id", { count: "exact" }).eq("user_id", auth.user.id),
  ]);

  return NextResponse.json({
    import: {
      id: record.id,
      status: record.status,
      template: record.template,
      sourceKey: record.source_key,
      importMode: record.import_mode,
      fileName: record.file_name,
      fileSha256: record.file_sha256,
      storagePath: record.storage_path,
      rowsTotal: record.rows_total,
      rowsIngested: record.rows_ingested,
      recordsAdded: record.records_added,
      recordsUpdated: record.records_updated,
      duplicatesSkipped: record.duplicates_skipped,
      recordsInvalid: record.records_invalid,
      recordsRetired: record.records_retired,
      importedAt: record.imported_at,
    },
    progress: {
      jobs: jobs.data ?? [],
      rawRecords: rawCount.count ?? 0,
      percentIngested:
        Number(record.rows_total ?? 0) === 0
          ? 0
          : Math.round((Number(record.rows_ingested ?? 0) / Number(record.rows_total)) * 100),
    },
    summary: {
      workouts: workouts.data ?? [],
      exerciseCount: (exercises.data ?? []).length,
      setCount: (sets.data ?? []).length,
      invalidRows: invalidRaw.data ?? [],
    },
    reconciliation: plans.data ?? [],
  });
}
