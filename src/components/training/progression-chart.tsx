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
  formatDistanceM,
  formatDuration,
  formatLocalDate,
  formatWeightKg,
} from "@/lib/read-model/format";
import type { ProgressionTrack, ProgressionUnit } from "@/lib/read-model/training";

function formatValue(value: number, unit: ProgressionUnit): string {
  switch (unit) {
    case "kg":
      return formatWeightKg(value);
    case "m":
      return formatDistanceM(value);
    case "s":
      return formatDuration(value);
    case "reps":
      return `${formatCount(value)} reps`;
  }
}

/**
 * One measurement, one axis, over sessions.
 *
 * There is deliberately no second y scale here. When an exercise supports two
 * comparisons (heaviest set and session volume), they are drawn as two charts
 * on the same x, not as two scales sharing one frame.
 */
export function ProgressionChart({ track }: { track: ProgressionTrack }) {
  return (
    <div className="h-56 w-full">
      <ResponsiveContainer width="100%" height="100%">
        <LineChart data={track.points} margin={{ top: 4, right: 8, bottom: 4, left: 0 }}>
          <CartesianGrid vertical={false} stroke="hsl(var(--chart-grid))" strokeDasharray="2 4" />
          <XAxis
            dataKey="date"
            tickFormatter={formatAxisDate}
            tickLine={false}
            axisLine={false}
            tick={{ fontSize: 11, fill: "hsl(var(--muted-foreground))" }}
            minTickGap={20}
          />
          <YAxis
            width={44}
            tickLine={false}
            axisLine={false}
            tick={{ fontSize: 11, fill: "hsl(var(--muted-foreground))" }}
            domain={["auto", "auto"]}
          />
          <Tooltip
            cursor={{ stroke: "hsl(var(--chart-grid))", strokeWidth: 1 }}
            content={({ active, payload }) => {
              if (!active || !payload?.length) return null;
              const point = payload[0]?.payload as { date: string; value: number } | undefined;
              if (!point) return null;
              return (
                <TooltipBox
                  label={formatLocalDate(point.date)}
                  rows={[
                    { name: track.metricLabel, value: formatValue(point.value, track.unit) },
                  ]}
                />
              );
            }}
          />
          <Line
            type="monotone"
            dataKey="value"
            name={track.metricLabel}
            stroke="hsl(var(--chart-1))"
            strokeWidth={2}
            dot={{ r: 3, fill: "hsl(var(--chart-1))", strokeWidth: 0 }}
            activeDot={{ r: 5, strokeWidth: 2, stroke: "hsl(var(--card))" }}
            connectNulls={false}
          />
        </LineChart>
      </ResponsiveContainer>
    </div>
  );
}

export function ProgressionTable({ track }: { track: ProgressionTrack }) {
  return (
    <table className="w-full text-left text-xs">
      <thead className="text-muted-foreground">
        <tr>
          <th className="py-1 pr-4 font-medium">Date</th>
          <th className="py-1 font-medium">{track.metricLabel}</th>
        </tr>
      </thead>
      <tbody>
        {track.points.map((point) => (
          <tr key={point.date} className="border-t border-border">
            <td className="py-1 pr-4">{formatLocalDate(point.date)}</td>
            <td className="py-1 tabular-nums">{formatValue(point.value, track.unit)}</td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}
