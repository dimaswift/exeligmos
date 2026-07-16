import type { QueryResultRow } from "pg";

import type { Principal } from "../auth/principal.js";
import type { Queryable } from "../db/database.js";
import {
  canonicalRequestHash,
  hashesMatch,
  OwnerSecurityProblem,
} from "./common.js";

interface IdempotencyRow extends QueryResultRow {
  readonly request_hash: Buffer;
  readonly response_status: number | null;
  readonly response_headers: Readonly<Record<string, unknown>> | null;
  readonly response_body: unknown;
  readonly expires_at: Date | string;
}

const IDEMPOTENCY_CLEANUP_LIMIT = 100;

export interface StoredJsonResponse<Body> {
  readonly status: number;
  readonly headers: Readonly<Record<string, string>>;
  readonly body: Body;
}

export interface IdempotentResult<Body> extends StoredJsonResponse<Body> {
  readonly replayed: boolean;
}

export async function executeIdempotentJson<Body>(options: {
  readonly client: Queryable;
  readonly principal: Principal;
  readonly operationId: string;
  readonly idempotencyKey: string;
  readonly request: unknown;
  readonly execute: () => Promise<StoredJsonResponse<Body>>;
  readonly now?: Date;
}): Promise<IdempotentResult<Body>> {
  const requestHash = canonicalRequestHash(options.request);
  const now = options.now ?? new Date();
  const existing = await lockExisting(
    options.client,
    options.principal.userId,
    options.operationId,
    options.idempotencyKey,
    now,
  );

  if (existing !== undefined) {
    await cleanupExpiredIdempotencyRows(
      options.client,
      options.principal.userId,
      options.operationId,
      options.idempotencyKey,
      now,
    );
    return replay(existing, requestHash);
  }

  const expiresAt = new Date(now.getTime() + 24 * 60 * 60 * 1_000);
  const inserted = await options.client.query(
    `INSERT INTO idempotency_keys (
       user_id, operation_id, idempotency_key, actor_type, actor_id,
       request_hash, expires_at
     )
     VALUES ($1, $2, $3, $4, $5, $6, $7)
     ON CONFLICT DO NOTHING
     RETURNING idempotency_key`,
    [
      options.principal.userId,
      options.operationId,
      options.idempotencyKey,
      options.principal.kind,
      options.principal.actorId,
      requestHash,
      expiresAt,
    ],
  );

  if (inserted.rowCount === 0) {
    const raced = await lockExisting(
      options.client,
      options.principal.userId,
      options.operationId,
      options.idempotencyKey,
      now,
    );
    if (raced === undefined) {
      throw new Error("Idempotency key conflict disappeared inside a transaction");
    }
    await cleanupExpiredIdempotencyRows(
      options.client,
      options.principal.userId,
      options.operationId,
      options.idempotencyKey,
      now,
    );
    return replay(raced, requestHash);
  }

  await cleanupExpiredIdempotencyRows(
    options.client,
    options.principal.userId,
    options.operationId,
    options.idempotencyKey,
    now,
  );
  const response = await options.execute();
  await options.client.query(
    `UPDATE idempotency_keys
     SET response_status = $4, response_headers = $5::jsonb, response_body = $6::jsonb
     WHERE user_id = $1 AND operation_id = $2 AND idempotency_key = $3`,
    [
      options.principal.userId,
      options.operationId,
      options.idempotencyKey,
      response.status,
      JSON.stringify(response.headers),
      JSON.stringify(response.body),
    ],
  );

  return { ...response, replayed: false };
}

export async function reserveSecretOnceIdempotency(options: {
  readonly client: Queryable;
  readonly principal: Principal;
  readonly operationId: string;
  readonly idempotencyKey: string;
  readonly request: unknown;
  readonly now?: Date;
}): Promise<void> {
  const requestHash = canonicalRequestHash(options.request);
  const now = options.now ?? new Date();
  const existing = await lockExisting(
    options.client,
    options.principal.userId,
    options.operationId,
    options.idempotencyKey,
    now,
  );
  if (existing !== undefined) {
    await cleanupExpiredIdempotencyRows(
      options.client,
      options.principal.userId,
      options.operationId,
      options.idempotencyKey,
      now,
    );
    if (!hashesMatch(existing.request_hash, requestHash)) {
      throw idempotencyConflict();
    }
    throw secretAlreadyReturned(existing.response_body);
  }

  const expiresAt = new Date(now.getTime() + 24 * 60 * 60 * 1_000);
  const inserted = await options.client.query(
    `INSERT INTO idempotency_keys (
       user_id, operation_id, idempotency_key, actor_type, actor_id,
       request_hash, response_status, response_headers, response_body, expires_at
     )
     VALUES ($1, $2, $3, $4, $5, $6, 409, '{}'::jsonb,
       '{"code":"api_key_secret_already_returned"}'::jsonb, $7)
     ON CONFLICT DO NOTHING
     RETURNING idempotency_key`,
    [
      options.principal.userId,
      options.operationId,
      options.idempotencyKey,
      options.principal.kind,
      options.principal.actorId,
      requestHash,
      expiresAt,
    ],
  );

  if (inserted.rowCount === 0) {
    const raced = await lockExisting(
      options.client,
      options.principal.userId,
      options.operationId,
      options.idempotencyKey,
      now,
    );
    await cleanupExpiredIdempotencyRows(
      options.client,
      options.principal.userId,
      options.operationId,
      options.idempotencyKey,
      now,
    );
    if (raced !== undefined && !hashesMatch(raced.request_hash, requestHash)) {
      throw idempotencyConflict();
    }
    throw secretAlreadyReturned(raced?.response_body);
  }

  await cleanupExpiredIdempotencyRows(
    options.client,
    options.principal.userId,
    options.operationId,
    options.idempotencyKey,
    now,
  );
}

