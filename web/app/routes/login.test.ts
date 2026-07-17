import { afterEach, describe, expect, it, vi } from "vitest";

import type { AuthSession } from "@exeligmos/api-client";

import { action } from "./login";

const backendSession: AuthSession = {
  tokenType: "Bearer",
  accessToken: "access-token",
  expiresIn: 900,
  refreshToken: "refresh-token",
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

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("login redirect", () => {
  it("lands a successful login on the feed by default", async () => {
    stubSuccessfulLogin();

    const response = (await action(
      actionArgs(
        new Request("https://app.example/login", {
          body: new URLSearchParams({ login: "sun", password: "secret" }),
          method: "POST",
        }),
      ),
    )) as Response;

    expect(response.status).toBe(302);
    expect(response.headers.get("Location")).toBe("/feed");
    expect(response.headers.get("Set-Cookie")).toContain("exeligmos_session=");
  });

  it("preserves a safe protected-page return target", async () => {
    stubSuccessfulLogin();

    const response = (await action(
      actionArgs(
        new Request("https://app.example/login", {
          body: new URLSearchParams({
            login: "sun",
            password: "secret",
            returnTo: "/records?from=login",
          }),
          method: "POST",
        }),
      ),
    )) as Response;

    expect(response.headers.get("Location")).toBe("/records?from=login");
  });

  it("falls back to the feed for an unsafe return target", async () => {
    stubSuccessfulLogin();

    const response = (await action(
      actionArgs(
        new Request("https://app.example/login", {
          body: new URLSearchParams({
            login: "sun",
            password: "secret",
            returnTo: "https://attacker.example",
          }),
          method: "POST",
        }),
      ),
    )) as Response;

    expect(response.headers.get("Location")).toBe("/feed");
  });
});

function stubSuccessfulLogin() {
  vi.stubGlobal(
    "fetch",
    vi.fn(() =>
      Promise.resolve(
        Response.json(backendSession, {
          headers: { "Content-Type": "application/json" },
          status: 200,
        }),
      ),
    ),
  );
}

function actionArgs(request: Request): Parameters<typeof action>[0] {
  return { request } as Parameters<typeof action>[0];
}
