import { describe, expect, it } from "vitest";

import type { AuthSession } from "@exeligmos/api-client";

import { commitAuthSession, readAuthSession, toStoredAuthSession } from "./session.server.js";

const backendSession: AuthSession = {
  tokenType: "Bearer",
  accessToken: "access-token-that-must-not-appear-in-cookie-storage",
  expiresIn: 900,
  refreshToken: "refresh-token-that-must-not-appear-in-cookie-storage",
  refreshExpiresIn: 86_400,
  user: {
    id: "2dca8eab-00a8-4e94-9bd2-2fcbfe17e890",
    login: "sun",
    displayName: "Sun",
    sarosAnchor: 141,
    createdAt: "2026-07-15T00:00:00Z",
    updatedAt: "2026-07-15T00:00:00Z",
  },
};

describe("sealed browser session", () => {
  it("round-trips authentication without exposing either backend token", async () => {
    const request = new Request("http://localhost/login");
    const cookie = await commitAuthSession(request, toStoredAuthSession(backendSession));
    expect(Buffer.byteLength(cookie, "utf8")).toBeLessThanOrEqual(4_096);
    expect(cookie).not.toContain(backendSession.accessToken);
    expect(cookie).not.toContain(backendSession.refreshToken);

    const cookieHeader = cookie.split(";", 1)[0]!;
    const stored = await readAuthSession(
      new Request("http://localhost/", { headers: { Cookie: cookieHeader } }),
    );
    expect(stored?.user.login).toBe("sun");
    expect(stored?.accessToken).toBe(backendSession.accessToken);
  });

  it("rejects payloads that cannot fit in a browser cookie", async () => {
    const oversized: AuthSession = {
      ...backendSession,
      accessToken: "a".repeat(5_000),
    };
    await expect(
      commitAuthSession(new Request("http://localhost/login"), toStoredAuthSession(oversized)),
    ).rejects.toThrow("exceeds the browser cookie limit");
  });
});
