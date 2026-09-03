import { beforeEach, describe, expect, it, vi } from "vitest";

/**
 * Unit tests for the auth server actions.
 *
 * These exercise this repository's own logic — input validation, error
 * surfacing, redirect targets, session handling — against a stubbed Supabase
 * auth client. They do NOT prove that a real Supabase Auth server accepts a
 * sign up or issues a session; that requires a live project and is verified
 * separately.
 */

const authMock = {
  signUp: vi.fn(),
  signInWithPassword: vi.fn(),
  signOut: vi.fn(),
};

vi.mock("@/lib/supabase/server", () => ({
  createClient: vi.fn(async () => ({ auth: authMock })),
}));

vi.mock("next/cache", () => ({ revalidatePath: vi.fn() }));

vi.mock("next/navigation", () => ({
  redirect: (path: string) => {
    const error = new Error("NEXT_REDIRECT") as Error & { digest: string };
    error.digest = `NEXT_REDIRECT;${path}`;
    throw error;
  },
}));

vi.mock("next/headers", () => ({
  headers: async () =>
    new Map([
      ["host", "app.example.com"],
      ["x-forwarded-proto", "https"],
    ]),
}));

const { signInAction, signUpAction, signOutAction } = await import(
  "@/app/auth/actions"
);

function form(entries: Record<string, string>): FormData {
  const data = new FormData();
  for (const [key, value] of Object.entries(entries)) data.append(key, value);
  return data;
}

async function redirectTarget(promise: Promise<unknown>): Promise<string> {
  try {
    await promise;
  } catch (error) {
    const digest = (error as { digest?: string }).digest ?? "";
    if (digest.startsWith("NEXT_REDIRECT;")) {
      return digest.slice("NEXT_REDIRECT;".length);
    }
    throw error;
  }
  throw new Error("expected a redirect, none was thrown");
}

beforeEach(() => {
  authMock.signUp.mockReset();
  authMock.signInWithPassword.mockReset();
  authMock.signOut.mockReset();
});

describe("signInAction", () => {
  it("rejects a malformed email without contacting the auth server", async () => {
    const state = await signInAction({}, form({ email: "nope", password: "longenough" }));
    expect(state.error).toMatch(/valid email/i);
    expect(authMock.signInWithPassword).not.toHaveBeenCalled();
  });

  it("rejects a password shorter than 8 characters", async () => {
    const state = await signInAction({}, form({ email: "a@b.com", password: "short" }));
    expect(state.error).toMatch(/at least 8/i);
    expect(authMock.signInWithPassword).not.toHaveBeenCalled();
  });

  it("surfaces the auth server's error message", async () => {
    authMock.signInWithPassword.mockResolvedValue({
      error: { message: "Invalid login credentials" },
    });
    const state = await signInAction({}, form({ email: "a@b.com", password: "password1" }));
    expect(state.error).toBe("Invalid login credentials");
  });

  it("redirects to the dashboard on success", async () => {
    authMock.signInWithPassword.mockResolvedValue({ error: null });
    const target = await redirectTarget(
      signInAction({}, form({ email: "a@b.com", password: "password1" })),
    );
    expect(target).toBe("/dashboard");
  });

  it("honours a same-origin redirectTo", async () => {
    authMock.signInWithPassword.mockResolvedValue({ error: null });
    const target = await redirectTarget(
      signInAction(
        {},
        form({ email: "a@b.com", password: "password1", redirectTo: "/dashboard/settings" }),
      ),
    );
    expect(target).toBe("/dashboard/settings");
  });

  it("ignores an off-origin redirectTo", async () => {
    authMock.signInWithPassword.mockResolvedValue({ error: null });
    const target = await redirectTarget(
      signInAction(
        {},
        form({
          email: "a@b.com",
          password: "password1",
          redirectTo: "https://evil.example.com",
        }),
      ),
    );
    expect(target).toBe("/dashboard");
  });
});

describe("signUpAction", () => {
  it("rejects mismatched passwords", async () => {
    const state = await signUpAction(
      {},
      form({ email: "a@b.com", password: "password1", confirmPassword: "password2" }),
    );
    expect(state.error).toMatch(/do not match/i);
    expect(authMock.signUp).not.toHaveBeenCalled();
  });

  it("sends the confirmation redirect to the derived site origin", async () => {
    authMock.signUp.mockResolvedValue({ data: { session: null }, error: null });
    await signUpAction(
      {},
      form({ email: "a@b.com", password: "password1", confirmPassword: "password1" }),
    );
    expect(authMock.signUp).toHaveBeenCalledWith(
      expect.objectContaining({
        options: { emailRedirectTo: "https://app.example.com/auth/confirm" },
      }),
    );
  });

  it("returns a notice when email confirmation is required", async () => {
    authMock.signUp.mockResolvedValue({ data: { session: null }, error: null });
    const state = await signUpAction(
      {},
      form({ email: "a@b.com", password: "password1", confirmPassword: "password1" }),
    );
    expect(state.notice).toMatch(/confirmation link/i);
    expect(state.error).toBeUndefined();
  });

  it("redirects to the dashboard when a session is issued immediately", async () => {
    authMock.signUp.mockResolvedValue({
      data: { session: { access_token: "token" } },
      error: null,
    });
    const target = await redirectTarget(
      signUpAction(
        {},
        form({ email: "a@b.com", password: "password1", confirmPassword: "password1" }),
      ),
    );
    expect(target).toBe("/dashboard");
  });

  it("surfaces the auth server's error message", async () => {
    authMock.signUp.mockResolvedValue({
      data: { session: null },
      error: { message: "User already registered" },
    });
    const state = await signUpAction(
      {},
      form({ email: "a@b.com", password: "password1", confirmPassword: "password1" }),
    );
    expect(state.error).toBe("User already registered");
  });
});

describe("signOutAction", () => {
  it("signs out and redirects to the login page", async () => {
    authMock.signOut.mockResolvedValue({ error: null });
    const target = await redirectTarget(signOutAction());
    expect(authMock.signOut).toHaveBeenCalledOnce();
    expect(target).toBe("/login");
  });
});
