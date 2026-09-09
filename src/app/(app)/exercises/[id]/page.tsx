import Link from "next/link";
import { notFound, redirect } from "next/navigation";

import { ChartFrame } from "@/components/training/chart-frame";
import {
  ProgressionChart,
  ProgressionTable,
} from "@/components/training/progression-chart";
import { StatTile } from "@/components/training/stat-tile";
import { Alert } from "@/components/ui/alert";
import { Badge } from "@/components/ui/badge";
import {
  formatCount,
  formatDateSpan,
  formatDistanceM,
  formatDuration,
  formatLocalDate,
  formatVolumeKg,
  formatWeightKg,
} from "@/lib/read-model/format";
import {
  PROGRESSION_KIND_LABEL,
  buildProgressionSeries,
  getExerciseProgression,
  getExerciseSummary,
} from "@/lib/read-model/training";
import { createClient } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export default async function ExerciseDetailPage({
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

  const [summaryResult, sessionsResult] = await Promise.all([
    getExerciseSummary(supabase, id),
    getExerciseProgression(supabase, id),
  ]);

  if (summaryResult.error !== null || sessionsResult.error !== null) {
    return (
      <main className="mx-auto w-full max-w-5xl px-6 py-10">
        <Alert tone="error">
          Could not load this exercise: {summaryResult.error ?? sessionsResult.error}
        </Alert>
      </main>
    );
  }

  // An exercise the signed-in user has never performed reads as not found:
  // RLS returns no sessions for it and the summary lists only performed work.
  const summary = summaryResult.data;
  if (!summary) notFound();

  const sessions = sessionsResult.data;
  const series = buildProgressionSeries(summary.progressionKind, sessions);

  return (
    <main className="mx-auto w-full max-w-5xl px-6 py-10">
      <nav className="text-xs text-muted-foreground">
        <Link href="/exercises" className="underline">
          Exercises
        </Link>
      </nav>

      <header className="mt-3">
        <h1 className="text-2xl font-semibold tracking-tight">{summary.displayName}</h1>
        <p className="mt-1 flex flex-wrap items-center gap-2 text-sm text-muted-foreground">
          <Badge>{PROGRESSION_KIND_LABEL[summary.progressionKind]}</Badge>
          {formatDateSpan(summary.firstPerformed, summary.lastPerformed)}
        </p>
      </header>

      <div className="mt-6 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <StatTile label="Sessions" value={formatCount(summary.sessionCount)} />
        <StatTile label="Sets" value={formatCount(summary.setCount)} />
        <StatTile
          label="Heaviest set"
          value={summary.topWeightKg !== null ? formatWeightKg(summary.topWeightKg) : "—"}
          hint={summary.topWeightKg === null ? "no load recorded" : undefined}
        />
        <StatTile
          label="Total volume"
          value={summary.volumeSets > 0 ? formatVolumeKg(summary.totalVolumeKg) : "—"}
          hint={
            summary.volumeSets > 0
              ? `over ${formatCount(summary.volumeSets)} loaded sets`
              : "not a loaded movement"
          }
        />
      </div>

      <section className="mt-6 grid gap-3 lg:grid-cols-2">
        {series.chartable ? (
          <>
            <ChartFrame
              title={series.metricLabel}
              description={`Per session, oldest first. This exercise's sets record ${PROGRESSION_KIND_LABEL[
                series.kind
              ].toLowerCase()}, so that is what is compared.`}
              table={<ProgressionTable track={series} />}
            >
              <ProgressionChart track={series} />
            </ChartFrame>
            {series.secondary ? (
              <ChartFrame
                title={series.secondary.metricLabel}
                description="Weight × reps summed across the session's loaded sets. Drawn on its own axis rather than sharing one with the heaviest set."
                table={<ProgressionTable track={series.secondary} />}
              >
                <ProgressionChart track={series.secondary} />
              </ChartFrame>
            ) : null}
          </>
        ) : (
          <div className="lg:col-span-2">
            <Alert tone="info">
              No progression is drawn for this exercise. {series.reason}
            </Alert>
          </div>
        )}
      </section>

      <section className="mt-6">
        <h2 className="text-sm font-medium">Sessions</h2>
        {sessions.length === 0 ? (
          <Alert tone="info" className="mt-2">
            This exercise has no recorded sessions.
          </Alert>
        ) : (
          <div className="mt-2 overflow-x-auto rounded-lg border border-border">
            <table className="w-full text-sm">
              <thead className="text-left text-xs text-muted-foreground">
                <tr>
                  <th className="px-4 py-2 font-medium">Date</th>
                  <th className="px-4 py-2 font-medium">Workout</th>
                  <th className="px-4 py-2 font-medium">Sets</th>
                  {summary.progressionKind === "load" ? (
                    <>
                      <th className="px-4 py-2 font-medium">Top set</th>
                      <th className="px-4 py-2 font-medium">Volume</th>
                    </>
                  ) : null}
                  {summary.progressionKind === "distance" ? (
                    <th className="px-4 py-2 font-medium">Distance</th>
                  ) : null}
                  {summary.progressionKind === "duration" ? (
                    <th className="px-4 py-2 font-medium">Duration</th>
                  ) : null}
                  {summary.progressionKind === "reps" ? (
                    <th className="px-4 py-2 font-medium">Reps</th>
                  ) : null}
                </tr>
              </thead>
              <tbody>
                {[...sessions].reverse().map((session) => (
                  <tr key={session.workoutId} className="border-t border-border">
                    <td className="px-4 py-2">
                      <Link href={`/history/${session.workoutId}`} className="hover:underline">
                        {formatLocalDate(session.localDate)}
                      </Link>
                    </td>
                    <td className="px-4 py-2 text-muted-foreground">
                      {session.workoutTitle?.trim() || "Untitled workout"}
                    </td>
                    <td className="px-4 py-2 tabular-nums">{formatCount(session.setCount)}</td>
                    {summary.progressionKind === "load" ? (
                      <>
                        <td className="px-4 py-2 tabular-nums">
                          {session.bestSetWeight !== null
                            ? `${formatWeightKg(session.bestSetWeight)}${
                                session.bestSetReps !== null
                                  ? ` × ${session.bestSetReps}`
                                  : ""
                              }`
                            : "—"}
                        </td>
                        <td className="px-4 py-2 tabular-nums">
                          {session.volumeSets > 0
                            ? formatVolumeKg(session.totalVolumeKg)
                            : "—"}
                        </td>
                      </>
                    ) : null}
                    {summary.progressionKind === "distance" ? (
                      <td className="px-4 py-2 tabular-nums">
                        {formatDistanceM(session.totalDistanceM)}
                      </td>
                    ) : null}
                    {summary.progressionKind === "duration" ? (
                      <td className="px-4 py-2 tabular-nums">
                        {formatDuration(session.totalDurationS)}
                      </td>
                    ) : null}
                    {summary.progressionKind === "reps" ? (
                      <td className="px-4 py-2 tabular-nums">
                        {session.totalReps !== null ? formatCount(session.totalReps) : "—"}
                      </td>
                    ) : null}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </section>
    </main>
  );
}
