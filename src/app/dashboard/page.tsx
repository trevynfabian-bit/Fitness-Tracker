import { redirect } from "next/navigation";

import { SignOutButton } from "@/components/auth/sign-out-button";
import { Alert } from "@/components/ui/alert";
import { createClient } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

type MetricDefinitionRow = {
  key: string;
  display_name: string;
  default_aggregation: string;
  user_id: string | null;
  canonical_unit_id: string;
};

type UnitRow = {
  id: string;
  key: string;
};

export default async function DashboardPage() {
  const supabase = await createClient();

  // Defence in depth: middleware already gates this path, but a Server
  // Component must never assume the middleware ran.
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    redirect("/login");
  }

  // Two plain queries rather than a PostgREST embed: the registry is small and
  // this keeps the read to the simplest possible request shape.
  const [definitionsResult, unitsResult] = await Promise.all([
    supabase
      .from("metric_definitions")
      .select("key, display_name, default_aggregation, user_id, canonical_unit_id")
      .order("key", { ascending: true }),
    supabase.from("units").select("id, key"),
  ]);

  const error = definitionsResult.error ?? unitsResult.error;
  const definitions = (definitionsResult.data ?? []) as MetricDefinitionRow[];
  const unitKeyById = new Map(
    ((unitsResult.data ?? []) as UnitRow[]).map((unit) => [unit.id, unit.key]),
  );

  return (
    <main className="mx-auto w-full max-w-3xl px-6 py-12">
      <header className="flex items-start justify-between gap-4">
        <div>
          <h1 className="text-2xl font-semibold tracking-tight">Dashboard</h1>
          <p className="mt-1 text-sm text-muted-foreground">
            Signed in as {user.email}
          </p>
        </div>
        <SignOutButton />
      </header>

      <section className="mt-10">
        <h2 className="text-sm font-medium uppercase tracking-wide text-muted-foreground">
          Metric registry
        </h2>
        <p className="mt-1 text-sm text-muted-foreground">
          Read through the anon key under row level security. System definitions
          are shared; anything you define is visible only to you.
        </p>

        {error ? (
          <Alert tone="error" className="mt-4">
            Could not load the metric registry: {error.message}
          </Alert>
        ) : (
          <div className="mt-4 overflow-x-auto rounded-lg border border-border">
            <table className="w-full text-sm">
              <thead className="bg-muted text-left text-muted-foreground">
                <tr>
                  <th className="px-3 py-2 font-medium">Key</th>
                  <th className="px-3 py-2 font-medium">Name</th>
                  <th className="px-3 py-2 font-medium">Unit</th>
                  <th className="px-3 py-2 font-medium">Aggregation</th>
                  <th className="px-3 py-2 font-medium">Scope</th>
                </tr>
              </thead>
              <tbody>
                {definitions.map((definition) => (
                  <tr key={definition.key} className="border-t border-border">
                    <td className="px-3 py-2 font-mono text-xs">{definition.key}</td>
                    <td className="px-3 py-2">{definition.display_name}</td>
                    <td className="px-3 py-2">{unitKeyById.get(definition.canonical_unit_id) ?? "—"}</td>
                    <td className="px-3 py-2">{definition.default_aggregation}</td>
                    <td className="px-3 py-2 text-muted-foreground">
                      {definition.user_id === null ? "system" : "yours"}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </section>

      <section className="mt-10">
        <Alert tone="info">
          No health data has been imported. Import is Phase 3; nothing in this
          application fabricates measurements.
        </Alert>
      </section>
    </main>
  );
}
