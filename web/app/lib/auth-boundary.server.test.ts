import { RouterContextProvider } from "react-router";
import { describe, expect, it, vi } from "vitest";

import type { AuthBoundary } from "./auth.server.js";
import { createAuthBoundaryMiddleware, readRequestAuth } from "./auth-boundary.server.js";

const auth: AuthBoundary["auth"] = {
  accessExpiresAt: Date.parse("2030-01-01T00:15:00.000Z"),
  accessToken: "access-token",
  refreshExpiresAt: Date.parse("2030-01-02T00:00:00.000Z"),
  refreshToken: "refresh-token",
  user: {
    createdAt: "2030-01-01T00:00:00.000Z",
    displayName: "Solar Observer",
    id: "01901234-5678-7abc-8def-0123456789ab",
    login: "observer",
    sarosAnchor: 141,
    updatedAt: "2030-01-01T00:00:00.000Z",
  },
};

describe("authenticated request boundary", () => {
  it("resolves authentication once and shares it with downstream loaders", async () => {
    const boundary: AuthBoundary = { auth };
    const resolve = vi.fn(() => Promise.resolve(boundary));
    const middleware = createAuthBoundaryMiddleware(resolve);
    const context = new RouterContextProvider();
    const request = new Request("https://app.example/feed");

    const response = await middleware(
      {
        context,
        params: {},
        pattern: "/feed",
        request,
        url: new URL(request.url),
      },
      () => {
        expect(readRequestAuth(context)).toBe(boundary);
        return Promise.resolve(new Response("ok"));
      },
    );

    expect(resolve).toHaveBeenCalledTimes(1);
    expect(response).toBeInstanceOf(Response);
  });

  it("adds a rotated session cookie to the final nested response", async () => {
    const headers = new Headers({ "Set-Cookie": "session=rotated; HttpOnly" });
    const middleware = createAuthBoundaryMiddleware(() => Promise.resolve({ auth, headers }));
    const context = new RouterContextProvider();
    const request = new Request("https://app.example/feed/following");

    const response = await middleware(
      {
        context,
        params: {},
        pattern: "/feed/following",
        request,
        url: new URL(request.url),
      },
      () => Promise.resolve(new Response("ok", { headers: { "X-Loader": "following" } })),
    );

    expect(response).toBeInstanceOf(Response);
    expect(response?.headers.get("Set-Cookie")).toBe("session=rotated; HttpOnly");
    expect(response?.headers.get("X-Loader")).toBe("following");
  });
});
