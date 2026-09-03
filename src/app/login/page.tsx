import Link from "next/link";

import { signInAction } from "@/app/auth/actions";
import { CredentialsForm } from "@/components/auth/credentials-form";
import { Alert } from "@/components/ui/alert";
import { safeRedirectPath } from "@/lib/routes";

const ERROR_MESSAGES: Record<string, string> = {
  invalid_confirmation_link: "That confirmation link is not valid.",
  confirmation_failed: "That confirmation link has expired or was already used.",
};

export default async function LoginPage({
  searchParams,
}: {
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  const params = await searchParams;
  const redirectTo = safeRedirectPath(
    typeof params.redirectTo === "string" ? params.redirectTo : undefined,
  );
  const errorKey = typeof params.error === "string" ? params.error : undefined;

  return (
    <main className="mx-auto flex min-h-dvh w-full max-w-sm flex-col justify-center px-6 py-12">
      <h1 className="text-2xl font-semibold tracking-tight">Sign in</h1>
      <p className="mt-1 text-sm text-muted-foreground">
        Access your health data foundation.
      </p>

      <div className="mt-8 space-y-4">
        {errorKey && ERROR_MESSAGES[errorKey] ? (
          <Alert tone="error">{ERROR_MESSAGES[errorKey]}</Alert>
        ) : null}

        <CredentialsForm mode="sign-in" action={signInAction} redirectTo={redirectTo} />
      </div>

      <p className="mt-6 text-sm text-muted-foreground">
        No account?{" "}
        <Link href="/signup" className="font-medium text-foreground underline">
          Create one
        </Link>
      </p>
    </main>
  );
}
