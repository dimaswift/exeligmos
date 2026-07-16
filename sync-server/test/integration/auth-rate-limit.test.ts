import assert from "node:assert/strict";
import path from "node:path";
import test from "node:test";

import type { FastifyRequest } from "fastify";
import { Client, type QueryResultRow } from "pg";

import { PostgresAuthAttemptLimiter } from "../../src/auth/rate-limit.js";
import { createPostgresDatabase } from "../../src/db/database.js";
import { runMigrations } from "../../src/db/migrate.js";
import { HttpProblem } from "../../src/http/problem.js";

const databaseUrl = process.env.TEST_DATABASE_URL?.trim();

interface BucketStateRow extends QueryResultRow {
  readonly attempts: number;
  readonly hash_length: number;
}

test(
  "PostgreSQL auth limits are atomic and shared across server instances",
  { skip: databaseUrl === undefined || databaseUrl.length === 0 },
  async () => {
    assert.ok(databaseUrl);
    await runMigrations({
      databaseUrl,
      directory: path.resolve(process.cwd(), "db/migrations"),
    });
    const coordination = new Client({ connectionString: databaseUrl });
    await coordination.connect();
    await coordination.query(
      "SELECT pg_advisory_lock($1::bigint)",
      [2_026_071_402],
    );
    const firstDatabase = createTestDatabase(databaseUrl);
    const secondDatabase = createTestDatabase(databaseUrl);
    const first = new PostgresAuthAttemptLimiter(firstDatabase);
    const second = new PostgresAuthAttemptLimiter(secondDatabase);

    try {
      await firstDatabase.query("DELETE FROM auth_rate_limits");
      const registrationRequest = requestFrom("203.0.113.50");
      const registrationResults = await Promise.allSettled([
        first.checkRegistration(registrationRequest, "aurora"),
        second.checkRegistration(registrationRequest, "aurora"),
        first.checkRegistration(registrationRequest, "aurora"),
        second.checkRegistration(registrationRequest, "aurora"),
        first.checkRegistration(registrationRequest, "aurora"),
        second.checkRegistration(registrationRequest, "aurora"),
      ]);
      assert.equal(
        registrationResults.filter((result) => result.status === "fulfilled").length,
        5,
      );
      const registrationRejection = registrationResults.find(
        (result): result is PromiseRejectedResult => result.status === "rejected",
      );
      assert.ok(registrationRejection);
      assert.ok(registrationRejection.reason instanceof HttpProblem);
      assert.equal(registrationRejection.reason.code, "auth_rate_limited");
      assert.ok(Number(registrationRejection.reason.headers["retry-after"]) >= 1);

      const registrationBuckets = await firstDatabase.query<BucketStateRow>(
        `SELECT attempts, octet_length(bucket_hash) AS hash_length
         FROM auth_rate_limits
         ORDER BY attempts`,
      );
      assert.equal(registrationBuckets.rows.length, 2);
      assert.deepEqual(
        registrationBuckets.rows.map((row) => row.attempts),
        [6, 6],
      );
      assert.ok(registrationBuckets.rows.every((row) => row.hash_length === 32));

      // An expired fixed window resets atomically instead of retaining the ban.
      await firstDatabase.query(
        `UPDATE auth_rate_limits
         SET window_started_at = statement_timestamp() - interval '2 hours',
             expires_at = statement_timestamp() - interval '1 hour'`,
      );
      await second.checkRegistration(registrationRequest, "aurora");
      const resetBuckets = await firstDatabase.query<BucketStateRow>(
        `SELECT attempts, octet_length(bucket_hash) AS hash_length
         FROM auth_rate_limits`,
      );
      assert.ok(resetBuckets.rows.every((row) => row.attempts === 1));

      // Case-normalized account protection is shared even when source IPs vary.
      await firstDatabase.query("DELETE FROM auth_rate_limits");
      for (let attempt = 0; attempt < 10; attempt += 1) {
        const limiter = attempt % 2 === 0 ? first : second;
        await limiter.checkLogin(
          requestFrom(`198.51.100.${attempt + 1}`),
          attempt % 2 === 0 ? "Aurora.User" : "aurora.user",
        );
      }
      await assert.rejects(
        first.checkLogin(requestFrom("198.51.100.99"), "AURORA.USER"),
        isAuthRateLimit,
      );

      // Registration and login consume one shared cluster-wide Argon budget.
      await firstDatabase.query("DELETE FROM auth_rate_limits");
      for (let attempt = 0; attempt < 60; attempt += 1) {
        await first.checkRegistration(
          requestFrom(`192.0.2.${attempt + 1}`),
          `register-${attempt}`,
        );
        await second.checkLogin(
          requestFrom(`198.51.100.${attempt + 1}`),
          `login-${attempt}`,
        );
      }
      await assert.rejects(
        first.checkRegistration(requestFrom("203.0.113.200"), "over-budget"),
        isAuthRateLimit,
      );
    } finally {
      try {
        await firstDatabase.query("DELETE FROM auth_rate_limits");
      } finally {
        try {
          await Promise.all([firstDatabase.close(), secondDatabase.close()]);
        } finally {
          try {
            await coordination.query(
              "SELECT pg_advisory_unlock($1::bigint)",
              [2_026_071_402],
            );
          } finally {
            await coordination.end();
          }
        }
      }
    }
  },
);

function createTestDatabase(url: string) {
  return createPostgresDatabase({
    url,
    poolMax: 4,
    connectionTimeoutMs: 2_000,
    idleTimeoutMs: 5_000,
    readinessTimeoutMs: 1_000,
    statementTimeoutMs: 5_000,
    lockTimeoutMs: 1_000,
    idleInTransactionSessionTimeoutMs: 5_000,
  });
}

function requestFrom(ip: string): FastifyRequest {
  return { ip } as unknown as FastifyRequest;
}

function isAuthRateLimit(error: unknown): boolean {
  return error instanceof HttpProblem &&
    error.status === 429 &&
    error.code === "auth_rate_limited" &&
    Number(error.headers["retry-after"]) >= 1;
}
