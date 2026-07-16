import { randomUUID } from "node:crypto";

import type { QueryResultRow } from "pg";

import type { Principal } from "../auth/principal.js";
import type { Database, Queryable } from "../db/database.js";
import {
  assertUuid,
  boundedLimit,
  decodeCursor,
  encodeCursor,
  isoTimestamp,
  optionalIsoTimestamp,
  OwnerSecurityProblem,
  requireMatchingEtag,
  resourceEtag,
} from "./common.js";
import { executeIdempotentJson, type IdempotentResult } from "./idempotency.js";
import type {
  CreateDeviceInput,
  DeviceKind,
  DeviceView,
  Page,
  UpdateDeviceInput,
  Versioned,
} from "./models.js";

interface DeviceRow extends QueryResultRow {
  readonly id: string;
  readonly user_id: string;
  readonly name: string;
  readonly kind: DeviceKind;
  readonly platform: string | null;
  readonly app_version: string | null;
  readonly metadata: Readonly<Record<string, unknown>>;
  readonly revision: string | number;
  readonly registered_at: Date | string;
  readonly updated_at: Date | string;
  readonly last_seen_at: Date | string | null;
  readonly revoked_at: Date | string | null;
}

const DEVICE_COLUMNS = `
  id, user_id, name, kind, platform, app_version, metadata, revision,
  registered_at, updated_at, last_seen_at, revoked_at
`;

const DEVICE_KINDS = new Set<DeviceKind>([
  "ios",
  "macos",
  "web",
  "agent",
  "server",
  "other",
]);

export class DeviceService {
  constructor(private readonly database: Database) {}

  async list(options: {
    readonly userId: string;
    readonly cursor?: string;
    readonly limit?: number;
  }): Promise<Page<DeviceView>> {
    const limit = boundedLimit(options.limit);
    const cursor = decodeCursor("devices", options.cursor);
    const values: unknown[] = [options.userId];
    let cursorSql = "";
    if (cursor !== undefined) {
      values.push(cursor.timestamp, cursor.id);
      cursorSql = "AND (registered_at, id) < ($2::timestamptz, $3::uuid)";
    }
    values.push(limit + 1);

    const result = await this.database.query<DeviceRow>(
      `SELECT ${DEVICE_COLUMNS}
       FROM devices
       WHERE user_id = $1
       ${cursorSql}
       ORDER BY registered_at DESC, id DESC
       LIMIT $${values.length}`,
      values,
    );
    const hasMore = result.rows.length > limit;
    const rows = result.rows.slice(0, limit);
    const last = rows.at(-1);
    return {
      data: rows.map(deviceView),
      hasMore,
      ...(hasMore && last !== undefined
        ? {
            nextCursor: encodeCursor("devices", {
              timestamp: isoTimestamp(last.registered_at),
              id: last.id,
            }),
          }
        : {}),
    };
  }

  async get(userId: string, deviceId: string): Promise<Versioned<DeviceView>> {
    assertUuid(deviceId, "deviceId");
    const row = await findDevice(this.database, userId, deviceId, false);
    if (row === undefined) {
      throw notFound();
    }
    return versionedDevice(row);
  }

  async register(options: {
    readonly principal: Principal;
    readonly input: CreateDeviceInput;
    readonly idempotencyKey: string;
    readonly requestId: string;
  }): Promise<IdempotentResult<DeviceView>> {
    validateCreateDevice(options.input);

    return this.database.transaction(async (client) =>
      executeIdempotentJson({
        client,
        principal: options.principal,
        operationId: "registerDevice",
        idempotencyKey: options.idempotencyKey,
        request: options.input,
        execute: async () => {
          const id = options.input.id ?? randomUUID();
          const result = await client.query<DeviceRow>(
            `INSERT INTO devices (
               id, user_id, name, kind, platform, app_version, metadata
             )
             VALUES ($1, $2, $3, $4, $5, $6, $7::jsonb)
             ON CONFLICT (id) DO NOTHING
             RETURNING ${DEVICE_COLUMNS}`,
            [
              id,
              options.principal.userId,
              options.input.name,
              options.input.kind,
              options.input.platform ?? null,
              options.input.appVersion ?? null,
              JSON.stringify(options.input.metadata ?? {}),
            ],
          );
          const row = result.rows[0];
          if (row === undefined) {
            throw new OwnerSecurityProblem({
              status: 409,
              code: "device_id_conflict",
              detail: "The supplied device ID already exists.",
            });
          }
          const versioned = versionedDevice(row);
          await audit(client, options.principal, options.requestId, "device.register", row.id);

          return {
            status: 201,
            headers: {
              etag: versioned.etag,
              location: `/v1/devices/${row.id}`,
            },
            body: versioned.view,
          };
        },
      }),
    );
  }

