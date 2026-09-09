import Link from "next/link";
import { redirect } from "next/navigation";

import { TrainingEmptyState } from "@/components/training/empty-state";
import { Pagination } from "@/components/training/pagination";
import { Alert } from "@/components/ui/alert";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import {
  formatCount,
  formatLocalDate,
  formatVolumeKg,
  formatWeightKg,
} from "@/lib/read-model/format";
import {
  EXERCISE_PAGE_SIZE,
  PROGRESSION_KIND_LABEL,
  getExercisePage,
} from "@/lib/read-model/training";
import { createClient } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

function first(value: string | string[] | undefined): string | undefined {
  return Array.isArray(value) ? value[0] : value;
}

export default async function ExercisesPage({
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
  const search = (first(params.q) ?? "").trim();

  const result = await getExercisePage(supabase, {
    limit: EXERCISE_PAGE_SIZE,
    offset,
    search: search || null,
  });

  return (
    <main className="mx-auto w-full max-w-5xl px-6 py-10">
      <header>
        <h1 className="text-2xl font-semibold tracking-tight">Exercises</h1>
        <p className="mt-1 text-sm text-muted-foreground">
          Every exercise you have actually performed, most recent first. Names come from the
          exercise registry, not from the raw text in the file.
        </p>
      </header>

      <form method="get" className="mt-6 flex flex-wrap items-end gap-3">
        <div className="min-w-[14rem] flex-1">
          <Label htmlFor="q">Search exercises</Label>
          <Input id="q" name="q" defaultValue={search} placeholder="Bench press" className="mt-1" />
        </div>
        <Button type="submit" variant="outline" size="sm">
          Apply
        </Button>
      </form>

      {result.error !== null ? (
        <Alert tone="error" className="mt-6">
          Could not load your exercises: {result.error}
        </Alert>
      ) : result.data.exercises.length === 0 ? (
        <div className="mt-6">
          {search ? (
            <Alert tone="info">No exercise matches “{search}”.</Alert>
          ) : (
            <TrainingEmptyState
              title="No exercises yet"
              description="Exercises appear here once training data has been imported. Each one is resolved to a registry definition, so the same movement recorded under different names in different files reads as one exercise."
            />
          )}
        </div>
      ) : (
        <div className="mt-6">
          <ul className="divide-y divide-border rounded-lg border border-border">
            {result.data.exercises.map((exercise) => (
              <li key={exercise.exerciseDefinitionId}>
                <Link
                  href={`/exercises/${exercise.exerciseDefinitionId}`}
                  className="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1 px-4 py-3 hover:bg-muted"
                >
                  <span className="min-w-0">
                    <span className="block truncate text-sm font-medium">
                      {exercise.displayName}
                    </span>
                    <span className="mt-0.5 flex items-center gap-2 text-xs text-muted-foreground">
                      <Badge>{PROGRESSION_KIND_LABEL[exercise.progressionKind]}</Badge>
                      last performed {formatLocalDate(exercise.lastPerformed)}
                    </span>
                  </span>
                  <span className="text-xs tabular-nums text-muted-foreground">
                    {formatCount(exercise.sessionCount)} sessions ·{" "}
                    {formatCount(exercise.setCount)} sets
                    {exercise.volumeSets > 0
                      ? ` · ${formatVolumeKg(exercise.totalVolumeKg)}`
                      : ""}
                    {exercise.topWeightKg !== null
                      ? ` · top ${formatWeightKg(exercise.topWeightKg)}`
                      : ""}
                  </span>
                </Link>
              </li>
            ))}
          </ul>
          <Pagination
            basePath="/exercises"
            query={{ q: search || undefined }}
            offset={result.data.offset}
            limit={result.data.limit}
            totalCount={result.data.totalCount}
            hasPrevious={result.data.hasPrevious}
            hasNext={result.data.hasNext}
            noun="exercises"
          />
        </div>
      )}
    </main>
  );
}
