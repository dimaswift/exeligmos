import { afterEach, describe, expect, it, vi } from "vitest";

import type { AuthSession } from "@exeligmos/api-client";

import { assertSameOrigin, requireAuth } from "./auth.server.js";
import { safeReturnTo } from "./navigation.js";
import { commitAuthSession, toStoredAuthSession } from "./session.server.js";

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("auth request boundaries", () => {
  it("keeps redirects on the same origin", () => {
    expect(safeReturnTo("/records?from=login")).toBe("/records?from=login");
    expect(safeReturnTo("//attacker.example")).toBe("/");
    expect(safeReturnTo("https://attacker.example")).toBe("/");
  });

  it("rejects a cross-origin form request", () => {
    const request = new Request("https://app.example/logout", {
      headers: { Origin: "https://attacker.example" },
      method: "POST",
    });
    expect(() => assertSameOrigin(request)).toThrow();
  });

  it("coalesces concurrent rotation of the same single-use refresh token", async () => {
    const now = Date.now();
    const current: AuthSession = {
      tokenType: "Bearer",
      accessToken: "expiring-access",
      expiresIn: 1,
      refreshToken: "one-use-refresh-token",
      refreshExpiresIn: 86_400,
      user: {
        id: "2dca8eab-00a8-4e94-9bd2-2fcbfe17e890",
        login: "sun",
        displayName: "Sun",
        createdAt: "2026-07-15T00:00:00Z",
        updatedAt: "2026-07-15T00:00:00Z",
      },
    };
    const rotated: AuthSession = {
      ...current,
      accessToken: "rotated-access",
      expiresIn: 900,
      refreshToken: "rotated-refresh-token",
    };
    const cookie = await commitAuthSession(
      new Request("https://app.example/feed"),
      toStoredAuthSession(current, now - 60_000),
    );
    const cookieHeader = cookie.split(";", 1)[0]!;
    let refreshRequests = 0;
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
        const request = input instanceof Request ? input : new Request(input, init);
        expect(new URL(request.url).pathname).toBe("/v1/auth/refresh");
        refreshRequests += 1;
        await Promise.resolve();
        return new Response(JSON.stringify(rotated), {
          status: 200,
          headers: { "Content-Type": "application/json" },
        });
      }),
    );
    const request = () =>
      new Request("https://app.example/feed", { headers: { Cookie: cookieHeader } });

    const [first, second] = await Promise.all([requireAuth(request()), requireAuth(request())]);

    expect(refreshRequests).toBe(1);
    expect(first.auth.accessToken).toBe("rotated-access");
    expect(second.auth.accessToken).toBe("rotated-access");
    expect(first.headers?.has("Set-Cookie")).toBe(true);
    expect(second.headers?.has("Set-Cookie")).toBe(true);
  });
});
