import { redirect } from "next/navigation";

import { TrainingEmptyState } from "@/components/training/empty-state";
import { Pagination } from "@/components/training/pagination";
import { WorkoutList } from "@/components/training/workout-list";
import { Alert } from "@/components/ui/alert";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { HISTORY_PAGE_SIZE, getWorkoutPage } from "@/lib/read-model/training";
import { createClient } from "@/lib/supabase/server";

export const dynamic = "force-dynamic";

const DATE = /^\d{4}-\d{2}-\d{2}$/;

function first(value: string | string[] | undefined): string | undefined {
  return Array.isArray(value) ? value[0] : value;
}

export default async function HistoryPage({
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
  const fromRaw = (first(params.from) ?? "").trim();
  const toRaw = (first(params.to) ?? "").trim();
  const from = DATE.test(fromRaw) ? fromRaw : null;
  const to = DATE.test(toRaw) ? toRaw : null;

  // The page fetches exactly one page. A lifetime of workouts is never loaded
  // into the browser: the window and its total both come from the database.
  const result = await getWorkoutPage(supabase, {
    limit: HISTORY_PAGE_SIZE,
    offset,
    from,
    to,
    search: search || null,
  });

  const filtered = Boolean(search || from || to);

  return (
    <main className="mx-auto w-full max-w-5xl px-6 py-10">
      <header>
        <h1 className="text-2xl font-semibold tracking-tight">Workout history</h1>
        <p className="mt-1 text-sm text-muted-foreground">
          Every imported session, newest first.
        </p>
      </header>

      <form method="get" className="mt-6 flex flex-wrap items-end gap-3">
        <div className="min-w-[12rem] flex-1">
          <Label htmlFor="q">Search titles</Label>
          <Input id="q" name="q" defaultValue={search} placeholder="Push day" className="mt-1" />
        </div>
        <div>
          <Label htmlFor="from">From</Label>
          <Input id="from" name="from" type="date" defaultValue={from ?? ""} className="mt-1" />
        </div>
        <div>
          <Label htmlFor="to">To</Label>
          <Input id="to" name="to" type="date" defaultValue={to ?? ""} className="mt-1" />
        </div>
        <Button type="submit" variant="outline" size="sm">
          Apply
        </Button>
      </form>

      {result.error !== null ? (
        <Alert tone="error" className="mt-6">
          Could not load your workout history: {result.error}
        </Alert>
      ) : result.data.workouts.length === 0 ? (
        <div className="mt-6">
          {filtered ? (
            <Alert tone="info">
              No workout matches this filter. Clear the search or widen the date range.
            </Alert>
          ) : (
            <TrainingEmptyState />
          )}
        </div>
      ) : (
        <div className="mt-6">
          <WorkoutList workouts={result.data.workouts} />
          <Pagination
            basePath="/history"
            query={{ q: search || undefined, from: from ?? undefined, to: to ?? undefined }}
            offset={result.data.offset}
            limit={result.data.limit}
            totalCount={result.data.totalCount}
            hasPrevious={result.data.hasPrevious}
            hasNext={result.data.hasNext}
          />
        </div>
      )}
    </main>
  );
}
