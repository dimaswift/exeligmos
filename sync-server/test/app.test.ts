import assert from "node:assert/strict";
import test from "node:test";

import type { FastifyRequest } from "fastify";

import { buildApp } from "../src/app.js";
import type { AuthAttemptLimiter } from "../src/auth/rate-limit.js";
import { HttpProblem } from "../src/http/problem.js";
import { FakeDatabase, testConfig } from "./helpers.js";

class CapturingLoginLimiter implements AuthAttemptLimiter {
  readonly addresses: string[] = [];

  async checkRegistration(_request: FastifyRequest, _login: string): Promise<void> {}

  async checkLogin(request: FastifyRequest, _login: string): Promise<void> {
    this.addresses.push(request.ip);
    throw new HttpProblem({
      status: 429,
      code: "captured_rate_limit",
      detail: "Captured the resolved client address.",
    });
  }

  async checkRefresh(_request: FastifyRequest): Promise<void> {}
}

test("the complete Phase 3 resource surface is registered", async (context) => {
  const app = buildApp({ config: testConfig(), database: new FakeDatabase() });
  context.after(() => app.close());
  await app.ready();

  for (const [method, url] of [
    ["GET", "/v1/tags"],
    ["GET", "/v1/templates"],
    ["POST", "/v1/media-upload-sessions"],
    ["GET", "/v1/media/:mediaId/content"],
    ["GET", "/v1/public/media/:mediaId/content"],
    ["GET", "/v1/sync/changes"],
    ["POST", "/v1/sync/batches"],
  ] as const) {
    assert.equal(app.hasRoute({ method, url }), true, `${method} ${url} must be registered`);
  }
});

test("liveness does not depend on PostgreSQL", async (context) => {
  const database = new FakeDatabase({
    ready: false,
    database: "down",
    pgvector: "unknown",
    latencyMs: 0,
  });
  const app = buildApp({ config: testConfig(), database });
  context.after(() => app.close());

  const response = await app.inject({ method: "GET", url: "/health/live" });

  assert.equal(response.statusCode, 200);
  assert.deepEqual(response.json(), { status: "ok" });
  assert.ok(response.headers["x-request-id"]);
  assert.equal(database.checks, 0);
});

test("readiness checks PostgreSQL and pgvector", async (context) => {
  const database = new FakeDatabase();
  const app = buildApp({ config: testConfig(), database });
  context.after(() => app.close());

  const response = await app.inject({ method: "GET", url: "/health/ready" });

  assert.equal(response.statusCode, 200);
  assert.deepEqual(response.json(), {
    status: "ready",
    checks: { database: "up", pgvector: "up" },
  });
  assert.equal(database.checks, 1);
});

test("readiness failures use an RFC 9457 problem response", async (context) => {
  const database = new FakeDatabase({
    ready: false,
    database: "up",
    pgvector: "down",
    latencyMs: 0,
  });
  const app = buildApp({ config: testConfig(), database });
  context.after(() => app.close());

  const response = await app.inject({
    method: "GET",
    url: "/health/ready",
    headers: { "x-request-id": "readiness-test" },
  });
  const problem = response.json();

  assert.equal(response.statusCode, 503);
  assert.match(response.headers["content-type"] ?? "", /^application\/problem\+json/);
  assert.equal(response.headers["x-request-id"], "readiness-test");
  assert.equal(response.headers["retry-after"], "5");
  assert.equal(problem.type, "urn:exeligmos:problem:not-ready");
  assert.equal(problem.code, "not_ready");
  assert.equal(problem.instance, "/health/ready");
  assert.equal(problem.requestId, "readiness-test");
  assert.deepEqual(problem.checks, { database: "up", pgvector: "down" });
});

test("unknown routes and unhandled errors use safe problem responses", async (context) => {
  const app = buildApp({ config: testConfig(), database: new FakeDatabase() });
  app.get("/test/boom", async () => {
    throw new Error("database password must stay private");
  });
  context.after(() => app.close());

  const missing = await app.inject({ method: "GET", url: "/missing?secret=yes" });
  const failure = await app.inject({ method: "GET", url: "/test/boom" });

  assert.equal(missing.statusCode, 404);
  assert.equal(missing.json().instance, "/missing");
  assert.equal(missing.json().code, "not_found");
  assert.equal(failure.statusCode, 500);
  assert.equal(failure.json().code, "internal_error");
  assert.equal(failure.body.includes("database password"), false);
  assert.match(failure.headers["content-type"] ?? "", /^application\/problem\+json/);
});

