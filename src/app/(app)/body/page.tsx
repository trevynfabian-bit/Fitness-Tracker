import { redirect } from "next/navigation";

import { MeasurementForm } from "@/components/body/measurement-form";
import { MeasurementList } from "@/components/body/measurement-list";
import { Alert } from "@/components/ui/alert";
import { Card, CardTitle } from "@/components/ui/card";
import { Pagination } from "@/components/training/pagination";
import { getMeasurableMetrics, getMeasurements, MEASUREMENT_PAGE_SIZE } from "@/lib/read-model/body";
import { createClient } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

function first(value: string | string[] | undefined): string | undefined {
  return Array.isArray(value) ? value[0] : value;
}

export default async function BodyPage({
  searchParams,
}: {
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const params = await searchParams;
  const offsetParam = Number.parseInt(first(params.offset) ?? "0", 10);
  const offset = Number.isFinite(offsetParam) && offsetParam > 0 ? offsetParam : 0;

  const [metricsResult, pageResult] = await Promise.all([
    getMeasurableMetrics(supabase),
    getMeasurements(supabase, { limit: MEASUREMENT_PAGE_SIZE, offset }),
  ]);

  if (metricsResult.error !== null || pageResult.error !== null) {
    return (
      <main className="mx-auto w-full max-w-5xl px-6 py-10">
        <h1 className="text-2xl font-semibold tracking-tight">Body</h1>
        <Alert tone="error" className="mt-6">
          Could not load your measurements: {metricsResult.error ?? pageResult.error}
        </Alert>
      </main>
    );
  }

  const metrics = metricsResult.data;
  const page = pageResult.data;

  return (
    <main className="mx-auto w-full max-w-5xl px-6 py-10">
      <header>
        <h1 className="text-2xl font-semibold tracking-tight">Body</h1>
        <p className="mt-1 text-sm text-muted-foreground">
          Measurements you record by hand. Each one becomes a record in the same import
          pipeline an exported file goes through, so nothing here is a shortcut around
          your history.
        </p>
      </header>

      <Card className="mt-6">
        <CardTitle>Record a measurement</CardTitle>
        <div className="mt-4">
          <MeasurementForm metrics={metrics} />
        </div>
      </Card>

      <section className="mt-6">
        <h2 className="text-sm font-medium">Recorded measurements</h2>
        {page.measurements.length === 0 ? (
          <Alert tone="info" className="mt-2">
            Nothing recorded yet. What you enter above appears here, and stays correctable.
          </Alert>
        ) : (
          <div className="mt-2">
            <MeasurementList measurements={page.measurements} metrics={metrics} />
            <Pagination
              basePath="/body"
              offset={page.offset}
              limit={page.limit}
              totalCount={page.totalCount}
              hasPrevious={page.hasPrevious}
              hasNext={page.hasNext}
              noun="measurements"
            />
          </div>
        )}
      </section>
    </main>
  );
}
