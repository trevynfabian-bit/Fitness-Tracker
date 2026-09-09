import { NextResponse } from "next/server";
import { z } from "zod";

import { createClient } from "@/lib/supabase/server";
import { createServiceClient } from "@/lib/supabase/service";
import { normalizeAliasLikeDatabase } from "@/lib/import/normalize";

/**
 * Import confirmation.
 *
 * Two things happen here and nothing else. Identities the user confirmed are
 * written to the registry, because I-6 admits no free-text identifier and
 * v2 section 6.4 requires a human to confirm a match once. Then the ingest job
 * is enqueued.
 *
 * Job enqueue uses the elevated connection: v2 section 1.1 puts enqueue in the
 * API layer, and the client role holds SELECT only on import_jobs so it cannot
 * create work for the worker directly.
 */

const bodySchema = z.object({
  importMode: z.enum(["append", "full_snapshot"]).optional(),
  exerciseResolutions: z
    .array(
      z.object({
        rawName: z.string().min(1),
        definitionKey: z.string().regex(/^[a-z0-9]+(_[a-z0-9]+)*$/),
        displayName: z.string().min(1),
      }),
    )
    .default([]),
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

  const { data: record, error } = await supabase.from("data_imports").select("*").eq("id", id).single();
  if (error || !record) return NextResponse.json({ error: "import not found" }, { status: 404 });
  if (record.status !== "draft") {
    return NextResponse.json({ error: `import is already ${record.status}` }, { status: 409 });
  }

  // Registry entries the user confirmed. Written with the user's own
  // credentials as user-owned rows, so the ownership rules apply normally.
  //
  // Deliberately not an upsert: the registry's unique indexes are PARTIAL
  // (system rows and user rows are separate scopes) and one is over an
  // expression, so ON CONFLICT cannot infer them. Read-then-insert is explicit,
  // and registry writes are a handful per import.
  const created: string[] = [];
  for (const resolution of parsed.data.exerciseResolutions) {
    const { data: existingDefinition } = await supabase
      .from("exercise_definitions")
      .select("id")
      .eq("user_id", auth.user.id)
      .eq("key", resolution.definitionKey)
      .maybeSingle();

    let definitionId = existingDefinition?.id as string | undefined;
    if (!definitionId) {
      const { data: inserted, error: defError } = await supabase
        .from("exercise_definitions")
        .insert({
          user_id: auth.user.id,
          key: resolution.definitionKey,
          display_name: resolution.displayName,
        })
        .select("id")
        .single();
      if (defError || !inserted) {
        return NextResponse.json({ error: `registry: ${defError?.message}` }, { status: 400 });
      }
      definitionId = inserted.id as string;
      created.push(resolution.definitionKey);
    }

    const aliasNormalized = normalizeAliasLikeDatabase(resolution.rawName);
    const { data: existingAlias } = await supabase
      .from("exercise_aliases")
      .select("id")
      .eq("user_id", auth.user.id)
      .eq("alias_normalized", aliasNormalized)
      .is("source_key", null)
      .maybeSingle();

    if (!existingAlias) {
      const { error: aliasError } = await supabase.from("exercise_aliases").insert({
        user_id: auth.user.id,
        exercise_definition_id: definitionId,
        alias_normalized: aliasNormalized,
        source_key: null,
      });
      if (aliasError) {
        return NextResponse.json({ error: `alias: ${aliasError.message}` }, { status: 400 });
      }
    }
  }

  const importMode = parsed.data.importMode ?? (record.import_mode as string);

  const service = createServiceClient();
  const { error: modeError } = await service
    .from("data_imports")
    .update({ status: "queued", import_mode: importMode })
    .eq("id", id)
    .eq("user_id", auth.user.id);
  if (modeError) return NextResponse.json({ error: modeError.message }, { status: 400 });

  const { error: jobError } = await service.from("import_jobs").insert({
    user_id: auth.user.id,
    import_id: id,
    stage: "ingest",
    state: "queued",
    cursor: {},
  });
  if (jobError) return NextResponse.json({ error: jobError.message }, { status: 400 });

  return NextResponse.json({ importId: id, status: "queued", importMode, registryEntriesCreated: created });
}