export async function completeSecretOnceIdempotency(options: {
  readonly client: Queryable;
  readonly principal: Principal;
  readonly operationId: string;
  readonly idempotencyKey: string;
  readonly apiKeyId: string;
}): Promise<void> {
  await options.client.query(
    `UPDATE idempotency_keys
     SET response_headers = jsonb_build_object(
           'location', '/v1/api-keys/' || $4::text
         ),
         response_body = jsonb_build_object(
           'code', 'api_key_secret_already_returned',
           'apiKeyId', $4::text
         )
     WHERE user_id = $1 AND operation_id = $2 AND idempotency_key = $3`,
    [
      options.principal.userId,
      options.operationId,
      options.idempotencyKey,
      options.apiKeyId,
    ],
  );
}

async function cleanupExpiredIdempotencyRows(
  client: Queryable,
  userId: string,
  operationId: string,
  idempotencyKey: string,
  now: Date,
): Promise<void> {
  // Excluding the current key preserves its existing exact-key locking and
  // replay semantics. Other requests can skip rows this transaction cleans.
  await client.query(
    `WITH expired AS (
       SELECT user_id, operation_id, idempotency_key
       FROM idempotency_keys
       WHERE expires_at <= $4
         AND (user_id, operation_id, idempotency_key) <>
             ($1::uuid, $2::text, $3::text)
       ORDER BY expires_at
       LIMIT $5
       FOR UPDATE SKIP LOCKED
     )
     DELETE FROM idempotency_keys AS stored
     USING expired
     WHERE stored.user_id = expired.user_id
       AND stored.operation_id = expired.operation_id
       AND stored.idempotency_key = expired.idempotency_key`,
    [userId, operationId, idempotencyKey, now, IDEMPOTENCY_CLEANUP_LIMIT],
  );
}

async function lockExisting(
  client: Queryable,
  userId: string,
  operationId: string,
  idempotencyKey: string,
  now: Date,
): Promise<IdempotencyRow | undefined> {
  const result = await client.query<IdempotencyRow>(
    `SELECT request_hash, response_status, response_headers, response_body, expires_at
     FROM idempotency_keys
     WHERE user_id = $1 AND operation_id = $2 AND idempotency_key = $3
     FOR UPDATE`,
    [userId, operationId, idempotencyKey],
  );
  const row = result.rows[0];
  if (row === undefined || new Date(row.expires_at).getTime() > now.getTime()) {
    return row;
  }

  await client.query(
    `DELETE FROM idempotency_keys
     WHERE user_id = $1 AND operation_id = $2 AND idempotency_key = $3
       AND expires_at <= $4`,
    [userId, operationId, idempotencyKey, now],
  );
  return undefined;
}

function replay<Body>(row: IdempotencyRow, requestHash: Buffer): IdempotentResult<Body> {
  if (!hashesMatch(row.request_hash, requestHash)) {
    throw idempotencyConflict();
  }
  if (row.response_status === null || row.response_headers === null || row.response_body === null) {
    throw new OwnerSecurityProblem({
      status: 409,
      code: "idempotency_in_progress",
      detail: "A request using this idempotency key is still in progress.",
    });
  }

  return {
    status: row.response_status,
    headers: stringHeaders(row.response_headers),
    body: row.response_body as Body,
    replayed: true,
  };
}

function stringHeaders(value: Readonly<Record<string, unknown>>): Readonly<Record<string, string>> {
  return Object.fromEntries(
    Object.entries(value).filter((entry): entry is [string, string] => typeof entry[1] === "string"),
  );
}

function idempotencyConflict(): OwnerSecurityProblem {
  return new OwnerSecurityProblem({
    status: 409,
    code: "idempotency_conflict",
    detail: "This idempotency key was already used with a different request.",
  });
}

function secretAlreadyReturned(responseBody: unknown): OwnerSecurityProblem {
  const apiKeyId =
    responseBody !== null &&
    typeof responseBody === "object" &&
    "apiKeyId" in responseBody &&
    typeof responseBody.apiKeyId === "string"
      ? responseBody.apiKeyId
      : undefined;

  return new OwnerSecurityProblem({
    status: 409,
    code: "api_key_secret_already_returned",
    detail:
      "This API key was created already; its secret cannot be returned again. " +
      "Use the returned apiKeyId to inspect or revoke the credential.",
    ...(apiKeyId === undefined ? {} : { extensions: { apiKeyId } }),
  });
}
