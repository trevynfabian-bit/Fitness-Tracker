import { redirect } from "next/navigation";

import { Alert } from "@/components/ui/alert";
import { Card, CardTitle } from "@/components/ui/card";
import { createClient } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

type MetricDefinitionRow = {
  key: string;
  display_name: string;
  default_aggregation: string;
  user_id: string | null;
  canonical_unit_id: string;
};

type UnitRow = { id: string; key: string };

/**
 * Account and registry. The metric registry lived on the dashboard while the
 * dashboard had nothing else to show; it is reference data, not training
 * history, so it belongs here now that the dashboard reads real data.
 */
export default async function SettingsPage() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect("/login");

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
    <main className="mx-auto w-full max-w-5xl px-6 py-10">
      <header>
        <h1 className="text-2xl font-semibold tracking-tight">Settings</h1>
        <p className="mt-1 text-sm text-muted-foreground">
          Account and reference data.
        </p>
      </header>

      <Card className="mt-6">
        <CardTitle>Account</CardTitle>
        <dl className="mt-3 grid gap-2 text-sm sm:grid-cols-2">
          <div>
            <dt className="text-muted-foreground">Email</dt>
            <dd>{user.email}</dd>
          </div>
          <div>
            <dt className="text-muted-foreground">User id</dt>
            <dd className="font-mono text-xs">{user.id}</dd>
          </div>
        </dl>
      </Card>

      <section className="mt-6">
        <h2 className="text-sm font-medium uppercase tracking-wide text-muted-foreground">
          Metric registry
        </h2>
        <p className="mt-1 text-sm text-muted-foreground">
          Read through the anon key under row level security. System definitions are shared;
          anything you define is visible only to you.
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
                    <td className="px-3 py-2">
                      {unitKeyById.get(definition.canonical_unit_id) ?? "—"}
                    </td>
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
    </main>
  );
}
