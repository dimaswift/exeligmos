import { createHash } from "node:crypto";

import type { QueryResultRow } from "pg";

import type { Principal } from "../auth/principal.js";
import type { Database, Queryable } from "../db/database.js";
import { HttpProblem } from "../http/problem.js";

export type JsonObject = Record<string, unknown>;

export interface MutationResponse<Body = unknown> {
  readonly status: number;
  readonly headers: Readonly<Record<string, string>>;
  readonly body: Body;
  readonly replayed?: boolean;
}

interface StoredIdempotencyRow extends QueryResultRow {
  readonly request_hash: Buffer;
  readonly response_status: number | null;
  readonly response_headers: unknown;
  readonly response_body: unknown;
}

interface CursorEnvelope {
  readonly v: 1;
  readonly kind: string;
  readonly signature: string;
  readonly sort: string;
  readonly id: string;
}

const IDEMPOTENCY_CLEANUP_LIMIT = 100;

export class PreconditionFailedProblem extends HttpProblem {
  constructor(readonly currentEtag: string) {
    super({
      status: 412,
      code: "etag_mismatch",
      title: "Precondition Failed",
      type: "urn:exeligmos:problem:etag-mismatch",
      detail: "If-Match does not match the current resource revision.",
      headers: { etag: currentEtag },
    });
  }
}

export function resourceEtag(kind: "record" | "event", id: string, revision: number): string {
  return `"${kind}-${id}-r${revision}"`;
}

export function requireMatchingEtag(ifMatch: string, currentEtag: string): void {
  if (ifMatch !== currentEtag) {
    throw new PreconditionFailedProblem(currentEtag);
  }
}

export function assertApiKeyDevice(principal: Principal, requestedDeviceId: string): void {
  if (
    principal.kind === "api_key" &&
    (principal.deviceId === undefined || principal.deviceId !== requestedDeviceId)
  ) {
    throw new HttpProblem({
      status: 403,
      code: "device_binding_mismatch",
      title: "Forbidden",
      type: "urn:exeligmos:problem:device-binding-mismatch",
      detail: "An API key can write only through its bound device.",
    });
  }
}

export async function assertActiveOwnedDevice(
  queryable: Queryable,
  userId: string,
  deviceId: string,
): Promise<void> {
  const result = await queryable.query(
    `SELECT 1
     FROM devices
     WHERE user_id = $1 AND id = $2 AND revoked_at IS NULL
     FOR SHARE`,
    [userId, deviceId],
  );
  if (result.rowCount === 0) {
    throw new HttpProblem({
      status: 422,
      code: "invalid_device",
      title: "Unprocessable Content",
      type: "urn:exeligmos:problem:invalid-device",
      detail: "The selected device does not exist or has been revoked.",
    });
  }
}

export async function writeMutationAudit(
  queryable: Queryable,
  principal: Principal,
  action: string,
  entityType: "record" | "event",
  entityId: string,
  requestId: string,
): Promise<void> {
  await queryable.query(
    `INSERT INTO audit_log (
       user_id, actor_type, actor_id, action, entity_type, entity_id, request_id
     ) VALUES ($1, $2, $3, $4, $5, $6, $7)`,
    [
      principal.userId,
      principal.kind,
      principal.actorId,
      action,
      entityType,
      entityId,
      requestId,
    ],
  );
}

export function cursorSignature(binding: unknown): string {
  return createHash("sha256").update(canonicalJson(binding)).digest("base64url");
}

export function encodeCursor(
  kind: string,
  signature: string,
  sort: string,
  id: string,
): string {
  const envelope: CursorEnvelope = { v: 1, kind, signature, sort, id };
  return Buffer.from(JSON.stringify(envelope), "utf8").toString("base64url");
}

export function decodeCursor(
  value: string | undefined,
  expectedKind: string,
  expectedSignature: string,
): { readonly sort: string; readonly id: string } | undefined {
  if (value === undefined) {
    return undefined;
  }

  try {
    const decoded: unknown = JSON.parse(Buffer.from(value, "base64url").toString("utf8"));
    if (!isCursorEnvelope(decoded)) {
      throw new Error("Malformed cursor");
    }
    if (decoded.kind !== expectedKind || decoded.signature !== expectedSignature) {
      throw new Error("Cursor does not belong to this query");
    }
    if (!Number.isFinite(Date.parse(decoded.sort)) || !isUuid(decoded.id)) {
      throw new Error("Invalid cursor tuple");
    }
    return { sort: decoded.sort, id: decoded.id };
  } catch {
    throw new HttpProblem({
      status: 400,
      code: "invalid_cursor",
      title: "Bad Request",
      type: "urn:exeligmos:problem:invalid-cursor",
      detail: "The cursor is malformed or does not belong to this query.",
    });
  }
}

export function parsePageLimit(value: unknown): number {
  if (value === undefined) {
    return 50;
  }
  const parsed = typeof value === "number" ? value : Number(value);
  if (!Number.isInteger(parsed) || parsed < 1 || parsed > 200) {
    throw invalidRequest("limit must be an integer between 1 and 200.");
  }
  return parsed;
}