  async update(options: {
    readonly principal: Principal;
    readonly deviceId: string;
    readonly ifMatch: string | undefined;
    readonly input: UpdateDeviceInput;
    readonly requestId: string;
  }): Promise<Versioned<DeviceView>> {
    assertUuid(options.deviceId, "deviceId");
    validateUpdateDevice(options.input);

    return this.database.transaction(async (client) => {
      const current = await findDevice(
        client,
        options.principal.userId,
        options.deviceId,
        true,
      );
      if (current === undefined) {
        throw notFound();
      }
      requireMatchingEtag(deviceEtag(current), options.ifMatch);
      if (current.revoked_at !== null) {
        throw new OwnerSecurityProblem({
          status: 409,
          code: "device_revoked",
          detail: "A revoked device cannot be modified.",
        });
      }

      const assignments: string[] = [];
      const values: unknown[] = [options.principal.userId, options.deviceId];
      addAssignment(assignments, values, "name", options.input.name);
      addAssignment(assignments, values, "platform", options.input.platform);
      addAssignment(assignments, values, "app_version", options.input.appVersion);
      if (options.input.metadata !== undefined) {
        values.push(JSON.stringify(mergeJsonObject(current.metadata, options.input.metadata)));
        assignments.push(`metadata = $${values.length}::jsonb`);
      }

      const result = await client.query<DeviceRow>(
        `UPDATE devices
         SET ${assignments.join(", ")}
         WHERE user_id = $1 AND id = $2 AND revoked_at IS NULL
         RETURNING ${DEVICE_COLUMNS}`,
        values,
      );
      const row = result.rows[0];
      if (row === undefined) {
        throw notFound();
      }
      await audit(client, options.principal, options.requestId, "device.update", row.id);
      return versionedDevice(row);
    });
  }

  async revoke(options: {
    readonly principal: Principal;
    readonly deviceId: string;
    readonly ifMatch: string | undefined;
    readonly requestId: string;
  }): Promise<void> {
    assertUuid(options.deviceId, "deviceId");
    await this.database.transaction(async (client) => {
      const current = await findDevice(
        client,
        options.principal.userId,
        options.deviceId,
        true,
      );
      if (current === undefined) {
        throw notFound();
      }
      if (current.revoked_at !== null) {
        // A caller can lose the original 204 response. Once the desired state
        // is already reached, accept the retry even though revocation advanced
        // the resource revision beyond the caller's original If-Match value.
        return;
      }
      requireMatchingEtag(deviceEtag(current), options.ifMatch);

      await client.query(
        `UPDATE devices
         SET revoked_at = clock_timestamp()
         WHERE user_id = $1 AND id = $2 AND revoked_at IS NULL`,
        [options.principal.userId, options.deviceId],
      );
      await client.query(
        `UPDATE api_keys
         SET revoked_at = clock_timestamp()
         WHERE user_id = $1 AND device_id = $2 AND revoked_at IS NULL`,
        [options.principal.userId, options.deviceId],
      );
      await client.query(
        `UPDATE auth_sessions
         SET revoked_at = clock_timestamp(), revoke_reason = 'device_revoked'
         WHERE user_id = $1 AND device_id = $2 AND revoked_at IS NULL`,
        [options.principal.userId, options.deviceId],
      );
      await audit(client, options.principal, options.requestId, "device.revoke", options.deviceId);
    });
  }

  async bindCurrentSession(options: {
    readonly principal: Principal;
    readonly deviceId: string;
    readonly requestId: string;
  }): Promise<void> {
    assertUuid(options.deviceId, "deviceId");
    await this.database.transaction(async (client) => {
      const device = await findDevice(
        client,
        options.principal.userId,
        options.deviceId,
        true,
      );
      if (device === undefined) {
        throw notFound();
      }
      if (device.revoked_at !== null) {
        throw new OwnerSecurityProblem({
          status: 409,
          code: "device_revoked",
          detail: "A revoked device cannot receive a session binding.",
        });
      }

      const bound = await client.query(
        `UPDATE auth_sessions
         SET device_id = $3
         WHERE user_id = $1
           AND id = $2
           AND revoked_at IS NULL
           AND expires_at > now()
         RETURNING id`,
        [options.principal.userId, options.principal.actorId, options.deviceId],
      );
      if (bound.rowCount === 0) {
        throw new OwnerSecurityProblem({
          status: 401,
          code: "authentication_invalid",
          detail: "The authenticated session is no longer active.",
        });
      }
      await audit(
        client,
        options.principal,
        options.requestId,
        "session.bind_device",
        options.deviceId,
      );
    });
  }
}

