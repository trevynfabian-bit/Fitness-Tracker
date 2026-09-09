import { ChartFrame } from "@/components/training/chart-frame";
import {
  MetricSeriesChart,
  MetricSeriesTable,
} from "@/components/body/metric-chart";
import type { MetricChart } from "@/lib/read-model/charts";
import { formatLocalDate } from "@/lib/read-model/format";

/**
 * One metric's card: the headline figure, the change, and the chart — or the
 * reason there is no chart.
 *
 * The refusal is the point. A card that quietly drew a two-point line, or
 * printed a percentage from a single measurement, would be the failure mode
 * this whole layer exists to prevent, so the insufficient case is rendered
 * deliberately rather than treated as an edge.
 */

function formatValue(value: number | null, unit: string): string {
  if (value === null) return "—";
  const rounded = Math.abs(value) >= 100 ? value.toFixed(0) : value.toFixed(1);
  return `${rounded} ${unit}`;
}

function formatChange(chart: MetricChart): string | null {
  const { changeAbsolute, changePercent } = chart.summary;
  if (changeAbsolute === null) return null;
  const sign = changeAbsolute > 0 ? "+" : "";
  const absolute = `${sign}${
    Math.abs(changeAbsolute) >= 100
      ? changeAbsolute.toFixed(0)
      : changeAbsolute.toFixed(1)
  } ${chart.unit}`;
  // Undefined rather than infinite when the baseline is zero, which is what
  // the read model returns and what this must not paper over.
  if (changePercent === null) return absolute;
  return `${absolute} (${sign}${changePercent.toFixed(1)}%)`;
}

export function MetricCard({
  chart,
  rangeLabel,
}: {
  chart: MetricChart;
  rangeLabel: string;
}) {
  const { summary } = chart;
  const change = formatChange(chart);

  const description = chart.chartable
    ? `${summary.observationCount} measurements over ${rangeLabel.toLowerCase()}. ` +
      `Range ${formatValue(summary.minValue, chart.unit)} to ${formatValue(
        summary.maxValue,
        chart.unit,
      )}.`
    : undefined;

  return (
    <div data-testid={`metric-card-${chart.metricKey}`}>
      <ChartFrame
        title={chart.displayName}
        description={description}
        tableCaption="View measurements as a table"
        table={
          chart.chartable ? <MetricSeriesTable chart={chart} /> : undefined
        }
      >
        <div className="flex flex-wrap items-baseline gap-x-4 gap-y-1">
          <p className="text-2xl font-semibold tabular-nums tracking-tight">
            {formatValue(summary.lastValue, chart.unit)}
          </p>
          {summary.lastDate ? (
            <p className="text-xs text-muted-foreground">
              latest, {formatLocalDate(summary.lastDate)}
            </p>
          ) : null}
          {change ? (
            <p className="ml-auto text-xs tabular-nums text-muted-foreground">
              {change} over {rangeLabel.toLowerCase()}
            </p>
          ) : null}
        </div>

        {chart.chartable ? (
          <div className="mt-4">
            <MetricSeriesChart chart={chart} />
          </div>
        ) : (
          <p
            data-testid={`insufficient-${chart.metricKey}`}
            className="mt-3 rounded-md border border-dashed border-border px-3 py-4 text-xs text-muted-foreground"
          >
            {chart.reason}
          </p>
        )}
      </ChartFrame>
    </div>
  );
}
