import Link from "next/link";

import {
  formatCount,
  formatDuration,
  formatLocalDate,
  formatVolumeKg,
} from "@/lib/read-model/format";
import type { WorkoutSummary } from "@/lib/read-model/training";

/**
 * The one rendering of "a workout in a list". The dashboard's recent activity
 * and the full history page use it unchanged, so a workout reads the same way
 * in both places and its numbers come from the same aggregation.
 */
export function WorkoutList({ workouts }: { workouts: WorkoutSummary[] }) {
  return (
    <ul className="divide-y divide-border rounded-lg border border-border">
      {workouts.map((workout) => (
        <li key={workout.id}>
          <Link
            href={`/history/${workout.id}`}
            className="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1 px-4 py-3 hover:bg-muted"
          >
            <span className="min-w-0">
              <span className="block truncate text-sm font-medium">
                {workout.title?.trim() || "Untitled workout"}
              </span>
              <span className="block text-xs text-muted-foreground">
                {formatLocalDate(workout.localDate)}
                {workout.durationS !== null ? ` · ${formatDuration(workout.durationS)}` : ""}
              </span>
            </span>
            <span className="text-xs tabular-nums text-muted-foreground">
              {formatCount(workout.exerciseCount)} exercises · {formatCount(workout.setCount)} sets
              {workout.volumeSets > 0 ? ` · ${formatVolumeKg(workout.totalVolumeKg)}` : ""}
            </span>
          </Link>
        </li>
      ))}
    </ul>
  );
}