async function findDevice(
  client: Queryable,
  userId: string,
  deviceId: string,
  forUpdate: boolean,
): Promise<DeviceRow | undefined> {
  const result = await client.query<DeviceRow>(
    `SELECT ${DEVICE_COLUMNS}
     FROM devices
     WHERE user_id = $1 AND id = $2
     ${forUpdate ? "FOR UPDATE" : ""}`,
    [userId, deviceId],
  );
  return result.rows[0];
}

function versionedDevice(row: DeviceRow): Versioned<DeviceView> {
  return { view: deviceView(row), etag: deviceEtag(row) };
}

function deviceEtag(row: DeviceRow): string {
  return resourceEtag("device", row.id, Number(row.revision));
}

function deviceView(row: DeviceRow): DeviceView {
  return {
    id: row.id,
    userId: row.user_id,
    name: row.name,
    kind: row.kind,
    ...(row.platform === null ? {} : { platform: row.platform }),
    ...(row.app_version === null ? {} : { appVersion: row.app_version }),
    metadata: row.metadata,
    revision: Number(row.revision),
    registeredAt: isoTimestamp(row.registered_at),
    updatedAt: isoTimestamp(row.updated_at),
    lastSeenAt: optionalIsoTimestamp(row.last_seen_at),
    revokedAt: optionalIsoTimestamp(row.revoked_at),
  };
}

function validateCreateDevice(input: CreateDeviceInput): void {
  if (input.id !== undefined) {
    assertUuid(input.id, "id");
  }
  if (!DEVICE_KINDS.has(input.kind)) {
    invalidDevice("kind is not supported");
  }
  validateText(input.name, "name", 120);
  validateOptionalText(input.platform, "platform", 80);
  validateOptionalText(input.appVersion, "appVersion", 80);
  validateMetadata(input.metadata);
}

function validateUpdateDevice(input: UpdateDeviceInput): void {
  if (Object.keys(input).length === 0) {
    invalidDevice("at least one mutable field is required");
  }
  validateOptionalText(input.name, "name", 120);
  validateOptionalText(input.platform, "platform", 80);
  validateOptionalText(input.appVersion, "appVersion", 80);
  validateMetadata(input.metadata);
}

function validateText(value: string, field: string, maximum: number): void {
  if (value.trim() !== value || value.length < 1 || value.length > maximum) {
    invalidDevice(`${field} must contain 1 to ${maximum} trimmed characters`);
  }
}

function validateOptionalText(
  value: string | undefined,
  field: string,
  maximum: number,
): void {
  if (value !== undefined) {
    validateText(value, field, maximum);
  }
}

function validateMetadata(value: Readonly<Record<string, unknown>> | undefined): void {
  if (value !== undefined && (value === null || Array.isArray(value))) {
    invalidDevice("metadata must be a JSON object");
  }
}

function invalidDevice(detail: string): never {
  throw new OwnerSecurityProblem({
    status: 422,
    code: "invalid_device",
    detail: `Invalid device: ${detail}.`,
  });
}

function addAssignment(
  assignments: string[],
  values: unknown[],
  column: string,
  value: string | undefined,
): void {
  if (value !== undefined) {
    values.push(value);
    assignments.push(`${column} = $${values.length}`);
  }
}

/** Apply RFC 7396 semantics inside the device metadata object. */
function mergeJsonObject(
  target: Readonly<Record<string, unknown>>,
  patch: Readonly<Record<string, unknown>>,
): Record<string, unknown> {
  const result: Record<string, unknown> = { ...target };
  for (const [key, value] of Object.entries(patch)) {
    if (value === null) {
      delete result[key];
    } else if (isPlainObject(value)) {
      const current = result[key];
      result[key] = mergeJsonObject(isPlainObject(current) ? current : {}, value);
    } else {
      result[key] = structuredClone(value);
    }
  }
  return result;
}

function isPlainObject(value: unknown): value is Readonly<Record<string, unknown>> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function notFound(): OwnerSecurityProblem {
  return new OwnerSecurityProblem({
    status: 404,
    code: "device_not_found",
    detail: "The device does not exist for this user.",
  });
}

async function audit(
  client: Queryable,
  principal: Principal,
  requestId: string,
  action: string,
  deviceId: string,
): Promise<void> {
  await client.query(
    `INSERT INTO audit_log (
       user_id, actor_type, actor_id, action, entity_type, entity_id,
       request_id, metadata
     )
     VALUES ($1, $2, $3, $4, 'device', $5, $6, '{}'::jsonb)`,
    [principal.userId, principal.kind, principal.actorId, action, deviceId, requestId],
  );
}
