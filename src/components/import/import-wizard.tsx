"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";

import { Alert } from "@/components/ui/alert";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { parseCsv } from "@/lib/import/csv";
import { PROFILE_SAMPLE_SIZE } from "@/lib/import/types";

/**
 * The import wizard.
 *
 * The file is parsed and profiled in the browser and PUT straight to private
 * storage with a signed URL. The API never receives the bytes (v2 section 1.2.3).
 */

type Detection = {
  decisive: boolean;
  profileId: string | null;
  template: string | null;
  matches: {
    profileId: string;
    name: string;
    confidence: string;
    similarity: number;
    missingRequiredColumns: string[];
    newColumns: string[];
  }[];
};

type Unresolved = { rawName: string; normalized: string; proposedKey: string; occurrences: number };

type Preview = {
  rowsInFile: number;
  rowsPreviewed: number;
  importMode: string;
  projected: { workouts: number; sets: number; willInsert: number; willUpdateOrSkip: number; invalid: number };
  invalidRows: { rowNumber: number; reason: string }[];
  unresolvedExercises: Unresolved[];
};

async function sha256Hex(buffer: ArrayBuffer): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", buffer);
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export function ImportWizard() {
  const router = useRouter();
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [importId, setImportId] = useState<string | null>(null);
  const [detection, setDetection] = useState<Detection | null>(null);
  const [preview, setPreview] = useState<Preview | null>(null);
  const [template, setTemplate] = useState<string>("");
  const [duplicateOf, setDuplicateOf] = useState<{ file_name: string; imported_at: string } | null>(null);

  async function onFile(file: File) {
    setError(null);
    setBusy("Profiling the file");
    try {
      const buffer = await file.arrayBuffer();
      const text = new TextDecoder().decode(buffer);
      const parsed = parseCsv(text);
      if (parsed.headers.length === 0) throw new Error("no header row found");

      const created = await fetch("/api/imports", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          fileName: file.name,
          fileType: file.name.toLowerCase().endsWith(".csv") ? "csv" : "xlsx",
          fileBytes: file.size,
          fileSha256: await sha256Hex(buffer),
          headers: parsed.headers,
          sampleRows: parsed.rows.slice(0, PROFILE_SAMPLE_SIZE),
          rowCount: parsed.rows.length,
          ...(template ? { template } : {}),
        }),
      });
      const createdBody = await created.json();
      if (!created.ok) {
        setDetection(createdBody.matches ? { decisive: false, profileId: null, template: null, matches: createdBody.matches } : null);
        throw new Error(createdBody.error ?? "could not create the import");
      }

      setImportId(createdBody.importId);
      setDetection(createdBody.detection);
      setDuplicateOf(createdBody.duplicateOf);

      setBusy("Uploading directly to storage");
      const upload = await fetch(createdBody.upload.signedUrl, {
        method: "PUT",
        headers: { "Content-Type": "text/csv", "x-upsert": "true" },
        body: file,
      });
      if (!upload.ok) throw new Error(`upload failed: ${upload.status}`);

      setBusy("Building the preview");
      const previewResponse = await fetch(`/api/imports/${createdBody.importId}/preview`, { method: "POST" });
      const previewBody = await previewResponse.json();
      if (!previewResponse.ok) throw new Error(previewBody.error ?? "preview failed");
      setPreview(previewBody);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : String(cause));
    } finally {
      setBusy(null);
    }
  }

  async function confirm() {
    if (!importId || !preview) return;
    setBusy("Confirming");
    setError(null);
    try {
      const response = await fetch(`/api/imports/${importId}/confirm`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          exerciseResolutions: preview.unresolvedExercises.map((u) => ({
            rawName: u.rawName,
            definitionKey: u.proposedKey,
            displayName: u.rawName,
          })),
        }),
      });
      const body = await response.json();
      if (!response.ok) throw new Error(body.error ?? "confirmation failed");
      router.push(`/import/${importId}`);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : String(cause));
    } finally {
      setBusy(null);
    }
  }

  return (
    <div className="space-y-6">
      <div className="space-y-2">
        <Label htmlFor="file">Export file (CSV)</Label>
        <Input
          id="file"
          type="file"
          accept=".csv,text/csv"
          disabled={busy !== null}
          onChange={(event) => {
            const file = event.target.files?.[0];
            if (file) void onFile(file);
          }}
        />
        <p className="text-xs text-muted-foreground">
          Parsed in your browser and uploaded straight to private storage. The application server
          never receives the file.
        </p>
      </div>

      {detection && !detection.decisive && !importId ? (
        <div className="space-y-2">
          <Label htmlFor="template">Detection was not decisive. Choose a template.</Label>
          <select
            id="template"
            className="h-10 w-full rounded-md border border-input bg-transparent px-3 text-sm"
            value={template}
            onChange={(event) => setTemplate(event.target.value)}
          >
            <option value="">Select…</option>
            {["metrics", "activities", "strength", "labs", "events"].map((t) => (
              <option key={t} value={t}>{t}</option>
            ))}
          </select>
        </div>
      ) : null}

      {busy ? <Alert tone="info">{busy}…</Alert> : null}
      {error ? <Alert tone="error">{error}</Alert> : null}
      {duplicateOf ? (
        <Alert tone="info">
          This exact file was imported before, as {duplicateOf.file_name}. Importing it again is
          safe: identical rows are skipped as duplicates.
        </Alert>
      ) : null}

      {detection?.matches?.length ? (
        <section>
          <h2 className="text-sm font-medium uppercase tracking-wide text-muted-foreground">Detection</h2>
          <ul className="mt-2 space-y-1 text-sm">
            {detection.matches.map((m) => (
              <li key={m.profileId} className="flex justify-between gap-4 border-b border-border py-1">
                <span>{m.name}</span>
                <span className="text-muted-foreground">
                  {m.confidence} · {(m.similarity * 100).toFixed(0)}% similar
                  {m.missingRequiredColumns.length ? ` · missing ${m.missingRequiredColumns.join(", ")}` : ""}
                </span>
              </li>
            ))}
          </ul>
        </section>
      ) : null}

      {preview ? (
        <section className="space-y-4">
          <h2 className="text-sm font-medium uppercase tracking-wide text-muted-foreground">Preview</h2>
          <dl className="grid grid-cols-2 gap-2 text-sm sm:grid-cols-3">
            {[
              ["Rows in file", preview.rowsInFile],
              ["Previewed", preview.rowsPreviewed],
              ["Workouts", preview.projected.workouts],
              ["Sets", preview.projected.sets],
              ["Will insert", preview.projected.willInsert],
              ["Already present", preview.projected.willUpdateOrSkip],
            ].map(([label, value]) => (
              <div key={String(label)} className="rounded-md border border-border p-2">
                <dt className="text-xs text-muted-foreground">{label}</dt>
                <dd className="font-mono text-base">{value}</dd>
              </div>
            ))}
          </dl>

          <Alert tone="info">Import mode: {preview.importMode}</Alert>

          {preview.unresolvedExercises.length ? (
            <div>
              <h3 className="text-sm font-medium">
                {preview.unresolvedExercises.length} exercises need a registry entry
              </h3>
              <p className="mt-1 text-xs text-muted-foreground">
                No identity is ever created silently. Confirming below registers each of these
                once, and the registry recognises them from then on.
              </p>
              <ul className="mt-2 max-h-56 overflow-y-auto rounded-md border border-border text-sm">
                {preview.unresolvedExercises.map((u) => (
                  <li key={u.rawName} className="flex justify-between gap-4 border-b border-border px-3 py-1 last:border-b-0">
                    <span>{u.rawName}</span>
                    <span className="font-mono text-xs text-muted-foreground">{u.proposedKey}</span>
                  </li>
                ))}
              </ul>
            </div>
          ) : null}

          {preview.invalidRows.length ? (
            <Alert tone="error">
              {preview.projected.invalid} rows would be invalid. First: row{" "}
              {preview.invalidRows[0]?.rowNumber} — {preview.invalidRows[0]?.reason}
            </Alert>
          ) : null}

          <Button onClick={() => void confirm()} disabled={busy !== null}>
            Confirm and import
          </Button>
        </section>
      ) : null}
    </div>
  );
}
