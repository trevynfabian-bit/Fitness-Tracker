import { NextResponse } from "next/server";

import { createClient } from "@/lib/supabase/server";
import { parseCsv } from "@/lib/import/csv";
import {
  computeDerivedFields,
  DERIVED_KEY,
  normalize,
  normalizeAliasLikeDatabase,
  NORMALIZE_VERSION,
} from "@/lib/import/normalize";
import { loadRegistrySnapshotFor } from "@/lib/import/registry";
import { mappingSpecSchema } from "@/lib/import/types";

/**
 * Preview and validation (v2 section 5.2).
 *
 * Runs the real mapping over a sample and reports exactly what confirmation
 * would do: rows that insert, rows that update, rows that are unchanged
 * duplicates, invalid rows with their reasons, and every identity that does not
 * yet resolve to a registry row.
 *
 * Nothing is written. The file is read with the user's own credentials, so the
 * storage policy is exercised rather than bypassed.
 */

const PREVIEW_ROW_LIMIT = 300;

export async function POST(_request: Request, context: { params: Promise<{ id: string }> }) {
  const { id } = await context.params;
  const supabase = await createClient();
  const { data: auth } = await supabase.auth.getUser();
  if (!auth.user) return NextResponse.json({ error: "unauthenticated" }, { status: 401 });

  const { data: record, error } = await supabase.from("data_imports").select("*").eq("id", id).single();
  if (error || !record) return NextResponse.json({ error: "import not found" }, { status: 404 });

  const spec = mappingSpecSchema.safeParse(record.mapping_spec_snapshot);
  if (!spec.success) {
    return NextResponse.json({ error: "this import has no usable mapping spec" }, { status: 409 });
  }

  const { data: file, error: downloadError } = await supabase.storage
    .from("imports")
    .download(record.storage_path as string);
  if (downloadError || !file) {
    return NextResponse.json({ error: `file not readable: ${downloadError?.message}` }, { status: 409 });
  }

  const parsed = parseCsv(await file.text());
  const derived = computeDerivedFields(spec.data, parsed.rows);
  const registry = await loadRegistrySnapshotFor(supabase, auth.user.id);

  const sample = parsed.rows.slice(0, PREVIEW_ROW_LIMIT);
  const unresolvedExercises = new Map<string, number>();
  const invalidRows: { rowNumber: number; reason: string }[] = [];
  const workoutKeys = new Set<string>();
  const setKeys = new Set<string>();

  for (const [index, row] of sample.entries()) {
    try {
      const result = normalize(
        {
          id: index + 1,
          userId: auth.user.id,
          sourceKey: record.source_key as string,
          payload: { ...row, [DERIVED_KEY]: derived[index] ?? {} },
        },
        spec.data,
        registry,
        NORMALIZE_VERSION,
      );
      for (const w of result.workouts) workoutKeys.add(w.naturalKey);
      for (const s of result.sets) setKeys.add(s.naturalKey);
    } catch (cause) {
      const message = cause instanceof Error ? cause.message : String(cause);
      const unresolved = message.match(/exercise "([^"]+)"/);
      if (unresolved?.[1]) {
        unresolvedExercises.set(unresolved[1], (unresolvedExercises.get(unresolved[1]) ?? 0) + 1);
      } else {
        invalidRows.push({ rowNumber: index + 1, reason: message });
      }
    }
  }

  // Which of the keys the sample produced already exist, so the preview can say
  // insert vs update rather than guessing.
  const { data: existing } = await supabase
    .from("v_strength_sets")
    .select("natural_key")
    .in("natural_key", [...setKeys].slice(0, 500));
  const existingKeys = new Set((existing ?? []).map((r) => r.natural_key as string));

  return NextResponse.json({
    importId: id,
    template: record.template,
    sourceKey: record.source_key,
    importMode: record.import_mode,
    rowsInFile: parsed.rows.length,
    rowsPreviewed: sample.length,
    parseErrors: parsed.errors,
    projected: {
      workouts: workoutKeys.size,
      sets: setKeys.size,
      willInsert: [...setKeys].filter((k) => !existingKeys.has(k)).length,
      willUpdateOrSkip: [...setKeys].filter((k) => existingKeys.has(k)).length,
      invalid: invalidRows.length,
    },
    invalidRows: invalidRows.slice(0, 20),
    // v2 section 6.4: a fuzzy match is only ever a proposal, and no alias is
    // written without a human confirming it once.
    unresolvedExercises: [...unresolvedExercises.entries()].map(([name, count]) => ({
      rawName: name,
      normalized: normalizeAliasLikeDatabase(name),
      proposedKey: normalizeAliasLikeDatabase(name).replace(/\s+/g, "_").slice(0, 60),
      occurrences: count,
    })),
  });
}