export function optionalDate(value: unknown, name: string): string | undefined {
  if (value === undefined) {
    return undefined;
  }
  if (
    typeof value !== "string" ||
    !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})$/.test(value) ||
    !Number.isFinite(Date.parse(value))
  ) {
    throw invalidRequest(`${name} must be an RFC 3339 date-time.`);
  }
  return new Date(value).toISOString();
}

export function optionalString(value: unknown, name: string): string | undefined {
  if (value === undefined) {
    return undefined;
  }
  if (typeof value !== "string" || value.length === 0) {
    throw invalidRequest(`${name} must be a non-empty string.`);
  }
  return value;
}

export function stringArray(value: unknown): readonly string[] | undefined {
  if (value === undefined) {
    return undefined;
  }
  if (Array.isArray(value)) {
    return value.map((item) => String(item));
  }
  return [String(value)];
}

export function invalidRequest(detail: string, code = "invalid_request"): HttpProblem {
  return new HttpProblem({
    status: 400,
    code,
    title: "Bad Request",
    type: `urn:exeligmos:problem:${code.replaceAll("_", "-")}`,
    detail,
  });
}

export function unprocessable(detail: string, code = "invalid_resource"): HttpProblem {
  const normalizedCode = code
    .replaceAll(/([a-z0-9])([A-Z])/g, "$1_$2")
    .replaceAll(/[^A-Za-z0-9_]/g, "_")
    .toLowerCase();
  return new HttpProblem({
    status: 422,
    code: normalizedCode,
    title: "Unprocessable Content",
    type: `urn:exeligmos:problem:${normalizedCode.replaceAll("_", "-")}`,
    detail,
    extensions: {
      errors: [{ path: "/", code: normalizedCode, message: detail }],
    },
  });
}

export function notFound(resource: "record" | "event" | "template"): HttpProblem {
  return new HttpProblem({
    status: 404,
    code: `${resource}_not_found`,
    title: "Not Found",
    type: `urn:exeligmos:problem:${resource}-not-found`,
    detail: `The requested ${resource} does not exist.`,
  });
}

export async function executeIdempotentMutation<Body>(
  database: Database,
  principal: Principal,
  operationId: string,
  idempotencyKey: string,
  requestFingerprint: unknown,
  work: (queryable: Queryable) => Promise<MutationResponse<Body>>,
): Promise<MutationResponse<Body>> {
  if (
    idempotencyKey.length < 8 ||
    idempotencyKey.length > 255 ||
    !/^[\x21-\x7e]+$/.test(idempotencyKey)
  ) {
    throw invalidRequest(
      "Idempotency-Key must contain 8 to 255 visible non-whitespace characters.",
      "invalid_idempotency_key",
    );
  }

  const requestHash = createHash("sha256")
    .update(canonicalJson(requestFingerprint))
    .digest();

  return database.transaction(async (queryable) => {
    await queryable.query(
      `DELETE FROM idempotency_keys
       WHERE user_id = $1 AND operation_id = $2 AND idempotency_key = $3
         AND expires_at <= now()`,
      [principal.userId, operationId, idempotencyKey],
    );

    const inserted = await queryable.query(
      `INSERT INTO idempotency_keys (
         user_id, operation_id, idempotency_key, actor_type, actor_id,
         request_hash, expires_at
       ) VALUES ($1, $2, $3, $4, $5, $6, now() + interval '24 hours')
       ON CONFLICT (user_id, operation_id, idempotency_key) DO NOTHING
       RETURNING request_hash, response_status, response_headers, response_body`,
      [
        principal.userId,
        operationId,
        idempotencyKey,
        principal.kind,
        principal.actorId,
        requestHash,
      ],
    );

    if (inserted.rowCount === 0) {
      const existing = await queryable.query<StoredIdempotencyRow>(
        `SELECT request_hash, response_status, response_headers, response_body
         FROM idempotency_keys
         WHERE user_id = $1 AND operation_id = $2 AND idempotency_key = $3
         FOR UPDATE`,
        [principal.userId, operationId, idempotencyKey],
      );
      await cleanupExpiredIdempotencyRows(
        queryable,
        principal.userId,
        operationId,
        idempotencyKey,
      );
      const row = existing.rows[0];
      if (row === undefined || !row.request_hash.equals(requestHash)) {
        throw new HttpProblem({
          status: 409,
          code: "idempotency_conflict",
          title: "Conflict",
          type: "urn:exeligmos:problem:idempotency-conflict",
          detail: "This Idempotency-Key was already used for a different request.",
        });
      }
      if (row.response_status === null) {
        throw new HttpProblem({
          status: 409,
          code: "idempotency_in_progress",
          title: "Conflict",
          type: "urn:exeligmos:problem:idempotency-in-progress",
          detail: "The original mutation has not completed.",
        });
      }
      return {
        status: row.response_status,
        headers: stringRecord(row.response_headers),
        body: row.response_body as Body,
        replayed: true,
      };
    }

    await cleanupExpiredIdempotencyRows(
      queryable,
      principal.userId,
      operationId,
      idempotencyKey,
    );
    const response = await work(queryable);
    await queryable.query(
      `UPDATE idempotency_keys
       SET response_status = $4, response_headers = $5::jsonb, response_body = $6::jsonb
       WHERE user_id = $1 AND operation_id = $2 AND idempotency_key = $3`,
      [
        principal.userId,
        operationId,
        idempotencyKey,
        response.status,
        JSON.stringify(response.headers),
        response.body === undefined ? null : JSON.stringify(response.body),
      ],
    );
    return response;
  });
}

