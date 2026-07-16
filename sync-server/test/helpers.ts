import { generateKeyPairSync } from "node:crypto";
import type { ServerConfig } from "../src/config.js";
import type { QueryResultRow } from "pg";

import type {
  Database,
  DatabaseReadiness,
  DatabaseResult,
  Queryable,
} from "../src/db/database.js";

const TEST_JWT_PRIVATE_KEY_BASE64 = generateKeyPairSync("ed25519")
  .privateKey.export({ format: "der", type: "pkcs8" })
  .toString("base64");

export function testConfig(overrides: Partial<ServerConfig> = {}): ServerConfig {
  return {
    nodeEnv: "test",
    host: "127.0.0.1",
    port: 8788,
    logLevel: "silent",
    trustProxy: false,
    shutdownTimeoutMs: 1_000,
    auth: {
      registrationMode: "open",
      jwtIssuer: "exeligmos-test",
      jwtAudience: "exeligmos-test-clients",
      jwtKeyId: "test-key",
      jwtPrivateKeyPkcs8Base64: TEST_JWT_PRIVATE_KEY_BASE64,
      accessTokenTtlSeconds: 300,
      refreshTokenTtlSeconds: 3_600,
      argon2MaxConcurrency: 2,
    },
    database: {
      url: "postgresql://test:test@localhost:5432/exeligmos_test",
      poolMax: 2,
      // Integration files run concurrently against one PostgreSQL instance;
      // leave enough acquisition headroom for migration and Argon2-heavy tests.
      connectionTimeoutMs: 2_000,
      idleTimeoutMs: 1_000,
      readinessTimeoutMs: 100,
      statementTimeoutMs: 5_000,
      lockTimeoutMs: 1_000,
      idleInTransactionSessionTimeoutMs: 5_000,
    },
    media: {
      storageRoot: "var/test-media",
      maxByteLength: 2 * 1024 * 1024,
      uploadTtlMs: 60_000,
    },
    ...overrides,
  };
}

export class FakeDatabase implements Database {
  checks = 0;
  closes = 0;

  constructor(
    private readonly result: DatabaseReadiness = {
      ready: true,
      database: "up",
      pgvector: "up",
      pgvectorVersion: "0.8.5",
      latencyMs: 0,
    },
  ) {}

  async checkReadiness(): Promise<DatabaseReadiness> {
    this.checks += 1;
    return this.result;
  }

  async query<Row extends QueryResultRow = QueryResultRow>(
    _text: string,
    _values?: readonly unknown[],
  ): Promise<DatabaseResult<Row>> {
    throw new Error("FakeDatabase query handler was not configured for this test");
  }

  async transaction<Result>(
    work: (client: Queryable) => Promise<Result>,
  ): Promise<Result> {
    return work(this);
  }

  async close(): Promise<void> {
    this.closes += 1;
  }
}
