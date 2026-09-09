"use client";

import {
  CartesianGrid,
  Line,
  LineChart,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from "recharts";

import { TooltipBox } from "@/components/training/chart-tooltip";
import type { MetricChart, SeriesPoint } from "@/lib/read-model/charts";
import { formatAxisDate, formatLocalDate } from "@/lib/read-model/format";

/**
 * One measured metric over a window.
 *
 * One series, so no legend: the frame's title names it, and identity never
 * depends on hue when there is one hue.
 *
 * connectNulls is off, and that is the whole point of this chart. A metric
 * whose gap_policy is 'null' returns NULL on a day nobody measured, and a line
 * drawn across that day would be asserting a measurement that was never taken.
 * Where the registry says carry_forward, the value is carried and the point is
 * drawn hollow, so a carried value never looks like a measured one.
 */

function formatValue(value: number | null, unit: string): string {
  if (value === null) return "Not recorded";
  const rounded = Math.abs(value) >= 100 ? value.toFixed(0) : value.toFixed(1);
  return `${rounded} ${unit}`;
}

/** Observed points are solid; filled ones are hollow and visibly not measured. */
function PointDot(props: {
  cx?: number;
  cy?: number;
  payload?: SeriesPoint;
}) {
  const { cx, cy, payload } = props;
  if (cx === undefined || cy === undefined || !payload || payload.value === null) return null;
  if (!payload.observed && !payload.filled) return null;
  return payload.observed ? (
    <circle cx={cx} cy={cy} r={3} fill="hsl(var(--chart-1))" />
  ) : (
    <circle
      cx={cx}
      cy={cy}
      r={2.5}
      fill="hsl(var(--card))"
      stroke="hsl(var(--chart-1))"
      strokeWidth={1.5}
    />
  );
}

export function MetricSeriesChart({ chart }: { chart: MetricChart }) {
  const { series, unit, gapPolicy } = chart;
  const observed = series.filter((point) => point.observed).length;
  const filled = series.filter((point) => point.filled).length;

  return (
    <div>
      <div className="h-48 w-full">
        <ResponsiveContainer width="100%" height="100%">
          <LineChart data={series} margin={{ top: 4, right: 8, bottom: 4, left: 0 }}>
            <CartesianGrid
              vertical={false}
              stroke="hsl(var(--chart-grid))"
              strokeDasharray="2 4"
            />
            <XAxis
              dataKey="localDate"
              tickFormatter={formatAxisDate}
              tickLine={false}
              axisLine={false}
              tick={{ fontSize: 11, fill: "hsl(var(--muted-foreground))" }}
              minTickGap={24}
            />
            <YAxis
              width={44}
              // A body metric never starts at zero: a weight axis anchored to
              // zero compresses every real change into a flat line.
              domain={["auto", "auto"]}
              tickLine={false}
              axisLine={false}
              tick={{ fontSize: 11, fill: "hsl(var(--muted-foreground))" }}
              tickFormatter={(value: number) =>
                Math.abs(value) >= 100 ? value.toFixed(0) : value.toFixed(1)
              }
            />
            <Tooltip
              cursor={{ stroke: "hsl(var(--chart-grid))", strokeWidth: 1 }}
              content={({ active, payload }) => {
                if (!active || !payload?.length) return null;
                const point = payload[0]?.payload as SeriesPoint | undefined;
                if (!point) return null;
                return (
                  <TooltipBox
                    label={formatLocalDate(point.localDate)}
                    rows={[
                      { name: chart.displayName, value: formatValue(point.value, unit) },
                      {
                        name: "Source",
                        value: point.observed
                          ? "Measured"
                          : point.filled
                            ? "Carried from the last measurement"
                            : "No measurement",
                      },
                    ]}
                  />
                );
              }}
            />
            <Line
              type="monotone"
              dataKey="value"
              name={chart.displayName}
              stroke="hsl(var(--chart-1))"
              strokeWidth={2}
              dot={<PointDot />}
              activeDot={{ r: 5, strokeWidth: 2, stroke: "hsl(var(--card))" }}
              connectNulls={false}
              isAnimationActive={false}
            />
          </LineChart>
        </ResponsiveContainer>
      </div>
      <p className="mt-2 text-xs text-muted-foreground">
        {observed} of {series.length} days recorded a measurement
        {gapPolicy === "carry_forward" && filled > 0
          ? `; ${filled} carry the previous one forward and are drawn hollow.`
          : gapPolicy === "zero"
            ? "; days with none count as zero."
            : "; the rest are drawn as gaps, not as zero."}
      </p>
    </div>
  );
}

export function MetricSeriesTable({ chart }: { chart: MetricChart }) {
  const rows = chart.series.filter((point) => point.observed);
  return (
    <table className="w-full text-left text-xs">
      <caption className="sr-only">
        {chart.displayName} measurements, in {chart.unit}
      </caption>
      <thead>
        <tr className="text-muted-foreground">
          <th scope="col" className="py-1 pr-4 font-medium">
            Date
          </th>
          <th scope="col" className="py-1 pr-4 text-right font-medium">
            {chart.displayName} ({chart.unit})
          </th>
        </tr>
      </thead>
      <tbody>
        {rows.map((point) => (
          <tr key={point.localDate} className="border-t border-border">
            <td className="py-1 pr-4">{formatLocalDate(point.localDate)}</td>
            <td className="py-1 pr-4 text-right tabular-nums">
              {point.value === null ? "—" : point.value.toFixed(2)}
            </td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}
