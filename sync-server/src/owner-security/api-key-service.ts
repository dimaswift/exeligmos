import { createHash, randomBytes } from "node:crypto";

import type { QueryResultRow } from "pg";

import {
  API_KEY_SCOPES,
  type ApiKeyScope,
  type Principal,
} from "../auth/principal.js";
import type { Database, Queryable } from "../db/database.js";
import {
  assertUuid,
  boundedLimit,
  decodeCursor,
  encodeCursor,
  isoTimestamp,
  optionalIsoTimestamp,
  OwnerSecurityProblem,
  resourceEtag,
} from "./common.js";
import {
  completeSecretOnceIdempotency,
  reserveSecretOnceIdempotency,
} from "./idempotency.js";
import type {
  ApiKeyView,
  CreateApiKeyInput,
  CreatedApiKeyView,
  Page,
  Versioned,
} from "./models.js";

interface ApiKeyRow extends QueryResultRow {
  readonly id: string;
  readonly user_id: string;
  readonly device_id: string;
  readonly name: string;
  readonly key_prefix: string;
  readonly scopes: ApiKeyScope[];
  readonly revision: string | number;
  readonly created_at: Date | string;
  readonly expires_at: Date | string | null;
  readonly revoked_at: Date | string | null;
  readonly last_used_at: Date | string | null;
}

interface DeviceStateRow extends QueryResultRow {
  readonly id: string;
}

const API_KEY_COLUMNS = `
  id, user_id, device_id, name, key_prefix, scopes, revision,
  created_at, expires_at, revoked_at, last_used_at
`;

const VALID_SCOPES = new Set<string>(API_KEY_SCOPES);

export interface ApiKeyServiceOptions {
  readonly generateSecret?: () => string;
  readonly now?: () => Date;
}

export class ApiKeyService {
  private readonly generateSecret: () => string;
  private readonly now: () => Date;

  constructor(
    private readonly database: Database,
    options: ApiKeyServiceOptions = {},
  ) {
    this.generateSecret = options.generateSecret ?? defaultSecret;
    this.now = options.now ?? (() => new Date());
  }

  async list(options: {
    readonly userId: string;
    readonly cursor?: string;
    readonly limit?: number;
  }): Promise<Page<ApiKeyView>> {
    const limit = boundedLimit(options.limit);
    const cursor = decodeCursor("api-keys", options.cursor);
    const values: unknown[] = [options.userId];
    let cursorSql = "";
    if (cursor !== undefined) {
      values.push(cursor.timestamp, cursor.id);
      cursorSql = "AND (created_at, id) < ($2::timestamptz, $3::uuid)";
    }
    values.push(limit + 1);

    const result = await this.database.query<ApiKeyRow>(
      `SELECT ${API_KEY_COLUMNS}
       FROM api_keys
       WHERE user_id = $1
       ${cursorSql}
       ORDER BY created_at DESC, id DESC
       LIMIT $${values.length}`,
      values,
    );
    const hasMore = result.rows.length > limit;
    const rows = result.rows.slice(0, limit);
    const last = rows.at(-1);
    return {
      data: rows.map(apiKeyView),
      hasMore,
      ...(hasMore && last !== undefined
        ? {
            nextCursor: encodeCursor("api-keys", {
              timestamp: isoTimestamp(last.created_at),
              id: last.id,
            }),
          }
        : {}),
    };
  }

  async get(userId: string, apiKeyId: string): Promise<Versioned<ApiKeyView>> {
    assertUuid(apiKeyId, "apiKeyId");
    const row = await findApiKey(this.database, userId, apiKeyId, false);
    if (row === undefined) {
      throw notFound();
    }
    return versionedApiKey(row);
  }

  async create(options: {
    readonly principal: Principal;
    readonly input: CreateApiKeyInput;
    readonly idempotencyKey: string;
    readonly requestId: string;
  }): Promise<CreatedApiKeyView & { readonly etag: string; readonly location: string }> {
    validateCreateApiKey(options.input, this.now());

    try {
      return await this.database.transaction(async (client) => {
        await reserveSecretOnceIdempotency({
          client,
          principal: options.principal,
          operationId: "createApiKey",
          idempotencyKey: options.idempotencyKey,
          request: options.input,
          now: this.now(),
        });

        const device = await client.query<DeviceStateRow>(
          `SELECT id
           FROM devices
           WHERE user_id = $1 AND id = $2 AND revoked_at IS NULL
           FOR UPDATE`,
          [options.principal.userId, options.input.deviceId],
        );
        if (device.rows[0] === undefined) {
          throw new OwnerSecurityProblem({
            status: 422,
            code: "invalid_api_key_device",
            detail: "API keys must be bound to an active device owned by this user.",
          });
        }

        const secret = this.generateSecret();
        validateGeneratedSecret(secret);
        const prefix = secret.slice(0, 12);
        const keyHash = createHash("sha256").update(secret, "utf8").digest();
        const result = await client.query<ApiKeyRow>(
          `INSERT INTO api_keys (
             user_id, device_id, name, key_prefix, key_hash, scopes, expires_at
           )
           VALUES ($1, $2, $3, $4, $5, $6::text[], $7)
           RETURNING ${API_KEY_COLUMNS}`,
          [
            options.principal.userId,
            options.input.deviceId,
            options.input.name,
            prefix,
            keyHash,
            [...options.input.scopes],
            options.input.expiresAt ?? null,
          ],
        );
        const row = result.rows[0];
        if (row === undefined) {
          throw new Error("API key insert did not return a row");
        }
        await completeSecretOnceIdempotency({
          client,
          principal: options.principal,
          operationId: "createApiKey",
          idempotencyKey: options.idempotencyKey,
          apiKeyId: row.id,
        });
        await audit(client, options.principal, options.requestId, "api_key.create", row.id, {
          deviceId: row.device_id,
          scopes: row.scopes,
        });

        return {
          key: apiKeyView(row),
          secret,
          etag: apiKeyEtag(row),
          location: `/v1/api-keys/${row.id}`,
        };
      });
    } catch (error) {
      if (isConstraint(error, "api_keys_expires_at_check")) {
        throw new OwnerSecurityProblem({
          status: 422,
          code: "invalid_api_key",
          detail: "Invalid API key request: expiresAt must still be in the future.",
        });
      }
      throw error;
    }
  }

