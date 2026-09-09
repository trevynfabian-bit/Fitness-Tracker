import { NextResponse } from "next/server";
import { z } from "zod";

import { createClient } from "@/lib/supabase/server";
import { BUILT_IN_PROFILES } from "@/lib/import/profiles";
import { detectProfiles, isDecisive, toCandidate } from "@/lib/import/detection";
import { NORMALIZE_VERSION } from "@/lib/import/normalize";
import { profileRows } from "@/lib/import/profiling";
import { TEMPLATES } from "@/lib/import/types";

/**
 * Create an import and hand back a signed upload URL.
 *
 * The API never receives the file (v2 section 1.2.3). The client profiles the
 * file locally, posts the headers and a sample, and PUTs the bytes straight to
 * private storage.
 */

const bodySchema = z.object({
  fileName: z.string().min(1),
  fileType: z.enum(["csv", "xlsx"]),
  fileBytes: z.number().int().nonnegative(),
  fileSha256: z.string().length(64),
  headers: z.array(z.string()).min(1),
  sampleRows: z.array(z.record(z.string(), z.string())).default([]),
  rowCount: z.number().int().nonnegative(),
  /** Set when the user overrode detection and chose a template by hand. */
  template: z.enum(TEMPLATES).optional(),
});

export async function POST(request: Request) {
  const supabase = await createClient();
  const { data: auth } = await supabase.auth.getUser();
  if (!auth.user) return NextResponse.json({ error: "unauthenticated" }, { status: 401 });

  const parsed = bodySchema.safeParse(await request.json());
  if (!parsed.success) {
    return NextResponse.json({ error: "invalid request", issues: parsed.error.issues }, { status: 400 });
  }
  const body = parsed.data;

  // 4. Import profile detection, over the headers the client profiled.
  const fileProfile = profileRows(body.headers, body.sampleRows);
  const matches = detectProfiles(fileProfile, BUILT_IN_PROFILES.map(toCandidate));
  const decisive = isDecisive(matches);
  const best = matches[0];

  // 5. Template selection where detection is not decisive.
  const chosen = decisive && best ? BUILT_IN_PROFILES.find((p) => p.profile_id === best.profileId) : undefined;
  const template = chosen?.template ?? body.template;
  if (!template) {
    return NextResponse.json(
      {
        error: "detection was not decisive; choose a template",
        matches,
        templates: TEMPLATES,
      },
      { status: 409 },
    );
  }

  // v2 section 5.2: warn on an exact re-upload before any work is done.
  const { data: priorImports } = await supabase
    .from("data_imports")
    .select("id, file_name, imported_at")
    .eq("file_sha256", body.fileSha256)
    .limit(1);
  const duplicateOf = (priorImports ?? [])[0] ?? null;

  const importId = crypto.randomUUID();
  const storagePath = `${auth.user.id}/${importId}/${body.fileName}`;

  const { error: insertError } = await supabase.from("data_imports").insert({
    id: importId,
    user_id: auth.user.id,
    source_key: chosen?.source_key ?? "unknown",
    template,
    storage_path: storagePath,
    file_name: body.fileName,
    file_type: body.fileType,
    file_bytes: body.fileBytes,
    file_sha256: body.fileSha256,
    // Frozen at import time so editing the profile later cannot retroactively
    // change what this import meant (v2 section 3).
    mapping_spec_snapshot: chosen?.mapping_spec ?? {},
    normalize_version: NORMALIZE_VERSION,
    import_mode: chosen?.import_mode ?? "append",
    status: "draft",
    rows_total: body.rowCount,
  });
  if (insertError) {
    return NextResponse.json({ error: insertError.message }, { status: 400 });
  }

  // 2. Direct-to-storage upload. The bytes never touch this process.
  const { data: signed, error: signError } = await supabase.storage
    .from("imports")
    .createSignedUploadUrl(storagePath);
  if (signError) {
    return NextResponse.json({ error: signError.message }, { status: 400 });
  }

  return NextResponse.json({
    importId,
    storagePath,
    upload: { signedUrl: signed.signedUrl, token: signed.token, path: signed.path },
    detection: { decisive, matches, profileId: chosen?.profile_id ?? null, template },
    duplicateOf,
  });
}
