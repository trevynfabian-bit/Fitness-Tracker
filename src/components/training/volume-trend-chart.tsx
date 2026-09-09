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
import {
  formatAxisDate,
  formatCount,
  formatLocalDate,
  formatVolumeKg,
} from "@/lib/read-model/format";
import type { TrainingWeek } from "@/lib/read-model/training";

/**
 * Weekly training volume, defined as the sum of weight × reps over the sets
 * that carry BOTH a load and a rep count.
 *
 * The aggregation is stated on the chart itself, because "volume" is not a
 * self-evident quantity. Sets without a load (a plank, a carry, a distance
 * interval) contribute nothing and are excluded rather than counted as zero,
 * and a week with no such set is a NULL, drawn as a gap. connectNulls is off
 * for exactly that reason: a line drawn across a week with no observation is a
 * claim the data does not make.
 */
export function VolumeTrendChart({ weeks }: { weeks: TrainingWeek[] }) {
  const observed = weeks.filter((week) => week.volumeKg !== null).length;
  const gaps = weeks.length - observed;

  return (
    <div>
      <div className="h-56 w-full">
        <ResponsiveContainer width="100%" height="100%">
          <LineChart data={weeks} margin={{ top: 4, right: 8, bottom: 4, left: 0 }}>
            <CartesianGrid
              vertical={false}
              stroke="hsl(var(--chart-grid))"
              strokeDasharray="2 4"
            />
            <XAxis
              dataKey="weekStart"
              tickFormatter={formatAxisDate}
              tickLine={false}
              axisLine={false}
              tick={{ fontSize: 11, fill: "hsl(var(--muted-foreground))" }}
              minTickGap={16}
            />
            <YAxis
              width={44}
              tickLine={false}
              axisLine={false}
              tick={{ fontSize: 11, fill: "hsl(var(--muted-foreground))" }}
              tickFormatter={(value: number) =>
                value >= 10_000 ? `${Math.round(value / 1000)}t` : `${Math.round(value)}`
              }
            />
            <Tooltip
              cursor={{ stroke: "hsl(var(--chart-grid))", strokeWidth: 1 }}
              content={({ active, payload }) => {
                if (!active || !payload?.length) return null;
                const week = payload[0]?.payload as TrainingWeek | undefined;
                if (!week) return null;
                return (
                  <TooltipBox
                    label={`Week of ${formatLocalDate(week.weekStart)}`}
                    rows={[
                      {
                        name: "Volume",
                        value:
                          week.volumeKg === null
                            ? "No loaded sets recorded"
                            : formatVolumeKg(week.volumeKg),
                      },
                      { name: "Loaded sets", value: formatCount(week.volumeSets) },
                    ]}
                  />
                );
              }}
            />
            <Line
              type="monotone"
              dataKey="volumeKg"
              name="Volume"
              stroke="hsl(var(--chart-1))"
              strokeWidth={2}
              dot={{ r: 3, fill: "hsl(var(--chart-1))", strokeWidth: 0 }}
              activeDot={{ r: 5, strokeWidth: 2, stroke: "hsl(var(--card))" }}
              connectNulls={false}
            />
          </LineChart>
        </ResponsiveContainer>
      </div>
      <p className="mt-2 text-xs text-muted-foreground">
        Volume is weight × reps, summed over sets recording both. {observed} of {weeks.length}{" "}
        weeks recorded a loaded set
        {gaps > 0 ? "; the rest are drawn as gaps, not as zero." : "."}
      </p>
    </div>
  );
}

export function VolumeTrendTable({ weeks }: { weeks: TrainingWeek[] }) {
  return (
    <table className="w-full text-left text-xs">
      <thead className="text-muted-foreground">
        <tr>
          <th className="py-1 pr-4 font-medium">Week of</th>
          <th className="py-1 pr-4 font-medium">Volume</th>
          <th className="py-1 font-medium">Loaded sets</th>
        </tr>
      </thead>
      <tbody>
        {weeks.map((week) => (
          <tr key={week.weekStart} className="border-t border-border">
            <td className="py-1 pr-4">{formatLocalDate(week.weekStart)}</td>
            <td className="py-1 pr-4 tabular-nums">
              {week.volumeKg === null ? "no observation" : formatVolumeKg(week.volumeKg)}
            </td>
            <td className="py-1 tabular-nums">{formatCount(week.volumeSets)}</td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}