test("database statement and lock deadlines return a retryable safe problem", async (context) => {
  const app = buildApp({ config: testConfig(), database: new FakeDatabase() });
  app.get("/test/database-timeout", async () => {
    throw Object.assign(new Error("internal query text must stay private"), { code: "55P03" });
  });
  context.after(() => app.close());

  const response = await app.inject({ method: "GET", url: "/test/database-timeout" });

  assert.equal(response.statusCode, 503);
  assert.equal(response.headers["retry-after"], "1");
  assert.equal(response.json().code, "database_timeout");
  assert.equal(response.body.includes("internal query text"), false);
});

test("PostgreSQL-incompatible JSON text returns a safe domain problem", async (context) => {
  const app = buildApp({ config: testConfig(), database: new FakeDatabase() });
  app.get("/test/invalid-database-text", async () => {
    throw Object.assign(new Error("invalid byte sequence details must stay private"), {
      code: "22P05",
    });
  });
  app.get("/test/invalid-json-surrogate", async () => {
    throw Object.assign(new Error("surrogate details must stay private"), {
      code: "22P02",
      routine: "json_errsave_error",
    });
  });
  context.after(() => app.close());

  const [response, surrogateResponse] = await Promise.all([
    app.inject({ method: "GET", url: "/test/invalid-database-text" }),
    app.inject({ method: "GET", url: "/test/invalid-json-surrogate" }),
  ]);

  assert.equal(response.statusCode, 422);
  assert.equal(response.json().code, "invalid_text");
  assert.equal(response.body.includes("invalid byte sequence details"), false);
  assert.equal(surrogateResponse.statusCode, 422);
  assert.equal(surrogateResponse.json().code, "invalid_json");
  assert.equal(surrogateResponse.body.includes("surrogate details"), false);
});

test("HttpProblem preserves an explicit stable error code", async (context) => {
  const app = buildApp({ config: testConfig(), database: new FakeDatabase() });
  app.get("/test/conflict", async () => {
    throw new HttpProblem({
      status: 409,
      code: "idempotency_conflict",
      type: "https://api.exeligmos.app/problems/idempotency-conflict",
      detail: "That key was already used for another request.",
    });
  });
  context.after(() => app.close());

  const response = await app.inject({ method: "GET", url: "/test/conflict" });

  assert.equal(response.statusCode, 409);
  assert.equal(response.json().code, "idempotency_conflict");
});

test("domain 422 problems include the documented field-error array", async (context) => {
  const app = buildApp({ config: testConfig(), database: new FakeDatabase() });
  app.get("/test/domain-validation", async () => {
    throw new HttpProblem({
      status: 422,
      code: "invalid_device",
      detail: "The selected device is invalid.",
    });
  });
  context.after(() => app.close());

  const response = await app.inject({ method: "GET", url: "/test/domain-validation" });

  assert.equal(response.statusCode, 422);
  assert.deepEqual(response.json().errors, [
    {
      path: "",
      code: "invalid_device",
      message: "The selected device is invalid.",
    },
  ]);
});

test("closing the app closes its database dependency", async () => {
  const database = new FakeDatabase();
  const app = buildApp({ config: testConfig(), database });

  await app.close();

  assert.equal(database.closes, 1);
});

test("forwarded client addresses are trusted only for the configured hop count", async () => {
  const untrustedLimiter = new CapturingLoginLimiter();
  const untrustedApp = buildApp({
    config: testConfig({ trustProxy: false }),
    database: new FakeDatabase(),
    authAttemptLimiter: untrustedLimiter,
  });
  const trustedLimiter = new CapturingLoginLimiter();
  const trustedApp = buildApp({
    config: testConfig({ trustProxy: 1 }),
    database: new FakeDatabase(),
    authAttemptLimiter: trustedLimiter,
  });

  try {
    const request = {
      method: "POST" as const,
      url: "/v1/auth/login",
      headers: { "x-forwarded-for": "198.51.100.42" },
      payload: {
        login: "aurora",
        password: "correct-horse-battery-staple",
      },
    };
    assert.equal((await untrustedApp.inject(request)).statusCode, 429);
    assert.equal((await trustedApp.inject(request)).statusCode, 429);

    assert.equal(untrustedLimiter.addresses.length, 1);
    assert.notEqual(untrustedLimiter.addresses[0], "198.51.100.42");
    assert.deepEqual(trustedLimiter.addresses, ["198.51.100.42"]);
  } finally {
    await untrustedApp.close();
    await trustedApp.close();
  }
});