  async revoke(options: {
    readonly principal: Principal;
    readonly apiKeyId: string;
    readonly requestId: string;
  }): Promise<void> {
    assertUuid(options.apiKeyId, "apiKeyId");
    await this.database.transaction(async (client) => {
      const row = await findApiKey(
        client,
        options.principal.userId,
        options.apiKeyId,
        true,
      );
      if (row === undefined) {
        throw notFound();
      }
      if (row.revoked_at !== null) {
        return;
      }

      await client.query(
        `UPDATE api_keys
         SET revoked_at = clock_timestamp()
         WHERE user_id = $1 AND id = $2 AND revoked_at IS NULL`,
        [options.principal.userId, options.apiKeyId],
      );
      await audit(client, options.principal, options.requestId, "api_key.revoke", row.id, {});
    });
  }
}

function isConstraint(error: unknown, constraint: string): boolean {
  return (
    error !== null &&
    typeof error === "object" &&
    "code" in error &&
    error.code === "23514" &&
    "constraint" in error &&
    error.constraint === constraint
  );
}

async function findApiKey(
  client: Queryable,
  userId: string,
  apiKeyId: string,
  forUpdate: boolean,
): Promise<ApiKeyRow | undefined> {
  const result = await client.query<ApiKeyRow>(
    `SELECT ${API_KEY_COLUMNS}
     FROM api_keys
     WHERE user_id = $1 AND id = $2
     ${forUpdate ? "FOR UPDATE" : ""}`,
    [userId, apiKeyId],
  );
  return result.rows[0];
}

function versionedApiKey(row: ApiKeyRow): Versioned<ApiKeyView> {
  return { view: apiKeyView(row), etag: apiKeyEtag(row) };
}

function apiKeyEtag(row: ApiKeyRow): string {
  return resourceEtag("api-key", row.id, Number(row.revision));
}

function apiKeyView(row: ApiKeyRow): ApiKeyView {
  return {
    id: row.id,
    userId: row.user_id,
    deviceId: row.device_id,
    name: row.name,
    prefix: row.key_prefix,
    scopes: row.scopes,
    createdAt: isoTimestamp(row.created_at),
    expiresAt: optionalIsoTimestamp(row.expires_at),
    revokedAt: optionalIsoTimestamp(row.revoked_at),
    lastUsedAt: optionalIsoTimestamp(row.last_used_at),
  };
}

function validateCreateApiKey(input: CreateApiKeyInput, now: Date): void {
  assertUuid(input.deviceId, "deviceId");
  if (input.name.trim() !== input.name || input.name.length < 1 || input.name.length > 120) {
    invalidApiKey("name must contain 1 to 120 trimmed characters");
  }
  if (
    input.scopes.length < 1 ||
    new Set(input.scopes).size !== input.scopes.length ||
    input.scopes.some((scope) => !VALID_SCOPES.has(scope))
  ) {
    invalidApiKey("scopes must be non-empty, unique, and recognized");
  }
  if (input.expiresAt !== undefined) {
    const expiresAt = Date.parse(input.expiresAt);
    if (
      !RFC3339_INSTANT_PATTERN.test(input.expiresAt) ||
      Number.isNaN(expiresAt) ||
      expiresAt <= now.getTime()
    ) {
      invalidApiKey("expiresAt must be a future RFC 3339 timestamp");
    }
  }
}

const RFC3339_INSTANT_PATTERN =
  /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})$/;

function validateGeneratedSecret(secret: string): void {
  if (!/^exk_[A-Za-z0-9_-]{24,}$/.test(secret)) {
    throw new Error("Generated API key secret does not match the contract");
  }
}

function defaultSecret(): string {
  // Hex keeps the non-secret display prefix inside the database's strict
  // alphanumeric constraint while retaining 256 bits of secret entropy.
  return `exk_${randomBytes(32).toString("hex")}`;
}

function invalidApiKey(detail: string): never {
  throw new OwnerSecurityProblem({
    status: 422,
    code: "invalid_api_key",
    detail: `Invalid API key request: ${detail}.`,
  });
}

function notFound(): OwnerSecurityProblem {
  return new OwnerSecurityProblem({
    status: 404,
    code: "api_key_not_found",
    detail: "The API key does not exist for this user.",
  });
}

async function audit(
  client: Queryable,
  principal: Principal,
  requestId: string,
  action: string,
  apiKeyId: string,
  metadata: Readonly<Record<string, unknown>>,
): Promise<void> {
  await client.query(
    `INSERT INTO audit_log (
       user_id, actor_type, actor_id, action, entity_type, entity_id,
       request_id, metadata
     )
     VALUES ($1, $2, $3, $4, 'api_key', $5, $6, $7::jsonb)`,
    [
      principal.userId,
      principal.kind,
      principal.actorId,
      action,
      apiKeyId,
      requestId,
      JSON.stringify(metadata),
    ],
  );
}
