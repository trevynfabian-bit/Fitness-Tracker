import { redirect } from "next/navigation";

import { MeasurementForm } from "@/components/body/measurement-form";
import { MeasurementList } from "@/components/body/measurement-list";
import { MetricCard } from "@/components/body/metric-card";
import { RangeSelector } from "@/components/body/range-selector";
import { Alert } from "@/components/ui/alert";
import { Card, CardTitle } from "@/components/ui/card";
import { Pagination } from "@/components/training/pagination";
import {
  getBodyCharts,
  parseChartRange,
  RANGE_LABEL,
  toIsoDate,
} from "@/lib/read-model/charts";
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
  const range = parseChartRange(first(params.range));

  const [metricsResult, pageResult, chartsResult] = await Promise.all([
    getMeasurableMetrics(supabase),
    getMeasurements(supabase, { limit: MEASUREMENT_PAGE_SIZE, offset }),
    getBodyCharts(supabase, range, toIsoDate(new Date())),
  ]);

  if (metricsResult.error !== null || pageResult.error !== null || chartsResult.error !== null) {
    return (
      <main className="mx-auto w-full max-w-5xl px-6 py-10">
        <h1 className="text-2xl font-semibold tracking-tight">Body</h1>
        <Alert tone="error" className="mt-6">
          Could not load your measurements:{" "}
          {metricsResult.error ?? pageResult.error ?? chartsResult.error}
        </Alert>
      </main>
    );
  }

  const metrics = metricsResult.data;
  const page = pageResult.data;
  const { charts, empty } = chartsResult.data;
  const rangeLabel = RANGE_LABEL[range];
  const offsetQuery = offset > 0 ? String(offset) : undefined;

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

      <section className="mt-8" aria-labelledby="body-trends">
        <div className="flex flex-wrap items-center justify-between gap-3">
          <h2 id="body-trends" className="text-sm font-medium">
            Trends
          </h2>
          {/* The range control sits above the charts, in one row, and is
              rendered even on an empty account: it is how the page says what
              window you are looking at, which an account with no data still
              needs to know. */}
          <RangeSelector basePath="/body" query={{ offset: offsetQuery }} active={range} />
        </div>

        {empty ? (
          <div data-testid="charts-empty" className="mt-3">
            <Alert tone="info">
              No measurements yet, so there is nothing to chart. Record one below and it will
              appear here as soon as it has been through the pipeline.
            </Alert>
          </div>
        ) : (
          <div className="mt-3 grid gap-4 md:grid-cols-2">
            {charts.map((chart) => (
              <MetricCard key={chart.metricKey} chart={chart} rangeLabel={rangeLabel} />
            ))}
          </div>
        )}
      </section>

      <Card className="mt-8">
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
              query={{ range }}
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
