import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import test from "node:test";

import type { FastifyRequest } from "fastify";
import type { QueryResultRow } from "pg";

import { BearerAuthenticator } from "../src/auth/bearer-authenticator.js";
import type { Authenticator } from "../src/auth/principal.js";
import type {
  Database,
  DatabaseReadiness,
  DatabaseResult,
  Queryable,
} from "../src/db/database.js";
import { HttpProblem } from "../src/http/problem.js";

class AuthenticationDatabase implements Database {
  readonly calls: Array<{ text: string; values: readonly unknown[] }> = [];

  constructor(private readonly keyExists = true) {}

  async query<Row extends QueryResultRow = QueryResultRow>(
    text: string,
    values: readonly unknown[] = [],
  ): Promise<DatabaseResult<Row>> {
    this.calls.push({ text, values });
    if (text.includes("FROM api_keys")) {
      const rows = this.keyExists
        ? [{
            id: "51062dc2-7143-4960-9783-a14e2e83c64f",
            user_id: "16e97ec6-e669-471b-a63d-9d1cd5df6e85",
            device_id: "910b7ae2-b92c-429e-bb4d-fca20233f083",
            scopes: ["records:read"],
          }]
        : [];
      return { rows: rows as unknown as Row[], rowCount: rows.length };
    }
    return { rows: [], rowCount: 1 };
  }

  async transaction<Result>(work: (client: Queryable) => Promise<Result>): Promise<Result> {
    return work(this);
  }

  async checkReadiness(): Promise<DatabaseReadiness> {
    return {
      ready: true,
      database: "up",
      pgvector: "up",
      pgvectorVersion: "0.8.5",
      latencyMs: 0,
    };
  }

  async close(): Promise<void> {}
}

const jwtPrincipal = {
  kind: "jwt" as const,
  userId: "16e97ec6-e669-471b-a63d-9d1cd5df6e85",
  actorId: "b4940194-fbd5-46c6-b945-50f777972ac2",
  scopes: new Set<string>(),
};

function request(token?: string): FastifyRequest {
  return {
    headers: token === undefined ? {} : { authorization: `Bearer ${token}` },
  } as FastifyRequest;
}

test("JWT credentials are delegated to the JWT authenticator", async () => {
  let calls = 0;
  const jwt: Authenticator = {
    async authenticate() {
      calls += 1;
      return jwtPrincipal;
    },
  };
  const database = new AuthenticationDatabase();
  const authenticator = new BearerAuthenticator(database, jwt);

  const principal = await authenticator.authenticate(request("header.payload.signature"));

  assert.equal(principal, jwtPrincipal);
  assert.equal(calls, 1);
  assert.equal(database.calls.length, 0);
});

test("API keys are hash-looked-up, scope checked, and device bound", async () => {
  const database = new AuthenticationDatabase();
  const jwt: Authenticator = {
    async authenticate() {
      throw new Error("JWT authenticator must not receive an API key");
    },
  };
  const authenticator = new BearerAuthenticator(database, jwt);
  const secret = "exk_q7W2_example-secret-returned-only-once";

  const principal = await authenticator.authenticate(request(secret), ["records:read"]);

  assert.deepEqual(
    {
      kind: principal.kind,
      userId: principal.userId,
      actorId: principal.actorId,
      deviceId: principal.deviceId,
      scopes: [...principal.scopes],
    },
    {
      kind: "api_key",
      userId: "16e97ec6-e669-471b-a63d-9d1cd5df6e85",
      actorId: "51062dc2-7143-4960-9783-a14e2e83c64f",
      deviceId: "910b7ae2-b92c-429e-bb4d-fca20233f083",
      scopes: ["records:read"],
    },
  );
  assert.deepEqual(
    database.calls[0]?.values[0],
    createHash("sha256").update(secret, "utf8").digest(),
  );
  assert.match(database.calls[1]?.text ?? "", /UPDATE api_keys/);
});

test("API keys fail closed for missing keys and missing scopes", async () => {
  const jwt: Authenticator = { async authenticate() { return jwtPrincipal; } };
  const unknown = new BearerAuthenticator(new AuthenticationDatabase(false), jwt);
  const limited = new BearerAuthenticator(new AuthenticationDatabase(), jwt);

  await assert.rejects(
    unknown.authenticate(request("exk_unknown-api-key-value-with-enough-bytes")),
    (error: unknown) => error instanceof HttpProblem && error.status === 401,
  );
  await assert.rejects(
    limited.authenticate(request("exk_known-api-key-value-with-enough-bytes"), ["records:write"]),
    (error: unknown) =>
      error instanceof HttpProblem &&
      error.status === 403 &&
      error.code === "insufficient_scope",
  );
});
