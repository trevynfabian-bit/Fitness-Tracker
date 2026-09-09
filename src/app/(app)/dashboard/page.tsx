import Link from "next/link";
import { redirect } from "next/navigation";

import { ChartFrame } from "@/components/training/chart-frame";
import { TrainingEmptyState } from "@/components/training/empty-state";
import { StatTile } from "@/components/training/stat-tile";
import {
  TrainingFrequencyChart,
  TrainingFrequencyTable,
} from "@/components/training/training-frequency-chart";
import {
  VolumeTrendChart,
  VolumeTrendTable,
} from "@/components/training/volume-trend-chart";
import { WorkoutList } from "@/components/training/workout-list";
import { Alert } from "@/components/ui/alert";
import {
  formatCount,
  formatDateSpan,
  formatVolumeKg,
} from "@/lib/read-model/format";
import {
  DASHBOARD_WEEKS,
  getTrainingOverview,
  getWeeklySeries,
  getWorkoutPage,
  RECENT_WORKOUT_COUNT,
  volumeSeriesIsChartable,
} from "@/lib/read-model/training";
import { createClient } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

export default async function DashboardPage() {
  const supabase = await createClient();

  // Defence in depth: middleware and the group layout both gate this path, but
  // a Server Component must never assume either ran.
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  // Three reads, in parallel, all through the read model. Every number below
  // comes from one of them; nothing on this page recomputes an aggregate.
  const [overviewResult, weeksResult, recentResult] = await Promise.all([
    getTrainingOverview(supabase),
    getWeeklySeries(supabase, DASHBOARD_WEEKS),
    getWorkoutPage(supabase, { limit: RECENT_WORKOUT_COUNT }),
  ]);

  if (
    overviewResult.error !== null ||
    weeksResult.error !== null ||
    recentResult.error !== null
  ) {
    const error = overviewResult.error ?? weeksResult.error ?? recentResult.error;
    return (
      <main className="mx-auto w-full max-w-5xl px-6 py-10">
        <h1 className="text-2xl font-semibold tracking-tight">Dashboard</h1>
        <Alert tone="error" className="mt-6">
          Could not load your training data: {error}
        </Alert>
      </main>
    );
  }

  const overview = overviewResult.data;
  const weeks = weeksResult.data;
  const recent = recentResult.data;

  if (overview.isEmpty) {
    return (
      <main className="mx-auto w-full max-w-5xl px-6 py-10">
        <header>
          <h1 className="text-2xl font-semibold tracking-tight">Dashboard</h1>
          <p className="mt-1 text-sm text-muted-foreground">
            Your training history, built from imported records.
          </p>
        </header>
        <div className="mt-8">
          <TrainingEmptyState />
        </div>
      </main>
    );
  }

  const hasVolume = overview.volumeSets > 0;

  return (
    <main className="mx-auto w-full max-w-5xl px-6 py-10">
      <header className="flex flex-wrap items-baseline justify-between gap-3">
        <div>
          <h1 className="text-2xl font-semibold tracking-tight">Dashboard</h1>
          <p className="mt-1 text-sm text-muted-foreground">
            {formatDateSpan(overview.firstWorkoutDate, overview.lastWorkoutDate)}
          </p>
        </div>
        <Link href="/history" className="text-sm underline">
          Full history
        </Link>
      </header>

      <section className="mt-8" aria-labelledby="overview-heading">
        <h2 id="overview-heading" className="sr-only">
          Overview
        </h2>
        <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
          <StatTile
            label="Workouts"
            value={formatCount(overview.totalWorkouts)}
            hint={`${formatCount(overview.workoutsLast28Days)} in the last 28 days of data`}
          />
          <StatTile
            label="Sets"
            value={formatCount(overview.totalSets)}
            hint={
              overview.nonVolumeSets > 0
                ? `${formatCount(overview.nonVolumeSets)} without a load or rep count`
                : "all carry a load and a rep count"
            }
          />
          <StatTile
            label="Exercises"
            value={formatCount(overview.distinctExercises)}
            hint={`${formatCount(overview.totalExerciseSlots)} performed instances`}
          />
          <StatTile
            label="Total volume"
            value={hasVolume ? formatVolumeKg(overview.totalVolumeKg) : "—"}
            hint={
              hasVolume
                ? `weight × reps over ${formatCount(overview.volumeSets)} loaded sets`
                : "no set records both a load and a rep count"
            }
          />
        </div>
      </section>

      <section className="mt-6 grid gap-3 lg:grid-cols-2" aria-labelledby="trends-heading">
        <h2 id="trends-heading" className="sr-only">
          Trends
        </h2>
        <ChartFrame
          title="Training frequency"
          description={`Workouts per week over the last ${weeks.length} weeks of your data. A week without training is a real zero.`}
          table={<TrainingFrequencyTable weeks={weeks} />}
        >
          <TrainingFrequencyChart weeks={weeks} />
        </ChartFrame>

        <ChartFrame
          title="Volume trend"
          description={`Weekly training volume over the last ${weeks.length} weeks of your data.`}
          table={volumeSeriesIsChartable(weeks) ? <VolumeTrendTable weeks={weeks} /> : undefined}
        >
          {volumeSeriesIsChartable(weeks) ? (
            <VolumeTrendChart weeks={weeks} />
          ) : (
            <p className="py-10 text-center text-sm text-muted-foreground">
              Fewer than two weeks in this window recorded a set with both a load and a rep
              count, so there is no volume trend to draw. Nothing is charted rather than
              plotting a flat line at zero.
            </p>
          )}
        </ChartFrame>
      </section>

      <section className="mt-6" aria-labelledby="recent-heading">
        <div className="flex items-baseline justify-between gap-4">
          <h2 id="recent-heading" className="text-sm font-medium">
            Recent activity
          </h2>
          <Link href="/history" className="text-xs text-muted-foreground underline">
            See all {formatCount(recent.totalCount)}
          </Link>
        </div>
        <div className="mt-2">
          <WorkoutList workouts={recent.workouts} />
        </div>
      </section>
    </main>
  );
}
