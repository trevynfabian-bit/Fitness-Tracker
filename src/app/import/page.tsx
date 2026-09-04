import Link from "next/link";
import { redirect } from "next/navigation";

import { ImportWizard } from "@/components/import/import-wizard";
import { createClient } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

export default async function ImportPage() {
  const supabase = await createClient();
  const { data: auth } = await supabase.auth.getUser();
  if (!auth.user) redirect("/login");

  const { data: recent } = await supabase
    .from("data_imports")
    .select("id, file_name, status, imported_at, template, source_key")
    .order("created_at", { ascending: false })
    .limit(10);

  return (
    <main className="mx-auto w-full max-w-3xl px-6 py-12">
      <header className="flex items-baseline justify-between gap-4">
        <div>
          <h1 className="text-2xl font-semibold tracking-tight">Import</h1>
          <p className="mt-1 text-sm text-muted-foreground">
            Upload a structured export. The engine profiles it, matches a profile, and shows you
            exactly what will happen before anything is written.
          </p>
        </div>
        <Link href="/dashboard" className="text-sm underline">Dashboard</Link>
      </header>

      <div className="mt-8">
        <ImportWizard />
      </div>

      {recent?.length ? (
        <section className="mt-12">
          <h2 className="text-sm font-medium uppercase tracking-wide text-muted-foreground">Recent imports</h2>
          <ul className="mt-2 divide-y divide-border rounded-md border border-border text-sm">
            {recent.map((r) => (
              <li key={r.id} className="flex items-center justify-between gap-4 px-3 py-2">
                <Link href={`/import/${r.id}`} className="underline">{r.file_name}</Link>
                <span className="text-muted-foreground">{r.source_key} · {r.template} · {r.status}</span>
              </li>
            ))}
          </ul>
        </section>
      ) : null}
    </main>
  );
}
