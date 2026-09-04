import { NextResponse } from "next/server";

import { createServiceClient } from "@/lib/supabase/service";
import { getWorkerEnv } from "@/lib/import/server-env";
import { drainJobs } from "@/lib/import/worker";

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
 */
export async function POST(request: Request) {
  const provided = request.headers.get("x-worker-secret");
  if (!provided || provided !== getWorkerEnv().IMPORT_WORKER_SECRET) {
    return NextResponse.json({ error: "unauthorised" }, { status: 401 });
  }

  const db = createServiceClient();
  const outcomes = await drainJobs(db);

  return NextResponse.json({
    batches: outcomes.length,
    outcomes,
    failed: outcomes.filter((o) => o.state === "failed"),
  });
}
