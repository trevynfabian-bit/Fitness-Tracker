import { z } from "zod";

/**
 * Server-only configuration for the worker.
 *
 * Validated lazily, on first use, so importing this module never runs in a
 * browser bundle and the values can never be inlined into client JavaScript.
 *
 * The service role key was deliberately absent from the application through
 * Phases 1 and 2, because nothing in the app was allowed to bypass RLS. Phase 3
 * introduces the one component that must: normalization is the sanctioned
 * canonical write path and the client roles hold SELECT only (I-4, RD-3). It is
 * read here and nowhere else, and only by the worker and by job enqueue.
 */
const schema = z.object({
  SUPABASE_SERVICE_ROLE_KEY: z
    .string()
    .min(1, "SUPABASE_SERVICE_ROLE_KEY is required to run the import worker"),
  IMPORT_WORKER_SECRET: z
    .string()
    .min(1, "IMPORT_WORKER_SECRET is required to authorise worker invocations"),
});

export type WorkerEnv = z.infer<typeof schema>;

let cached: WorkerEnv | null = null;

export function getWorkerEnv(): WorkerEnv {
  if (cached) return cached;
  const parsed = schema.safeParse({
    SUPABASE_SERVICE_ROLE_KEY: process.env.SUPABASE_SERVICE_ROLE_KEY,
    IMPORT_WORKER_SECRET: process.env.IMPORT_WORKER_SECRET,
  });
  if (!parsed.success) {
    throw new Error(
      `Invalid worker environment:\n${parsed.error.issues.map((i) => `  - ${i.path.join(".")}: ${i.message}`).join("\n")}`,
    );
  }
  cached = parsed.data;
  return cached;
}
