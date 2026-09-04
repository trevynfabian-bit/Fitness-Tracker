import Link from "next/link";
import { redirect } from "next/navigation";

import { ReconciliationPanel, type Plan } from "@/components/import/reconciliation-panel";
import { Alert } from "@/components/ui/alert";
import { createClient } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

/** Progress, the reconciliation decision, and the import summary. */
export default async function ImportDetailPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await createClient();
  const { data: auth } = await supabase.auth.getUser();
  if (!auth.user) redirect("/login");

  const { data: record } = await supabase.from("data_imports").select("*").eq("id", id).single();
  if (!record) redirect("/import");

  const [jobs, plans, workouts, rawCount, invalid] = await Promise.all([
    supabase.from("import_jobs").select("stage, state, attempts, last_error").eq("import_id", id).order("created_at"),
    supabase.from("reconciliation_plans").select("*").eq("import_id", id).order("computed_at", { ascending: false }),
    supabase.from("v_strength_workouts").select("id, local_date, title").eq("import_id", id).order("local_date"),
    supabase.from("raw_records").select("id", { count: "exact", head: true }).eq("import_id", id),
    supabase.from("raw_records").select("row_number, normalize_error").eq("import_id", id).eq("normalize_status", "invalid").limit(10),
  ]);

  const pending = (plans.data ?? []).find((p) => p.decision === null) as Plan | undefined;

  return (
    <main className="mx-auto w-full max-w-3xl px-6 py-12">
      <header className="flex items-baseline justify-between gap-4">
        <div>
          <h1 className="text-2xl font-semibold tracking-tight">{record.file_name}</h1>
          <p className="mt-1 text-sm text-muted-foreground">
            {record.source_key} · {record.template} · {record.import_mode} · status {record.status}
          </p>
        </div>
        <Link href="/import" className="text-sm underline">All imports</Link>
      </header>

      <section className="mt-8">
        <h2 className="text-sm font-medium uppercase tracking-wide text-muted-foreground">Progress</h2>
        <dl className="mt-2 grid grid-cols-2 gap-2 text-sm sm:grid-cols-4">
          {[
            ["Rows", `${record.rows_ingested ?? 0} / ${record.rows_total ?? 0}`],
            ["Raw records", rawCount.count ?? 0],
            ["Added", record.records_added ?? 0],
            ["Updated", record.records_updated ?? 0],
            ["Unchanged", record.duplicates_skipped ?? 0],
            ["Invalid", record.records_invalid ?? 0],
            ["Retired", record.records_retired ?? 0],
            ["Workouts", (workouts.data ?? []).length],
          ].map(([label, value]) => (
            <div key={String(label)} className="rounded-md border border-border p-2">
              <dt className="text-xs text-muted-foreground">{label}</dt>
              <dd className="font-mono text-base">{value}</dd>
            </div>
          ))}
        </dl>
        <ul className="mt-3 space-y-1 text-xs text-muted-foreground">
          {(jobs.data ?? []).map((j, index) => (
            <li key={index}>
              {j.stage}: {j.state}
              {j.last_error ? ` — ${j.last_error}` : ""}
            </li>
          ))}
        </ul>
      </section>

      {pending ? (
        <div className="mt-8">
          <ReconciliationPanel importId={id} plan={pending} />
        </div>
      ) : null}

      {(invalid.data ?? []).length ? (
        <section className="mt-8">
          <Alert tone="error">
            {record.records_invalid} rows could not be normalized. They remain in the raw layer, so a
            mapping fix plus a re-normalize needs no re-upload.
          </Alert>
          <ul className="mt-2 space-y-1 font-mono text-xs">
            {(invalid.data ?? []).map((r) => (
              <li key={r.row_number}>row {r.row_number}: {r.normalize_error}</li>
            ))}
          </ul>
        </section>
      ) : null}

      <section className="mt-8">
        <h2 className="text-sm font-medium uppercase tracking-wide text-muted-foreground">
          Workouts from this import
        </h2>
        <ul className="mt-2 divide-y divide-border rounded-md border border-border text-sm">
          {(workouts.data ?? []).map((w) => (
            <li key={w.id} className="flex justify-between gap-4 px-3 py-2">
              <span>{w.title}</span>
              <span className="font-mono text-xs text-muted-foreground">{w.local_date}</span>
            </li>
          ))}
          {(workouts.data ?? []).length === 0 ? (
            <li className="px-3 py-2 text-muted-foreground">Nothing imported yet.</li>
          ) : null}
        </ul>
      </section>
    </main>
  );
}
