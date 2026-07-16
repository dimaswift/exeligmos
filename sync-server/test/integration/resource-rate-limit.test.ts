import assert from "node:assert/strict";
import path from "node:path";
import test from "node:test";

import type { FastifyRequest } from "fastify";
import { Client, type QueryResultRow } from "pg";

import type { Principal } from "../../src/auth/principal.js";
import { createPostgresDatabase } from "../../src/db/database.js";
import { runMigrations } from "../../src/db/migrate.js";
import { HttpProblem } from "../../src/http/problem.js";
import {
  PostgresResourceRequestLimiter,
  type ResourceRateLimitPolicy,
} from "../../src/resources/rate-limit.js";

const databaseUrl = process.env.TEST_DATABASE_URL?.trim();

interface BucketStateRow extends QueryResultRow {
  readonly request_count: number;
  readonly hash_length: number;
}

const policy: ResourceRateLimitPolicy = {
  windowMs: 60_000,
  publicRecordReadsGlobal: 20,
  publicRecordReadsPerIp: 2,
  authenticatedReadsPerUser: 4,
  authenticatedReadsPerPrincipal: 2,
  authenticatedWritesPerUser: 3,
  authenticatedWritesPerPrincipal: 2,
};

test(
  "PostgreSQL resource limits are atomic and shared across replicas",
  { skip: databaseUrl === undefined || databaseUrl.length === 0 },
  async () => {
    assert.ok(databaseUrl);
    await runMigrations({
      databaseUrl,
      directory: path.resolve(process.cwd(), "db/migrations"),
    });
    const coordination = new Client({ connectionString: databaseUrl });
    await coordination.connect();
    await coordination.query("SELECT pg_advisory_lock($1::bigint)", [2_026_071_503]);
    const firstDatabase = testDatabase(databaseUrl);
    const secondDatabase = testDatabase(databaseUrl);
    const first = new PostgresResourceRequestLimiter(firstDatabase, policy);
    const second = new PostgresResourceRequestLimiter(secondDatabase, policy);

    try {
      await firstDatabase.query("DELETE FROM api_rate_limit_buckets");
      const publicRequest = requestFrom("203.0.113.40");
      const results = await Promise.allSettled([
        first.checkPublicRecordRead(publicRequest),
        second.checkPublicRecordRead(publicRequest),
        first.checkPublicRecordRead(publicRequest),
      ]);
      assert.equal(results.filter((result) => result.status === "fulfilled").length, 2);
      const rejected = results.find(
        (result): result is PromiseRejectedResult => result.status === "rejected",
      );
      assert.ok(rejected);
      assert.ok(isResourceLimit(rejected.reason));

      const publicBuckets = await firstDatabase.query<BucketStateRow>(
        `SELECT request_count, octet_length(bucket_hash) AS hash_length
         FROM api_rate_limit_buckets
         ORDER BY request_count`,
      );
      assert.deepEqual(publicBuckets.rows.map((row) => row.request_count), [3, 3]);
      assert.ok(publicBuckets.rows.every((row) => row.hash_length === 32));

      await firstDatabase.query(
        `UPDATE api_rate_limit_buckets
         SET window_started_at = statement_timestamp() - interval '2 minutes',
             expires_at = statement_timestamp() - interval '1 minute'`,
      );
      await second.checkPublicRecordRead(publicRequest);
      const reset = await firstDatabase.query<BucketStateRow>(
        `SELECT request_count, octet_length(bucket_hash) AS hash_length
         FROM api_rate_limit_buckets`,
      );
      assert.ok(reset.rows.every((row) => row.request_count === 1));

      await firstDatabase.query("DELETE FROM api_rate_limit_buckets");
      const firstPrincipal = principal("0ce129e6-cbf7-4731-8829-7592f69fb31e");
      const secondPrincipal = principal("60fc6b04-bb72-4cb0-8451-f72862fb3228");
      await first.checkAuthenticatedRead(publicRequest, firstPrincipal);
      await second.checkAuthenticatedRead(publicRequest, firstPrincipal);
      await assert.rejects(
        first.checkAuthenticatedRead(publicRequest, firstPrincipal),
        isResourceLimit,
      );
      await second.checkAuthenticatedRead(publicRequest, secondPrincipal);
      await assert.rejects(
        first.checkAuthenticatedRead(publicRequest, secondPrincipal),
        isResourceLimit,
      );
    } finally {
      try {
        await firstDatabase.query("DELETE FROM api_rate_limit_buckets");
      } finally {
        try {
          await Promise.all([firstDatabase.close(), secondDatabase.close()]);
        } finally {
          try {
            await coordination.query("SELECT pg_advisory_unlock($1::bigint)", [2_026_071_503]);
          } finally {
            await coordination.end();
          }
        }
      }
    }
  },
);

function testDatabase(url: string) {
  return createPostgresDatabase({
    url,
    poolMax: 4,
    connectionTimeoutMs: 2_000,
    idleTimeoutMs: 5_000,
    readinessTimeoutMs: 1_000,
    statementTimeoutMs: 5_000,
    lockTimeoutMs: 2_000,
    idleInTransactionSessionTimeoutMs: 5_000,
  });
}

function requestFrom(ip: string): FastifyRequest {
  return { ip } as unknown as FastifyRequest;
}

function principal(actorId: string): Principal {
  return {
    kind: "api_key",
    userId: "e42b4fde-8baf-4b95-8bc8-5395b68d0dd2",
    actorId,
    scopes: new Set(["records:read"]),
  };
}

function isResourceLimit(error: unknown): boolean {
  return error instanceof HttpProblem &&
    error.status === 429 &&
    error.code === "resource_rate_limited" &&
    Number(error.headers["retry-after"]) >= 1;
}