async function cleanupExpiredIdempotencyRows(
  queryable: Queryable,
  userId: string,
  operationId: string,
  idempotencyKey: string,
): Promise<void> {
  // Leave the current key to the exact-key path that already locked or
  // reserved it. SKIP LOCKED lets concurrent mutations share cleanup work.
  await queryable.query(
    `WITH expired AS (
       SELECT user_id, operation_id, idempotency_key
       FROM idempotency_keys
       WHERE expires_at <= now()
         AND (user_id, operation_id, idempotency_key) <>
             ($1::uuid, $2::text, $3::text)
       ORDER BY expires_at
       LIMIT $4
       FOR UPDATE SKIP LOCKED
     )
     DELETE FROM idempotency_keys AS stored
     USING expired
     WHERE stored.user_id = expired.user_id
       AND stored.operation_id = expired.operation_id
       AND stored.idempotency_key = expired.idempotency_key`,
    [userId, operationId, idempotencyKey, IDEMPOTENCY_CLEANUP_LIMIT],
  );
}

export function canonicalJson(value: unknown): string {
  if (value === null) {
    return "null";
  }
  if (typeof value === "string" || typeof value === "boolean") {
    return JSON.stringify(value);
  }
  if (typeof value === "number") {
    if (!Number.isFinite(value)) {
      throw invalidRequest("The request contains a non-finite number.");
    }
    return JSON.stringify(value);
  }
  if (Array.isArray(value)) {
    return `[${value.map((item) => canonicalJson(item === undefined ? null : item)).join(",")}]`;
  }
  if (typeof value === "object") {
    const entries = Object.entries(value as Record<string, unknown>)
      .filter(([, child]) => child !== undefined)
      .sort(([left], [right]) => (left < right ? -1 : left > right ? 1 : 0));
    return `{${entries
      .map(([key, child]) => `${JSON.stringify(key)}:${canonicalJson(child)}`)
      .join(",")}}`;
  }
  throw invalidRequest("The request contains a value that cannot be serialized.");
}

/** Applies RFC 7396 object merge semantics and returns a detached JSON object. */
export function mergeJsonObject(
  target: Readonly<Record<string, unknown>>,
  patch: Readonly<Record<string, unknown>>,
): JsonObject {
  const result: JsonObject = { ...target };
  for (const [key, value] of Object.entries(patch)) {
    if (value === null) {
      delete result[key];
    } else if (isPlainObject(value)) {
      const current = result[key];
      result[key] = mergeJsonObject(isPlainObject(current) ? current : {}, value);
    } else if (Array.isArray(value)) {
      result[key] = structuredClone(value);
    } else {
      result[key] = value;
    }
  }
  return result;
}

export function translateDatabaseError(error: unknown): never {
  const code = databaseErrorCode(error);
  if (code === "23505") {
    throw new HttpProblem({
      status: 409,
      code: "resource_conflict",
      title: "Conflict",
      type: "urn:exeligmos:problem:resource-conflict",
      detail: "A resource with the same stable identifier already exists.",
    });
  }
  if (code === "23503" || code === "23514") {
    throw unprocessable("The mutation violates a resource relationship or domain constraint.");
  }
  throw error;
}

export function databaseErrorCode(error: unknown): string | undefined {
  if (error instanceof Error && "code" in error) {
    return String((error as Error & { readonly code: unknown }).code);
  }
  return undefined;
}

export function isoDate(value: Date | string): string {
  return value instanceof Date ? value.toISOString() : new Date(value).toISOString();
}

function isCursorEnvelope(value: unknown): value is CursorEnvelope {
  if (value === null || typeof value !== "object") {
    return false;
  }
  const candidate = value as Partial<CursorEnvelope>;
  return (
    candidate.v === 1 &&
    typeof candidate.kind === "string" &&
    typeof candidate.signature === "string" &&
    typeof candidate.sort === "string" &&
    typeof candidate.id === "string"
  );
}

function isUuid(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(
    value,
  );
}

function stringRecord(value: unknown): Readonly<Record<string, string>> {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    return {};
  }
  return Object.fromEntries(
    Object.entries(value as Record<string, unknown>).map(([key, child]) => [key, String(child)]),
  );
}

function isPlainObject(value: unknown): value is JsonObject {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}
