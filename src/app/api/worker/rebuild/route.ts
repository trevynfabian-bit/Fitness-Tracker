import { NextResponse } from "next/server";
import { z } from "zod";

import { drainRollupQueue } from "@/lib/analytics/rollup";
import { getWorkerEnv } from "@/lib/import/server-env";
import { drainJobs } from "@/lib/import/worker";
import { createServiceClient } from "@/lib/supabase/service";

/**
 * Replay a user's raw layer through normalization.
 *
 * This is the operation the architecture's central claim rests on: canonical
 * rows are reproducible from raw_records, because normalization is a pure
 * function of (raw record, mapping spec, registry, version). Running it is how
 * that claim stops being a claim.
 *
 * Authorised by the worker secret, never by a user session. It is a
 * maintenance operation, it acts for whichever user it is told to, and it is
 * not something a signed-in person can trigger against themselves by accident.
 *
 * The rollup queue is drained afterwards. Replaying the raw layer re-enqueues
 * every day it touched, in both domains, and leaving those scopes pending
 * would end a rebuild with canonical truth restored and the analytics layer
 * still stale — which is the one state a rebuild exists to make impossible.
 */

const bodySchema = z.object({
  userId: z.string().uuid(),
  template: z.enum(["metrics", "activities", "strength", "labs", "events"]).optional(),
});

export async function POST(request: Request) {
  const provided = request.headers.get("x-worker-secret");
  if (!provided || provided !== getWorkerEnv().IMPORT_WORKER_SECRET) {
    return NextResponse.json({ error: "unauthorised" }, { status: 401 });
  }

  const parsed = bodySchema.safeParse(await request.json());
  if (!parsed.success) {
    return NextResponse.json({ error: "invalid request", issues: parsed.error.issues }, { status: 400 });
  }

  const db = createServiceClient();
  const { data: queued, error } = await db.rpc("normalize_rebuild_enqueue", {
    p_user_id: parsed.data.userId,
    p_template: parsed.data.template ?? null,
  });
  if (error) return NextResponse.json({ error: error.message }, { status: 400 });

  const outcomes = await drainJobs(db);
  const rollup = await drainRollupQueue(db);

  return NextResponse.json({
    importsQueued: Number(queued ?? 0),
    batches: outcomes.length,
    failed: outcomes.filter((o) => o.state === "failed"),
    rollup,
  });
}
