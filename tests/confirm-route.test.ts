import { beforeEach, describe, expect, it, vi } from "vitest";
import { NextRequest } from "next/server";

/**
 * Regression guard for the confirmation redirect.
 *
 * The session cookie this route sets is scoped to the request's host. If the
 * redirect names an absolute origin, that origin can differ from the one the
 * client used (localhost vs 127.0.0.1, a proxy hostname in production), the
 * browser drops the cookie, and confirmation silently fails: the user lands
 * back on /login having apparently confirmed successfully.
 *
 * The e2e suite catches this against a real stack. This test catches it in
 * milliseconds.
 */

const verifyOtp = vi.fn();

vi.mock("@/lib/supabase/server", () => ({
  createClient: vi.fn(async () => ({ auth: { verifyOtp } })),
}));

const { GET } = await import("@/app/auth/confirm/route");

function request(query: string) {
  return new NextRequest(`http://127.0.0.1:3000/auth/confirm${query}`);
}

beforeEach(() => {
  verifyOtp.mockReset();
});

describe("GET /auth/confirm", () => {
  it("redirects to the dashboard with a relative Location on success", async () => {
    verifyOtp.mockResolvedValue({ error: null });

    const response = await GET(request("?token_hash=abc&type=email"));

    expect(response.status).toBe(307);
    expect(response.headers.get("location")).toBe("/dashboard");
    expect(verifyOtp).toHaveBeenCalledWith({ type: "email", token_hash: "abc" });
  });

  it("never emits an absolute Location, which would drop the session cookie", async () => {
    verifyOtp.mockResolvedValue({ error: null });

    for (const query of [
      "?token_hash=abc&type=email",
      "?type=email",
      "?token_hash=abc&type=email&next=/dashboard/settings",
    ]) {
      const location = (await GET(request(query))).headers.get("location") ?? "";
      expect(location.startsWith("/"), `absolute Location for ${query}: ${location}`).toBe(
        true,
      );
      expect(location).not.toMatch(/^https?:\/\//);
    }
  });

  it("rejects a link with no token", async () => {
    const response = await GET(request("?type=email"));
    expect(response.headers.get("location")).toBe("/login?error=invalid_confirmation_link");
    expect(verifyOtp).not.toHaveBeenCalled();
  });

  it("reports a token the auth server rejects", async () => {
    verifyOtp.mockResolvedValue({ error: { message: "Token has expired" } });
    const response = await GET(request("?token_hash=stale&type=email"));
    expect(response.headers.get("location")).toBe("/login?error=confirmation_failed");
  });

  it("honours a safe next parameter and ignores an off-origin one", async () => {
    verifyOtp.mockResolvedValue({ error: null });

    const safe = await GET(request("?token_hash=abc&type=email&next=/dashboard/settings"));
    expect(safe.headers.get("location")).toBe("/dashboard/settings");

    const unsafe = await GET(
      request("?token_hash=abc&type=email&next=https://evil.example.com"),
    );
    expect(unsafe.headers.get("location")).toBe("/dashboard");
  });
});
