import assert from "node:assert/strict";
import test from "node:test";

import Fastify, { type FastifyRequest } from "fastify";

import type { Principal } from "../src/auth/principal.js";
import type {
  AuthSessionResponse,
  LoginInput,
  RegisterInput,
} from "../src/auth/service.js";
import { HttpProblem, registerProblemHandlers } from "../src/http/problem.js";
import {
  registerAuthRoutes,
  type AuthRouteService,
} from "../src/routes/auth.js";

const principal: Principal = {
  kind: "jwt",
  userId: "ad8063cc-e668-4bc3-8182-74763dd756fe",
  actorId: "0d4cc852-c4ef-49ac-9975-a285fb50ad7d",
  scopes: new Set(),
};

const session: AuthSessionResponse = {
  tokenType: "Bearer",
  accessToken: "a".repeat(64),
  expiresIn: 900,
  refreshToken: `exr_${"b".repeat(43)}`,
  refreshExpiresIn: 2_592_000,
  user: {
    id: principal.userId,
    login: "aurora",
    displayName: "Aurora",
    sarosAnchor: 141,
    createdAt: "2026-07-14T10:00:00.000Z",
    updatedAt: "2026-07-14T10:00:00.000Z",
  },
};

class FakeAuthRouteService implements AuthRouteService {
  loginError?: HttpProblem;
  registerCalls = 0;
  loginCalls = 0;
  refreshCalls = 0;
  logoutCalls = 0;
  logoutAuthentications = 0;

  async register(_input: RegisterInput): Promise<AuthSessionResponse> {
    this.registerCalls += 1;
    return session;
  }

  async login(_input: LoginInput): Promise<AuthSessionResponse> {
    this.loginCalls += 1;
    if (this.loginError !== undefined) {
      throw this.loginError;
    }
    return session;
  }

  async refresh(_refreshToken: string): Promise<AuthSessionResponse> {
    this.refreshCalls += 1;
    return session;
  }

  async logout(_principal: Principal, _refreshToken: string): Promise<void> {
    this.logoutCalls += 1;
  }

  async authenticate(_request: FastifyRequest): Promise<Principal> {
    return principal;
  }

  async authenticateForLogout(_request: FastifyRequest): Promise<Principal> {
    this.logoutAuthentications += 1;
    return principal;
  }
}

async function buildAuthApp(service: AuthRouteService) {
  const app = Fastify({ logger: false });
  registerProblemHandlers(app);
  await app.register(registerAuthRoutes, { authService: service });
  await app.ready();
  return app;
}

test("auth routes follow the documented session responses and headers", async (context) => {
  const service = new FakeAuthRouteService();
  const app = await buildAuthApp(service);
  context.after(() => app.close());

  const registered = await app.inject({
    method: "POST",
    url: "/v1/auth/register",
    payload: {
      login: "aurora",
      password: "correct-horse-battery-staple",
      displayName: "Aurora",
    },
  });
  assert.equal(registered.statusCode, 201);
  assert.equal(registered.headers.location, "/v1/me");
  assert.equal(registered.headers["cache-control"], "no-store");
  assert.deepEqual(registered.json(), session);

  const loggedIn = await app.inject({
    method: "POST",
    url: "/v1/auth/login",
    payload: { login: "aurora", password: "correct-horse-battery-staple" },
  });
  assert.equal(loggedIn.statusCode, 200);
  assert.equal(loggedIn.headers["cache-control"], "no-store");

  const refreshed = await app.inject({
    method: "POST",
    url: "/v1/auth/refresh",
    payload: { refreshToken: session.refreshToken },
  });
  assert.equal(refreshed.statusCode, 200);
  assert.equal(refreshed.headers["cache-control"], "no-store");

  const loggedOut = await app.inject({
    method: "POST",
    url: "/v1/auth/logout",
    headers: { authorization: `Bearer ${session.accessToken}` },
    payload: { refreshToken: session.refreshToken },
  });
  assert.equal(loggedOut.statusCode, 204);
  assert.equal(loggedOut.body, "");
  assert.equal(service.logoutCalls, 1);

  const logoutRetry = await app.inject({
    method: "POST",
    url: "/v1/auth/logout",
    headers: { authorization: `Bearer ${session.accessToken}` },
    payload: { refreshToken: session.refreshToken },
  });
  assert.equal(logoutRetry.statusCode, 204);
  assert.equal(logoutRetry.body, "");
  assert.equal(service.logoutCalls, 2);
  assert.equal(service.logoutAuthentications, 2);
});

