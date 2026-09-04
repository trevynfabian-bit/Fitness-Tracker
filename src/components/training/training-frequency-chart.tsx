"use client";

import {
  Bar,
  BarChart,
  CartesianGrid,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from "recharts";

import { TooltipBox } from "@/components/training/chart-tooltip";
import { formatAxisDate, formatCount, formatLocalDate } from "@/lib/read-model/format";
import type { TrainingWeek } from "@/lib/read-model/training";

/**
 * Workouts per ISO week.
 *
 * A week with no workouts is a real zero here: the user did not train. That is
 * the one place in this product where a zero-filled bar is honest, and it is
 * why frequency and volume are two charts rather than one — volume has no
 * equivalent zero (see VolumeTrendChart).
 */
export function TrainingFrequencyChart({ weeks }: { weeks: TrainingWeek[] }) {
  const trained = weeks.filter((week) => week.workoutCount > 0).length;

  return (
    <div>
      <div className="h-56 w-full">
        <ResponsiveContainer width="100%" height="100%">
          <BarChart data={weeks} margin={{ top: 4, right: 8, bottom: 4, left: 0 }}>
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
              allowDecimals={false}
              width={28}
              tickLine={false}
              axisLine={false}
              tick={{ fontSize: 11, fill: "hsl(var(--muted-foreground))" }}
            />
            <Tooltip
              cursor={{ fill: "hsl(var(--muted))" }}
              content={({ active, payload }) => {
                if (!active || !payload?.length) return null;
                const week = payload[0]?.payload as TrainingWeek | undefined;
                if (!week) return null;
                return (
                  <TooltipBox
                    label={`Week of ${formatLocalDate(week.weekStart)}`}
                    rows={[
                      { name: "Workouts", value: formatCount(week.workoutCount) },
                      { name: "Sets", value: formatCount(week.setCount) },
                    ]}
                  />
                );
              }}
            />
            <Bar
              dataKey="workoutCount"
              name="Workouts"
              fill="hsl(var(--chart-1))"
              radius={[4, 4, 0, 0]}
              maxBarSize={28}
            />
          </BarChart>
        </ResponsiveContainer>
      </div>
      <p className="mt-2 text-xs text-muted-foreground">
        Trained in {trained} of the last {weeks.length} weeks.
      </p>
    </div>
  );
}

export function TrainingFrequencyTable({ weeks }: { weeks: TrainingWeek[] }) {
  return (
    <table className="w-full text-left text-xs">
      <thead className="text-muted-foreground">
        <tr>
          <th className="py-1 pr-4 font-medium">Week of</th>
          <th className="py-1 pr-4 font-medium">Workouts</th>
          <th className="py-1 font-medium">Sets</th>
        </tr>
      </thead>
      <tbody>
        {weeks.map((week) => (
          <tr key={week.weekStart} className="border-t border-border">
            <td className="py-1 pr-4">{formatLocalDate(week.weekStart)}</td>
            <td className="py-1 pr-4 tabular-nums">{formatCount(week.workoutCount)}</td>
            <td className="py-1 tabular-nums">{formatCount(week.setCount)}</td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}
