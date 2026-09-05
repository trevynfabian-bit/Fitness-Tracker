import { NextResponse } from "next/server";

import { createServiceClient } from "@/lib/supabase/service";
import { getWorkerEnv } from "@/lib/import/server-env";
import { drainJobs } from "@/lib/import/worker";
import { drainRollupQueue } from "@/lib/analytics/rollup";

/**
 * The worker's invocation surface (ADR-22, D2).
 *
 * A cron tick calls this and it processes checkpointed batches. The worker
 * itself is a pure function over (job, batch); this route only decides that it
 * is time to run one, so lifting the worker into a long-running container later
 * changes this file and nothing else.
 *
 * Authorised by a shared secret, never by a user session: it acts for whichever
 * user owns the queued job.
 *
 * Two queues drain here, in order. Import jobs first, because they are what
 * makes canonical rows and therefore what makes analytics scopes dirty; the
 * rollup queue second, so one tick both imports a file and brings the
 * dashboard up to date. The rollup queue is drained unconditionally rather
 * than only after an import, because a retirement dirties scopes with no
 * import job behind it at all.
 */
export async function POST(request: Request) {
  const provided = request.headers.get("x-worker-secret");
  if (!provided || provided !== getWorkerEnv().IMPORT_WORKER_SECRET) {
    return NextResponse.json({ error: "unauthorised" }, { status: 401 });
  }

  const db = createServiceClient();
  const outcomes = await drainJobs(db);
  const rollup = await drainRollupQueue(db);

  return NextResponse.json({
    batches: outcomes.length,
    outcomes,
    failed: outcomes.filter((o) => o.state === "failed"),
    rollup,
  });
}
