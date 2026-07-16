import { createHash, timingSafeEqual } from "node:crypto";

import { HttpProblem } from "../http/problem.js";

export type OwnerSecurityStatus = 400 | 401 | 403 | 404 | 409 | 412 | 422;

export class OwnerSecurityProblem extends HttpProblem {
  readonly etag: string | undefined;

  constructor(options: {
    readonly status: OwnerSecurityStatus;
    readonly code: string;
    readonly detail: string;
    readonly etag?: string;
    readonly extensions?: Readonly<Record<string, unknown>>;
  }) {
    super({
      status: options.status,
      code: options.code,
      type: `https://api.exeligmos.app/problems/${options.code.replaceAll("_", "-")}`,
      detail: options.detail,
      ...(options.extensions === undefined ? {} : { extensions: options.extensions }),
    });
    this.etag = options.etag;
  }
}

export interface PageCursor {
  readonly timestamp: string;
  readonly id: string;
}

interface CursorPayload extends PageCursor {
  readonly version: 1;
  readonly resource: string;
}

export function encodeCursor(resource: string, cursor: PageCursor): string {
  const payload: CursorPayload = { version: 1, resource, ...cursor };
  return Buffer.from(JSON.stringify(payload), "utf8").toString("base64url");
}

export function decodeCursor(resource: string, value: string | undefined): PageCursor | undefined {
  if (value === undefined) {
    return undefined;
  }

  try {
    const parsed = JSON.parse(Buffer.from(value, "base64url").toString("utf8")) as unknown;
    if (!isCursorPayload(parsed) || parsed.resource !== resource) {
      throw new Error("cursor does not match this collection");
    }
    return { timestamp: parsed.timestamp, id: parsed.id };
  } catch {
    throw new OwnerSecurityProblem({
      status: 400,
      code: "invalid_cursor",
      detail: "The cursor is invalid or belongs to another collection.",
    });
  }
}

function isCursorPayload(value: unknown): value is CursorPayload {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    return false;
  }

  const candidate = value as Partial<CursorPayload>;
  return (
    candidate.version === 1 &&
    typeof candidate.resource === "string" &&
    typeof candidate.timestamp === "string" &&
    !Number.isNaN(Date.parse(candidate.timestamp)) &&
    typeof candidate.id === "string" &&
    UUID_PATTERN.test(candidate.id)
  );
}

export function boundedLimit(value: number | undefined): number {
  if (value === undefined) {
    return 50;
  }
  if (!Number.isInteger(value) || value < 1 || value > 200) {
    throw new OwnerSecurityProblem({
      status: 400,
      code: "invalid_limit",
      detail: "The page limit must be an integer from 1 through 200.",
    });
  }
  return value;
}

export function resourceEtag(resource: string, id: string, revision: number): string {
  return `"${resource}-${id}-r${revision}"`;
}

export function requireMatchingEtag(actual: string, supplied: string | undefined): void {
  if (supplied === undefined || supplied !== actual) {
    throw new OwnerSecurityProblem({
      status: 412,
      code: "precondition_failed",
      detail: "If-Match does not identify the current resource revision.",
      etag: actual,
    });
  }
}

export function canonicalRequestHash(value: unknown): Buffer {
  return createHash("sha256").update(stableJson(value), "utf8").digest();
}

export function hashesMatch(left: Uint8Array, right: Uint8Array): boolean {
  return left.byteLength === right.byteLength && timingSafeEqual(left, right);
}

export function isoTimestamp(value: Date | string): string {
  return value instanceof Date ? value.toISOString() : new Date(value).toISOString();
}

export function optionalIsoTimestamp(value: Date | string | null): string | null {
  return value === null ? null : isoTimestamp(value);
}

export function assertIdempotencyKey(value: string | undefined): string {
  if (
    value === undefined ||
    value.length < 8 ||
    value.length > 255 ||
    !/^[\x21-\x7e]+$/.test(value)
  ) {
    throw new OwnerSecurityProblem({
      status: 400,
      code: "invalid_idempotency_key",
      detail: "Idempotency-Key must contain 8 to 255 non-whitespace characters.",
    });
  }
  return value;
}

export function assertUuid(value: string, label: string): void {
  if (!UUID_PATTERN.test(value)) {
    throw new OwnerSecurityProblem({
      status: 400,
      code: "invalid_identifier",
      detail: `${label} must be a UUID.`,
    });
  }
}

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function stableJson(value: unknown): string {
  if (value === null || typeof value !== "object") {
    return JSON.stringify(value);
  }
  if (Array.isArray(value)) {
    return `[${value.map(stableJson).join(",")}]`;
  }

  const object = value as Readonly<Record<string, unknown>>;
  return `{${Object.keys(object)
    .sort()
    .map((key) => `${JSON.stringify(key)}:${stableJson(object[key])}`)
    .join(",")}}`;
}
