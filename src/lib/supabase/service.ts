import { createClient } from "@supabase/supabase-js";

import { clientEnv } from "@/lib/env";
import { getWorkerEnv } from "@/lib/import/server-env";

/**
 * The elevated connection. Used by exactly two things: the import worker, which
 * is the sanctioned canonical write path, and job enqueue, which v2 section 1.1
 * puts in the API layer.
 *
 * Never import this from a client component or from a route that serves user
 * input straight through. Every caller must have already established which user
 * it is acting for and must scope its writes to that user.
 */
export function createServiceClient() {
  return createClient(clientEnv.NEXT_PUBLIC_SUPABASE_URL, getWorkerEnv().SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}
