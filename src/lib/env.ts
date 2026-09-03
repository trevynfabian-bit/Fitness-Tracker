import { z } from "zod";

/**
 * Environment variable validation.
 *
 * Validated once, at module load, so a misconfigured deployment fails at boot
 * with a readable message instead of at the first request with a null pointer.
 *
 * Client variables must be referenced as literal `process.env.NEXT_PUBLIC_*`
 * expressions — Next.js inlines them statically and cannot see a dynamic
 * lookup such as `process.env[name]`.
 *
 * `SKIP_ENV_VALIDATION=1` bypasses validation. It exists for container image
 * builds and lint/typecheck runs that have no runtime configuration. It must
 * never be set on a running deployment.
 */

const skipValidation = process.env.SKIP_ENV_VALIDATION === "1";

const clientSchema = z.object({
  NEXT_PUBLIC_SUPABASE_URL: z
    .string()
    .min(1, "NEXT_PUBLIC_SUPABASE_URL is required")
    .url("NEXT_PUBLIC_SUPABASE_URL must be a valid URL"),
  NEXT_PUBLIC_SUPABASE_ANON_KEY: z
    .string()
    .min(1, "NEXT_PUBLIC_SUPABASE_ANON_KEY is required"),
  NEXT_PUBLIC_SITE_URL: z
    .string()
    .url("NEXT_PUBLIC_SITE_URL must be a valid URL")
    .optional(),
});

const serverSchema = z.object({
  NODE_ENV: z
    .enum(["development", "test", "production"])
    .default("development"),
});

export type ClientEnv = z.infer<typeof clientSchema>;
export type ServerEnv = z.infer<typeof serverSchema>;

function format(prefix: string, error: z.ZodError): string {
  const lines = error.issues.map(
    (issue) => `  - ${issue.path.join(".") || "(root)"}: ${issue.message}`,
  );
  return `${prefix}\n${lines.join("\n")}\n`;
}

/** Exported for unit tests. Validates an arbitrary record. */
export function parseClientEnv(source: Record<string, unknown>): ClientEnv {
  const result = clientSchema.safeParse(source);
  if (!result.success) {
    throw new Error(format("Invalid client environment variables:", result.error));
  }
  return result.data;
}

/** Exported for unit tests. Validates an arbitrary record. */
export function parseServerEnv(source: Record<string, unknown>): ServerEnv {
  const result = serverSchema.safeParse(source);
  if (!result.success) {
    throw new Error(format("Invalid server environment variables:", result.error));
  }
  return result.data;
}

const rawClientEnv = {
  NEXT_PUBLIC_SUPABASE_URL: process.env.NEXT_PUBLIC_SUPABASE_URL,
  NEXT_PUBLIC_SUPABASE_ANON_KEY: process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY,
  NEXT_PUBLIC_SITE_URL: process.env.NEXT_PUBLIC_SITE_URL,
};

const placeholderClientEnv: ClientEnv = {
  NEXT_PUBLIC_SUPABASE_URL: "http://localhost:54321",
  NEXT_PUBLIC_SUPABASE_ANON_KEY: "skipped-env-validation",
  NEXT_PUBLIC_SITE_URL: undefined,
};

export const clientEnv: ClientEnv = skipValidation
  ? placeholderClientEnv
  : parseClientEnv(rawClientEnv);

export const serverEnv: ServerEnv = skipValidation
  ? { NODE_ENV: "development" }
  : parseServerEnv({ NODE_ENV: process.env.NODE_ENV });
