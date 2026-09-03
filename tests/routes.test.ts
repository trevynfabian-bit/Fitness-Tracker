import { describe, expect, it } from "vitest";

import { isAuthPath, isProtectedPath, safeRedirectPath } from "../src/lib/routes";

describe("isProtectedPath", () => {
  it.each(["/dashboard", "/dashboard/", "/dashboard/settings", "/registry/metrics"])(
    "protects %s",
    (path) => {
      expect(isProtectedPath(path)).toBe(true);
    },
  );

  it.each(["/", "/login", "/signup", "/auth/confirm", "/dashboards", "/registryx"])(
    "does not protect %s",
    (path) => {
      expect(isProtectedPath(path)).toBe(false);
    },
  );
});

describe("isAuthPath", () => {
  it.each(["/login", "/signup"])("classifies %s as an auth route", (path) => {
    expect(isAuthPath(path)).toBe(true);
  });

  it("does not classify the dashboard as an auth route", () => {
    expect(isAuthPath("/dashboard")).toBe(false);
  });
});

describe("safeRedirectPath", () => {
  it("keeps a same-origin absolute path", () => {
    expect(safeRedirectPath("/dashboard/settings")).toBe("/dashboard/settings");
  });

  it.each([
    "//evil.example.com",
    "https://evil.example.com",
    "/\\evil.example.com",
    "javascript:alert(1)",
    "",
    null,
    undefined,
  ])("falls back for %s", (candidate) => {
    expect(safeRedirectPath(candidate)).toBe("/dashboard");
  });

  it("honours a custom fallback", () => {
    expect(safeRedirectPath(null, "/login")).toBe("/login");
  });
});
