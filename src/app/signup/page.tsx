import Link from "next/link";

import { signUpAction } from "@/app/auth/actions";
import { CredentialsForm } from "@/components/auth/credentials-form";

export default function SignUpPage() {
  return (
    <main className="mx-auto flex min-h-dvh w-full max-w-sm flex-col justify-center px-6 py-12">
      <h1 className="text-2xl font-semibold tracking-tight">Create account</h1>
      <p className="mt-1 text-sm text-muted-foreground">
        Your data is visible only to you.
      </p>

      <div className="mt-8">
        <CredentialsForm mode="sign-up" action={signUpAction} />
      </div>

      <p className="mt-6 text-sm text-muted-foreground">
        Already registered?{" "}
        <Link href="/login" className="font-medium text-foreground underline">
          Sign in
        </Link>
      </p>
    </main>
  );
}
