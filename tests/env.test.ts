import { describe, expect, it } from "vitest";

import { parseClientEnv, parseServerEnv } from "../src/lib/env";

describe("client environment validation", () => {
  it("accepts a complete configuration", () => {
    const env = parseClientEnv({
      NEXT_PUBLIC_SUPABASE_URL: "https://abc.supabase.co",
      NEXT_PUBLIC_SUPABASE_ANON_KEY: "anon-key",
      NEXT_PUBLIC_SITE_URL: "https://example.com",
    });

    expect(env.NEXT_PUBLIC_SUPABASE_URL).toBe("https://abc.supabase.co");
    expect(env.NEXT_PUBLIC_SITE_URL).toBe("https://example.com");
  });

  it("treats NEXT_PUBLIC_SITE_URL as optional", () => {
    const env = parseClientEnv({
      NEXT_PUBLIC_SUPABASE_URL: "https://abc.supabase.co",
      NEXT_PUBLIC_SUPABASE_ANON_KEY: "anon-key",
    });
    expect(env.NEXT_PUBLIC_SITE_URL).toBeUndefined();
  });

  it("rejects a missing Supabase URL", () => {
    expect(() =>
      parseClientEnv({ NEXT_PUBLIC_SUPABASE_ANON_KEY: "anon-key" }),
    ).toThrowError(/NEXT_PUBLIC_SUPABASE_URL/);
  });

  it("rejects a malformed Supabase URL", () => {
    expect(() =>
      parseClientEnv({
        NEXT_PUBLIC_SUPABASE_URL: "not-a-url",
        NEXT_PUBLIC_SUPABASE_ANON_KEY: "anon-key",
      }),
    ).toThrowError(/must be a valid URL/);
  });

  it("rejects a missing anon key", () => {
    expect(() =>
      parseClientEnv({ NEXT_PUBLIC_SUPABASE_URL: "https://abc.supabase.co" }),
    ).toThrowError(/NEXT_PUBLIC_SUPABASE_ANON_KEY/);
  });

  it("rejects an empty anon key", () => {
    expect(() =>
      parseClientEnv({
        NEXT_PUBLIC_SUPABASE_URL: "https://abc.supabase.co",
        NEXT_PUBLIC_SUPABASE_ANON_KEY: "",
      }),
    ).toThrowError(/NEXT_PUBLIC_SUPABASE_ANON_KEY/);
  });

  it("reports every missing variable at once", () => {
    expect(() => parseClientEnv({})).toThrowError(
      /NEXT_PUBLIC_SUPABASE_URL[\s\S]*NEXT_PUBLIC_SUPABASE_ANON_KEY/,
    );
  });
});

describe("server environment validation", () => {
  it("defaults NODE_ENV to development", () => {
    expect(parseServerEnv({}).NODE_ENV).toBe("development");
  });

  it("rejects an unknown NODE_ENV", () => {
    expect(() => parseServerEnv({ NODE_ENV: "staging" })).toThrowError(/NODE_ENV/);
  });
});
