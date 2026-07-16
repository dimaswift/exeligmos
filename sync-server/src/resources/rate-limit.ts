import { createHash } from "node:crypto";

import type { FastifyRequest } from "fastify";
import type { QueryResultRow } from "pg";

import type { Principal } from "../auth/principal.js";
import type { Database } from "../db/database.js";
import { HttpProblem } from "../http/problem.js";

export interface ResourceRateLimitPolicy {
  readonly windowMs: number;
  readonly publicRecordReadsGlobal: number;
  readonly publicRecordReadsPerIp: number;
  readonly authenticatedReadsPerUser: number;
  readonly authenticatedReadsPerPrincipal: number;
  readonly authenticatedWritesPerUser: number;
  readonly authenticatedWritesPerPrincipal: number;
}

export const DEFAULT_RESOURCE_RATE_LIMIT_POLICY: ResourceRateLimitPolicy = {
  windowMs: 60_000,
  publicRecordReadsGlobal: 3_000,
  publicRecordReadsPerIp: 120,
  authenticatedReadsPerUser: 1_200,
  authenticatedReadsPerPrincipal: 600,
  authenticatedWritesPerUser: 240,
  authenticatedWritesPerPrincipal: 120,
};

export interface ResourceRequestLimiter {
  checkPublicRecordRead(request: FastifyRequest): Promise<void>;
  checkAuthenticatedRead(request: FastifyRequest, principal: Principal): Promise<void>;
  checkAuthenticatedWrite(request: FastifyRequest, principal: Principal): Promise<void>;
}

/** Explicit route-test and embedding opt-out. buildApp installs the shared limiter. */
export const NOOP_RESOURCE_REQUEST_LIMITER: ResourceRequestLimiter = {
  async checkPublicRecordRead(): Promise<void> {},
  async checkAuthenticatedRead(): Promise<void> {},
  async checkAuthenticatedWrite(): Promise<void> {},
};

interface Rule {
  readonly namespace: string;
  readonly identity: string;
  readonly maximum: number;
  readonly policyName: string;
}

interface ViolationRow extends QueryResultRow {
  readonly policy_name: string;
  readonly maximum: number;
  readonly request_count: number;
  readonly retry_after: number;
}

/**
 * Cluster-wide fixed-window limits. One PostgreSQL statement atomically advances
 * both aggregate-user and individual-principal buckets, preventing extra API
 * keys or sessions from bypassing the user's total resource budget. Identities
 * are SHA-256 hashed before leaving the process.
 */
export class PostgresResourceRequestLimiter implements ResourceRequestLimiter {
  constructor(
    private readonly database: Database,
    private readonly policy: ResourceRateLimitPolicy = DEFAULT_RESOURCE_RATE_LIMIT_POLICY,
  ) {
    assertPolicy(policy);
  }

  async checkPublicRecordRead(request: FastifyRequest): Promise<void> {
    await this.consume([
      {
        namespace: "public-records:read:global",
        identity: "all",
        maximum: this.policy.publicRecordReadsGlobal,
        policyName: "public-record-read-global",
      },
      {
        namespace: "public-records:read:ip",
        identity: request.ip,
        maximum: this.policy.publicRecordReadsPerIp,
        policyName: "public-record-read-ip",
      },
    ]);
  }

  async checkAuthenticatedRead(
    _request: FastifyRequest,
    principal: Principal,
  ): Promise<void> {
    await this.consume(this.principalRules("read", principal));
  }

  async checkAuthenticatedWrite(
    _request: FastifyRequest,
    principal: Principal,
  ): Promise<void> {
    await this.consume(this.principalRules("write", principal));
  }

