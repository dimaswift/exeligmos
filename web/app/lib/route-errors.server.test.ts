import { describe, expect, it } from "vitest";

import { BackendRequestError } from "./backend.server.js";
import { throwRouteError } from "./route-errors.server.js";

describe("route API errors", () => {
  it("preserves retry and request diagnostics", async () => {
    const error = new BackendRequestError("Please retry.", 429, {
      requestId: "request-123",
      retryAfterSeconds: 7,
    });

    let thrown: unknown;
    try {
      await throwRouteError(error, new Request("https://app.example/explore"));
    } catch (caught) {
      thrown = caught;
    }

    expect(thrown).toBeInstanceOf(Response);
    const response = thrown as Response;
    expect(response.status).toBe(429);
    expect(response.headers.get("Retry-After")).toBe("7");
    expect(response.headers.get("X-Request-Id")).toBe("request-123");
    await expect(response.text()).resolves.toBe("Please retry.");
  });

  it("can hide deliberately indistinguishable public 404 details", async () => {
    let thrown: unknown;
    try {
      await throwRouteError(
        new BackendRequestError("Internal visibility detail.", 404),
        new Request("https://app.example/u/missing"),
        { notFoundMessage: "Public profile not found." },
      );
    } catch (caught) {
      thrown = caught;
    }

    expect(thrown).toBeInstanceOf(Response);
    await expect((thrown as Response).text()).resolves.toBe("Public profile not found.");
  });
});
