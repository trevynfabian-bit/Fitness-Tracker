import Link from "next/link";

import { Badge } from "@/components/ui/badge";
import {
  formatCount,
  formatDistanceM,
  formatDuration,
  formatRpe,
  formatVolumeKg,
  formatWeightKg,
} from "@/lib/read-model/format";
import type { WorkoutExercise } from "@/lib/read-model/training";

/**
 * One exercise inside a workout.
 *
 * The columns are chosen from the has_* flags the read model derived from the
 * sets themselves, so an exercise recording distance renders distance and an
 * exercise recording load renders load. Nothing here assumes a strength shape,
 * and nothing branches on which vendor produced the file (I-9): a future
 * template that lands duration-only sets renders a duration table without a
 * line of code changing.
 */
export function ExerciseBlock({ exercise }: { exercise: WorkoutExercise }) {
  const columns: { key: string; label: string; render: (setIndex: number) => string }[] = [];

  if (exercise.hasLoad) {
    columns.push({
      key: "weight",
      label: "Weight",
      render: (i) => formatWeightKg(exercise.sets[i]?.weightKg),
    });
  }
  if (exercise.hasReps) {
    columns.push({
      key: "reps",
      label: "Reps",
      render: (i) => formatCount(exercise.sets[i]?.reps ?? null),
    });
  }
  if (exercise.hasDistance) {
    columns.push({
      key: "distance",
      label: "Distance",
      render: (i) => formatDistanceM(exercise.sets[i]?.distanceM),
    });
  }
  if (exercise.hasDuration) {
    columns.push({
      key: "duration",
      label: "Duration",
      render: (i) => formatDuration(exercise.sets[i]?.durationS),
    });
  }
  if (exercise.hasRpe) {
    columns.push({
      key: "rpe",
      label: "RPE",
      render: (i) => formatRpe(exercise.sets[i]?.rpe),
    });
  }
  if (exercise.hasLoad && exercise.hasReps) {
    columns.push({
      key: "volume",
      label: "Volume",
      render: (i) => {
        const set = exercise.sets[i];
        return set && set.weightKg !== null && set.reps !== null
          ? formatVolumeKg(set.volumeKg)
          : "—";
      },
    });
  }

  return (
    <article className="rounded-lg border border-border">
      <header className="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1 border-b border-border px-4 py-3">
        <div className="min-w-0">
          <h3 className="truncate text-sm font-medium">
            <Link href={`/exercises/${exercise.exerciseDefinitionId}`} className="hover:underline">
              {exercise.displayName}
            </Link>
          </h3>
          {exercise.nameRaw && exercise.nameRaw !== exercise.displayName ? (
            <p className="mt-0.5 truncate text-xs text-muted-foreground">
              imported as “{exercise.nameRaw}”
            </p>
          ) : null}
        </div>
        <p className="text-xs tabular-nums text-muted-foreground">
          {formatCount(exercise.setCount)} sets
          {exercise.volumeKg !== null ? ` · ${formatVolumeKg(exercise.volumeKg)}` : ""}
          {exercise.topWeightKg !== null ? ` · top ${formatWeightKg(exercise.topWeightKg)}` : ""}
        </p>
      </header>

      {exercise.sets.length === 0 ? (
        <p className="px-4 py-3 text-xs text-muted-foreground">
          This exercise was recorded with no sets.
        </p>
      ) : columns.length === 0 ? (
        <p className="px-4 py-3 text-xs text-muted-foreground">
          These sets record no load, reps, distance or duration. Only the set count is known.
        </p>
      ) : (
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead className="text-left text-xs text-muted-foreground">
              <tr>
                <th className="px-4 py-2 font-medium">Set</th>
                {columns.map((column) => (
                  <th key={column.key} className="px-4 py-2 font-medium">
                    {column.label}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {exercise.sets.map((set, index) => (
                <tr key={set.id} className="border-t border-border">
                  <td className="px-4 py-2 text-muted-foreground">
                    <span className="tabular-nums">{set.setNumber}</span>
                    {set.setType && set.setType !== "working" ? (
                      <Badge className="ml-2">{set.setType}</Badge>
                    ) : null}
                  </td>
                  {columns.map((column) => (
                    <td key={column.key} className="px-4 py-2 tabular-nums">
                      {column.render(index)}
                    </td>
                  ))}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </article>
  );
}
