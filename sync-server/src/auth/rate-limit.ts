import { createHash } from "node:crypto";

import type { FastifyRequest } from "fastify";
import type { QueryResultRow } from "pg";

import type { Database } from "../db/database.js";
import { HttpProblem } from "../http/problem.js";

export interface AuthAttemptLimiter {
  checkRegistration(request: FastifyRequest, login: string): Promise<void>;
  checkLogin(request: FastifyRequest, login: string): Promise<void>;
  checkRefresh(request: FastifyRequest): Promise<void>;
}

/** Explicit test/embedding opt-out; production uses the PostgreSQL limiter. */
export const NOOP_AUTH_ATTEMPT_LIMITER: AuthAttemptLimiter = {
  async checkRegistration(): Promise<void> {},
  async checkLogin(): Promise<void> {},
  async checkRefresh(): Promise<void> {},
};

interface BucketRow extends QueryResultRow {
  readonly attempts: number;
  readonly retry_after: number;
}

interface Rule {
  readonly namespace: string;
  readonly identity: string;
  readonly maximum: number;
  readonly windowMs: number;
}

/**
 * Shared fixed-window protection backed by PostgreSQL. The existing Fastify
 * limiter remains as a cheap per-process first line; these buckets make limits
 * survive restarts and apply across replicas.
 */
export class PostgresAuthAttemptLimiter implements AuthAttemptLimiter {
  constructor(private readonly database: Database) {}

  async checkRegistration(request: FastifyRequest, _login: string): Promise<void> {
    await this.consumePasswordWorkBudget();
    await this.consume({
      namespace: "register:ip",
      identity: request.ip,
      maximum: 5,
      windowMs: 60 * 60 * 1_000,
    });
  }

  async checkLogin(request: FastifyRequest, login: string): Promise<void> {
    const normalizedLogin = login.trim().toLowerCase();
    await this.consumePasswordWorkBudget();
    await this.consume({
      namespace: "login:ip",
      identity: request.ip,
      maximum: 30,
      windowMs: 15 * 60 * 1_000,
    });
    await this.consume({
      namespace: "login:account",
      identity: normalizedLogin,
      maximum: 10,
      windowMs: 15 * 60 * 1_000,
    });
  }

  async checkRefresh(request: FastifyRequest): Promise<void> {
    await this.consume({
      namespace: "refresh:ip",
      identity: request.ip,
      maximum: 30,
      windowMs: 60 * 1_000,
    });
  }

  private async consumePasswordWorkBudget(): Promise<void> {
    await this.consume({
      namespace: "password:global",
      identity: "all",
      maximum: 120,
      windowMs: 60 * 1_000,
    });
  }

  private async consume(rule: Rule): Promise<void> {
    const bucketHash = createHash("sha256")
      .update(rule.namespace, "utf8")
      .update("\0", "utf8")
      .update(rule.identity, "utf8")
      .digest();
    const result = await this.database.query<BucketRow>(
      `WITH cleanup AS (
         DELETE FROM auth_rate_limits
         WHERE bucket_hash IN (
           SELECT bucket_hash
           FROM auth_rate_limits
           WHERE expires_at <= statement_timestamp()
             AND bucket_hash <> $1
           ORDER BY expires_at
           LIMIT 100
         )
       ), upserted AS (
         INSERT INTO auth_rate_limits (
           bucket_hash, attempts, window_started_at, expires_at
         ) VALUES (
           $1, 1, statement_timestamp(),
           statement_timestamp() + ($2::bigint * interval '1 millisecond')
         )
         ON CONFLICT (bucket_hash) DO UPDATE SET
           attempts = CASE
             WHEN auth_rate_limits.expires_at <= statement_timestamp() THEN 1
             ELSE auth_rate_limits.attempts + 1
           END,
           window_started_at = CASE
             WHEN auth_rate_limits.expires_at <= statement_timestamp()
               THEN statement_timestamp()
             ELSE auth_rate_limits.window_started_at
           END,
           expires_at = CASE
             WHEN auth_rate_limits.expires_at <= statement_timestamp()
               THEN statement_timestamp() + ($2::bigint * interval '1 millisecond')
             ELSE auth_rate_limits.expires_at
           END
         RETURNING attempts, expires_at
       )
       SELECT
         attempts,
         GREATEST(
           1,
           CEIL(EXTRACT(EPOCH FROM (expires_at - statement_timestamp())))::integer
         ) AS retry_after
       FROM upserted`,
      [bucketHash, rule.windowMs],
    );
    const bucket = result.rows[0];
    if (bucket === undefined) {
      throw new Error("Authentication rate-limit bucket was not returned");
    }
    if (bucket.attempts > rule.maximum) {
      throw new HttpProblem({
        status: 429,
        code: "auth_rate_limited",
        title: "Too Many Requests",
        type: "urn:exeligmos:problem:auth-rate-limited",
        detail: "Too many authentication attempts. Retry after the current window.",
        headers: { "retry-after": String(bucket.retry_after) },
      });
    }
  }
}