  private principalRules(operation: "read" | "write", principal: Principal): readonly Rule[] {
    const userMaximum = operation === "read"
      ? this.policy.authenticatedReadsPerUser
      : this.policy.authenticatedWritesPerUser;
    const principalMaximum = operation === "read"
      ? this.policy.authenticatedReadsPerPrincipal
      : this.policy.authenticatedWritesPerPrincipal;
    return [
      {
        namespace: `resources:${operation}:user`,
        identity: principal.userId,
        maximum: userMaximum,
        policyName: `authenticated-resource-${operation}-user`,
      },
      {
        namespace: `resources:${operation}:principal:${principal.kind}`,
        identity: `${principal.userId}\0${principal.actorId}`,
        maximum: principalMaximum,
        policyName: `authenticated-resource-${operation}-principal`,
      },
    ];
  }

  private async consume(rules: readonly Rule[]): Promise<void> {
    const hashHex = rules.map((rule) =>
      createHash("sha256")
        .update(rule.namespace, "utf8")
        .update("\0", "utf8")
        .update(rule.identity, "utf8")
        .digest("hex")
    );
    const result = await this.database.query<ViolationRow>(
      `WITH input AS (
         SELECT
           decode(hash_hex, 'hex') AS bucket_hash,
           maximum,
           policy_name
         FROM unnest($1::text[], $2::integer[], $3::text[])
           AS rule(hash_hex, maximum, policy_name)
       ), cleanup AS (
         DELETE FROM api_rate_limit_buckets
         WHERE bucket_hash IN (
           SELECT bucket_hash
           FROM api_rate_limit_buckets
           WHERE expires_at <= statement_timestamp()
             AND bucket_hash NOT IN (SELECT bucket_hash FROM input)
           ORDER BY expires_at
           LIMIT 100
         )
       ), upserted AS (
         INSERT INTO api_rate_limit_buckets (
           bucket_hash, request_count, window_started_at, expires_at
         )
         SELECT
           bucket_hash,
           1,
           statement_timestamp(),
           statement_timestamp() + ($4::bigint * interval '1 millisecond')
         FROM input
         ON CONFLICT (bucket_hash) DO UPDATE SET
           request_count = CASE
             WHEN api_rate_limit_buckets.expires_at <= statement_timestamp() THEN 1
             ELSE api_rate_limit_buckets.request_count + 1
           END,
           window_started_at = CASE
             WHEN api_rate_limit_buckets.expires_at <= statement_timestamp()
               THEN statement_timestamp()
             ELSE api_rate_limit_buckets.window_started_at
           END,
           expires_at = CASE
             WHEN api_rate_limit_buckets.expires_at <= statement_timestamp()
               THEN statement_timestamp() + ($4::bigint * interval '1 millisecond')
             ELSE api_rate_limit_buckets.expires_at
           END
         RETURNING bucket_hash, request_count, expires_at
       )
       SELECT
         input.policy_name,
         input.maximum,
         upserted.request_count,
         GREATEST(
           1,
           CEIL(EXTRACT(EPOCH FROM (upserted.expires_at - statement_timestamp())))::integer
         ) AS retry_after
       FROM upserted
       JOIN input USING (bucket_hash)
       WHERE upserted.request_count > input.maximum
       ORDER BY upserted.request_count - input.maximum DESC, input.policy_name
       LIMIT 1`,
      [
        hashHex,
        rules.map((rule) => rule.maximum),
        rules.map((rule) => rule.policyName),
        this.policy.windowMs,
      ],
    );
    const violation = result.rows[0];
    if (violation === undefined) {
      return;
    }

    throw new HttpProblem({
      status: 429,
      code: "resource_rate_limited",
      title: "Too Many Requests",
      type: "urn:exeligmos:problem:resource-rate-limited",
      detail: "The resource request rate limit was exceeded. Retry after the current window.",
      headers: { "retry-after": String(violation.retry_after) },
      extensions: {
        policy: violation.policy_name,
        limit: violation.maximum,
        windowSeconds: Math.ceil(this.policy.windowMs / 1_000),
      },
    });
  }
}

function assertPolicy(policy: ResourceRateLimitPolicy): void {
  const values = Object.values(policy);
  if (values.some((value) => !Number.isSafeInteger(value) || value < 1)) {
    throw new Error("Resource rate-limit policy values must be positive safe integers");
  }
}