test("auth routes validate bodies and challenge invalid credentials", async (context) => {
  const service = new FakeAuthRouteService();
  service.loginError = new HttpProblem({
    status: 401,
    code: "invalid_credentials",
    detail: "The login or password is incorrect.",
  });
  const app = await buildAuthApp(service);
  context.after(() => app.close());

  const invalidBody = await app.inject({
    method: "POST",
    url: "/v1/auth/login",
    payload: { login: "x", password: "short" },
  });
  assert.equal(invalidBody.statusCode, 400);
  const validationProblem = invalidBody.json<{
    code: string;
    errors: Array<{ path: string; code: string; message: string }>;
  }>();
  assert.equal(validationProblem.code, "validation_error");
  assert.ok(validationProblem.errors.some((error) => error.path === "/login"));
  assert.ok(validationProblem.errors.every((error) => error.code.startsWith("schema_")));

  const invalidPassword = await app.inject({
    method: "POST",
    url: "/v1/auth/register",
    payload: { login: "aurora", password: "short" },
  });
  assert.equal(invalidPassword.statusCode, 400);
  assert.ok(
    invalidPassword
      .json<{ errors: Array<{ path: string }> }>()
      .errors.some((error) => error.path === "/password"),
  );

  const rejected = await app.inject({
    method: "POST",
    url: "/v1/auth/login",
    payload: { login: "aurora", password: "incorrect-password-value" },
  });
  assert.equal(rejected.statusCode, 401);
  assert.equal(rejected.headers["www-authenticate"], 'Bearer realm="exeligmos"');
  assert.equal(rejected.json().code, "invalid_credentials");
});

test("login is explicitly rate limited and returns an RFC problem", async (context) => {
  const service = new FakeAuthRouteService();
  service.loginError = new HttpProblem({
    status: 401,
    code: "invalid_credentials",
    detail: "The login or password is incorrect.",
  });
  const app = await buildAuthApp(service);
  context.after(() => app.close());

  for (let attempt = 0; attempt < 10; attempt += 1) {
    const response = await app.inject({
      method: "POST",
      url: "/v1/auth/login",
      payload: { login: "aurora", password: "incorrect-password-value" },
    });
    assert.equal(response.statusCode, 401);
  }

  const limited = await app.inject({
    method: "POST",
    url: "/v1/auth/login",
    payload: { login: "aurora", password: "incorrect-password-value" },
  });
  assert.equal(limited.statusCode, 429);
  assert.equal(limited.json().code, "too_many_requests");
  assert.ok(Number(limited.headers["retry-after"]) >= 1);
  assert.equal(service.loginCalls, 10);
});

test("registration and refresh have independent brute-force limits", async (context) => {
  const service = new FakeAuthRouteService();
  const app = await buildAuthApp(service);
  context.after(() => app.close());

  for (let attempt = 0; attempt < 5; attempt += 1) {
    const response = await app.inject({
      method: "POST",
      url: "/v1/auth/register",
      payload: {
        login: "aurora",
        password: "correct-horse-battery-staple",
      },
    });
    assert.equal(response.statusCode, 201);
  }
  const registerLimited = await app.inject({
    method: "POST",
    url: "/v1/auth/register",
    payload: {
      login: "aurora",
      password: "correct-horse-battery-staple",
    },
  });
  assert.equal(registerLimited.statusCode, 429);
  assert.equal(service.registerCalls, 5);

  for (let attempt = 0; attempt < 30; attempt += 1) {
    const response = await app.inject({
      method: "POST",
      url: "/v1/auth/refresh",
      payload: { refreshToken: session.refreshToken },
    });
    assert.equal(response.statusCode, 200);
  }
  const refreshLimited = await app.inject({
    method: "POST",
    url: "/v1/auth/refresh",
    payload: { refreshToken: session.refreshToken },
  });
  assert.equal(refreshLimited.statusCode, 429);
  assert.equal(service.refreshCalls, 30);
});
