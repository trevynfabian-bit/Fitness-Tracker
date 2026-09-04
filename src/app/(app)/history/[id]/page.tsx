import Link from "next/link";
import { notFound, redirect } from "next/navigation";

import { ExerciseBlock } from "@/components/training/exercise-block";
import { StatTile } from "@/components/training/stat-tile";
import { Alert } from "@/components/ui/alert";
import {
  formatCount,
  formatDuration,
  formatLocalDate,
  formatVolumeKg,
} from "@/lib/read-model/format";
import { getWorkoutDetail } from "@/lib/read-model/training";
import { createClient } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export default async function WorkoutDetailPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { id } = await params;
  if (!UUID.test(id)) notFound();

  const result = await getWorkoutDetail(supabase, id);
  if (result.error !== null) {
    return (
      <main className="mx-auto w-full max-w-5xl px-6 py-10">
        <Alert tone="error">Could not load this workout: {result.error}</Alert>
      </main>
    );
  }

  // RLS returns nothing for another user's workout, which is indistinguishable
  // from a workout that does not exist. That is the correct answer to give: a
  // 404 leaks nothing about whether the id belongs to somebody else.
  const workout = result.data;
  if (!workout) notFound();

  return (
    <main className="mx-auto w-full max-w-5xl px-6 py-10">
      <nav className="text-xs text-muted-foreground">
        <Link href="/history" className="underline">
          Workout history
        </Link>
      </nav>

      <header className="mt-3">
        <h1 className="text-2xl font-semibold tracking-tight">
          {workout.title?.trim() || "Untitled workout"}
        </h1>
        <p className="mt-1 text-sm text-muted-foreground">
          {formatLocalDate(workout.localDate, "long")}
          {workout.durationS !== null ? ` · ${formatDuration(workout.durationS)}` : ""} ·{" "}
          imported from {workout.sourceKey}
        </p>
      </header>

      <div className="mt-6 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <StatTile label="Exercises" value={formatCount(workout.exercises.length)} />
        <StatTile label="Sets" value={formatCount(workout.setCount)} />
        <StatTile
          label="Reps"
          value={workout.totalReps === null ? "—" : formatCount(workout.totalReps)}
        />
        <StatTile
          label="Volume"
          value={workout.volumeSets > 0 ? formatVolumeKg(workout.totalVolumeKg) : "—"}
          hint={
            workout.volumeSets > 0
              ? `over ${formatCount(workout.volumeSets)} loaded sets`
              : "no set records both a load and a rep count"
          }
        />
      </div>

      <section className="mt-6 space-y-3">
        {workout.exercises.length === 0 ? (
          <Alert tone="info">This workout was imported with no exercises.</Alert>
        ) : (
          workout.exercises.map((exercise) => (
            <ExerciseBlock key={exercise.id} exercise={exercise} />
          ))
        )}
      </section>
    </main>
  );
}
