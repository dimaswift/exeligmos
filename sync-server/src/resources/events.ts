import { randomUUID } from "node:crypto";

import type { QueryResultRow } from "pg";

import type { Principal } from "../auth/principal.js";
import type { Database, Queryable } from "../db/database.js";
import {
  assertSerializedJsonSize,
  RESOURCE_METADATA_MAX_BYTES,
} from "./limits.js";
import {
  assertActiveOwnedDevice,
  assertApiKeyDevice,
  cursorSignature,
  databaseErrorCode,
  decodeCursor,
  encodeCursor,
  executeIdempotentMutation,
  invalidRequest,
  isoDate,
  type JsonObject,
  mergeJsonObject,
  type MutationResponse,
  notFound,
  optionalDate,
  parsePageLimit,
  requireMatchingEtag,
  resourceEtag,
  translateDatabaseError,
  unprocessable,
  writeMutationAudit,
} from "./shared.js";
import {
  type ResourceReference,
  type ResourceReferenceInput,
  referenceProjectionSql,
  replaceResourceReferences,
} from "./references.js";
import type { PublicUserSummary } from "./social.js";

export type EventVisibility = "public" | "private";

export interface CreateEventInput {
  readonly id?: string;
  readonly deviceId: string;
  readonly startsAt: string;
  readonly endsAt?: string;
  readonly label: string;
  readonly type: number;
  readonly metadata?: JsonObject;
  readonly visibility?: EventVisibility;
  readonly references?: readonly ResourceReferenceInput[];
}

export interface UpdateEventInput {
  readonly deviceId?: string;
  readonly startsAt?: string;
  readonly endsAt?: string | null;
  readonly label?: string;
  readonly type?: number;
  readonly metadata?: JsonObject;
  readonly visibility?: EventVisibility;
  readonly references?: readonly ResourceReferenceInput[];
}

export interface EventResource {
  readonly id: string;
  readonly userId: string;
  readonly author: PublicUserSummary;
  readonly deviceId: string;
  readonly visibility: EventVisibility;
  readonly startsAt: string;
  readonly endsAt?: string;
  readonly label: string;
  readonly type: number;
  readonly metadata: JsonObject;
  readonly references: readonly ResourceReference[];
  readonly revision: number;
  readonly createdAt: string;
  readonly updatedAt: string;
}

export interface PublicEventProjection {
  readonly id: string;
  readonly userId: string;
  readonly author: PublicUserSummary;
  readonly visibility: "public";
  readonly startsAt: string;
  readonly endsAt?: string;
  readonly label: string;
  readonly type: number;
  readonly metadata: JsonObject;
  readonly references: readonly ResourceReference[];
  readonly revision: number;
  readonly createdAt: string;
  readonly updatedAt: string;
}

export interface EventPage {
  readonly data: readonly EventResource[];
  readonly hasMore: boolean;
  readonly nextCursor?: string;
}

export interface EventListQuery {
  readonly cursor?: string;
  readonly limit?: unknown;
  readonly deviceId?: string;
  readonly types?: readonly (string | number)[];
  readonly from?: string;
  readonly to?: string;
  readonly updatedAfter?: string;
  readonly visibility?: EventVisibility;
}

export interface PublicEventListQuery {
  readonly cursor?: string;
  readonly limit?: unknown;
  readonly userId?: string;
  readonly types?: readonly (string | number)[];
  readonly from?: string;
  readonly to?: string;
}

interface EventRow extends QueryResultRow {
  readonly id: string;
  readonly user_id: string;
  readonly device_id: string;
  readonly visibility: EventVisibility;
  readonly starts_at: Date | string;
  readonly ends_at: Date | string | null;
  readonly label: string;
  readonly type: number;
  readonly metadata: JsonObject;
  readonly revision: string | number;
  readonly created_at: Date | string;
  readonly updated_at: Date | string;
  readonly deleted_at: Date | string | null;
  readonly references: readonly ResourceReference[];
  readonly author: PublicUserSummary;
}

const EVENT_COLUMNS = `
  e.id,
  e.user_id,
  e.device_id,
  e.visibility,
  e.starts_at,
  e.ends_at,
  e.label,
  e.type,
  e.metadata,
  e.revision,
  e.created_at,
  e.updated_at,
  e.deleted_at,
  jsonb_build_object(
    'id', author.id,
    'login', author.login,
    'displayName', author.display_name,
    'sarosAnchor', author.saros_anchor
  ) AS author,
  ${referenceProjectionSql("e", "event")}
`;

export class EventService {
  constructor(private readonly database: Database) {}

  async list(principal: Principal, query: EventListQuery): Promise<EventPage> {
    const limit = parsePageLimit(query.limit);
    const from = optionalDate(query.from, "from");
    const to = optionalDate(query.to, "to");
    const updatedAfter = optionalDate(query.updatedAfter, "updatedAfter");
    if (from !== undefined && to !== undefined && Date.parse(from) >= Date.parse(to)) {
      throw invalidRequest("from must precede to.");
    }
    const types = normalizeTypes(query.types);
    const binding = {
      userId: principal.userId,
      deviceId: query.deviceId,
      types,
      from,
      to,
      updatedAfter,
      visibility: query.visibility,
    };
    const signature = cursorSignature(binding);
    const cursor = decodeCursor(query.cursor, "events", signature);
    const values: unknown[] = [principal.userId];
    const where = ["e.user_id = $1", "e.deleted_at IS NULL"];
    if (query.visibility !== undefined) {
      values.push(query.visibility);
      where.push(`e.visibility = $${values.length}`);
    }
    if (query.deviceId !== undefined) {
      assertUuid(query.deviceId, "deviceId");
      values.push(query.deviceId);
      where.push(`e.device_id = $${values.length}::uuid`);
    }
    if (types !== undefined) {
      values.push(types);
      where.push(`e.type = ANY($${values.length}::integer[])`);
    }
    if (from !== undefined) {
      values.push(from);
      where.push(`COALESCE(e.ends_at, 'infinity'::timestamptz) >= $${values.length}::timestamptz`);
    }
    if (to !== undefined) {
      values.push(to);
      where.push(`e.starts_at < $${values.length}::timestamptz`);
    }
    if (updatedAfter !== undefined) {
      values.push(updatedAfter);
      where.push(`e.updated_at >= $${values.length}::timestamptz`);
    }
    if (cursor !== undefined) {
      values.push(cursor.sort, cursor.id);
      where.push(`(e.starts_at, e.id) < ($${values.length - 1}::timestamptz, $${values.length}::uuid)`);
    }
    values.push(limit + 1);
    const result = await this.database.query<EventRow>(
      `SELECT ${EVENT_COLUMNS}
       FROM events e
       JOIN users author ON author.id = e.user_id
       WHERE ${where.join(" AND ")}
       ORDER BY e.starts_at DESC, e.id DESC
       LIMIT $${values.length}`,
      values,
    );
    const hasMore = result.rows.length > limit;
    const rows = result.rows.slice(0, limit);
    const last = rows.at(-1);
    return {
      data: rows.map(mapEventRow),
      hasMore,
      ...(hasMore && last !== undefined
        ? {
            nextCursor: encodeCursor(
              "events",
              signature,
              isoDate(last.starts_at),
              last.id,
            ),
          }
        : {}),
    };
  }

  async listPublic(query: PublicEventListQuery): Promise<{
    readonly data: readonly PublicEventProjection[];
    readonly hasMore: boolean;
    readonly nextCursor?: string;
  }> {
    const limit = parsePageLimit(query.limit);
    const from = optionalDate(query.from, "from");
    const to = optionalDate(query.to, "to");
    if (from !== undefined && to !== undefined && Date.parse(from) >= Date.parse(to)) {
      throw invalidRequest("from must precede to.");
    }
    const types = normalizeTypes(query.types);
    if (query.userId !== undefined) {
      assertUuid(query.userId, "userId");
    }
    const signature = cursorSignature({ userId: query.userId, types, from, to });
    const cursor = decodeCursor(query.cursor, "public-events", signature);
    const values: unknown[] = [];
    const where = ["e.visibility = 'public'", "e.deleted_at IS NULL", "author.status = 'active'"];
    if (query.userId !== undefined) {
      values.push(query.userId);
      where.push(`e.user_id = $${values.length}::uuid`);
    }
    if (types !== undefined) {
      values.push(types);
      where.push(`e.type = ANY($${values.length}::integer[])`);
    }
    if (from !== undefined) {
      values.push(from);
      where.push(`COALESCE(e.ends_at, 'infinity'::timestamptz) >= $${values.length}::timestamptz`);
    }
    if (to !== undefined) {
      values.push(to);
      where.push(`e.starts_at < $${values.length}::timestamptz`);
    }
    if (cursor !== undefined) {
      values.push(cursor.sort, cursor.id);
      where.push(`(e.starts_at, e.id) < ($${values.length - 1}::timestamptz, $${values.length}::uuid)`);
    }
    values.push(limit + 1);
    const result = await this.database.query<EventRow>(
      `SELECT ${EVENT_COLUMNS}
       FROM events e
       JOIN users author ON author.id = e.user_id
       WHERE ${where.join(" AND ")}
       ORDER BY e.starts_at DESC, e.id DESC
       LIMIT $${values.length}`,
      values,
    );
    const hasMore = result.rows.length > limit;
    const rows = result.rows.slice(0, limit);
    const last = rows.at(-1);
    return {
      data: rows.map((row) => publicEventProjection(mapEventRow(row))),
      hasMore,
      ...(hasMore && last !== undefined
        ? { nextCursor: encodeCursor("public-events", signature, isoDate(last.starts_at), last.id) }
        : {}),
    };
  }

  async get(userId: string, eventId: string): Promise<EventResource> {
    const row = await loadEvent(this.database, userId, eventId);
    if (row === undefined) {
      throw notFound("event");
    }
    return mapEventRow(row);
  }

  async getPublic(eventId: string): Promise<PublicEventProjection> {
    assertUuid(eventId, "eventId");
    const result = await this.database.query<EventRow>(
      `SELECT ${EVENT_COLUMNS}
       FROM events e
       JOIN users author ON author.id = e.user_id
       WHERE e.id = $1 AND e.visibility = 'public' AND e.deleted_at IS NULL
         AND author.status = 'active'`,
      [eventId],
    );
    const row = result.rows[0];
    if (row === undefined) {
      throw notFound("event");
    }
    return publicEventProjection(mapEventRow(row));
  }

  async create(
    principal: Principal,
    input: CreateEventInput,
    idempotencyKey: string,
    requestId: string,
  ): Promise<MutationResponse<EventResource>> {
    assertApiKeyDevice(principal, input.deviceId);
    return this.translate(() =>
      executeIdempotentMutation(
        this.database,
        principal,
        "createEvent",
        idempotencyKey,
        { input },
        (queryable) => createEventInTransaction(queryable, principal, input, requestId),
      ),
    );
  }

  async patch(
    principal: Principal,
    eventId: string,
    input: UpdateEventInput,
    ifMatch: string,
    idempotencyKey: string,
    requestId: string,
  ): Promise<MutationResponse<EventResource>> {
    return this.translate(() =>
      executeIdempotentMutation(
        this.database,
        principal,
        "updateEvent",
        idempotencyKey,
        { eventId, ifMatch, input },
        async (queryable) => {
          const current = await lockEvent(queryable, principal.userId, eventId);
          if (current === undefined) {
            throw notFound("event");
          }
          requireMatchingEtag(ifMatch, resourceEtag("event", eventId, Number(current.revision)));
          const deviceId = input.deviceId ?? current.device_id;
          if (input.visibility !== undefined && input.visibility !== current.visibility) {
            throw unprocessable("Event visibility is immutable.", "visibility_immutable");
          }
          assertApiKeyDevice(principal, deviceId);
          await assertActiveOwnedDevice(queryable, principal.userId, deviceId);
          const interval = validateInterval(
            input.startsAt ?? isoDate(current.starts_at),
            input.endsAt === undefined
              ? current.ends_at === null
                ? undefined
                : isoDate(current.ends_at)
              : input.endsAt ?? undefined,
          );
          const metadata = input.metadata === undefined
            ? current.metadata
            : mergeJsonObject(current.metadata, input.metadata);
          assertSerializedJsonSize(metadata, RESOURCE_METADATA_MAX_BYTES, "metadata");
          await queryable.query(
            `UPDATE events SET
               device_id = $3,
               starts_at = $4::timestamptz,
               ends_at = $5::timestamptz,
               label = $6,
               type = $7,
               metadata = $8::jsonb,
               updated_at = clock_timestamp()
             WHERE user_id = $1 AND id = $2`,
            [
              principal.userId,
              eventId,
              deviceId,
              interval.startsAt,
              interval.endsAt,
              input.label === undefined ? current.label : validateLabel(input.label),
              input.type === undefined ? current.type : validateType(input.type),
              JSON.stringify(metadata),
            ],
          );
          if (input.references !== undefined) {
            await replaceResourceReferences(
              queryable,
              principal.userId,
              "event",
              eventId,
              input.references,
            );
          }
          await writeMutationAudit(
            queryable,
            principal,
            "event.update",
            "event",
            eventId,
            requestId,
          );
          const row = await loadEvent(queryable, principal.userId, eventId);
          if (row === undefined) {
            throw new Error("Updated event could not be reloaded");
          }
          const resource = mapEventRow(row);
          return {
            status: 200,
            headers: { etag: resourceEtag("event", eventId, resource.revision) },
            body: resource,
          };
        },
      ),
    );
  }

  async delete(
    principal: Principal,
    eventId: string,
    ifMatch: string,
    idempotencyKey: string,
    requestId: string,
  ): Promise<MutationResponse<null>> {
    return this.translate(() =>
      executeIdempotentMutation(
        this.database,
        principal,
        "deleteEvent",
        idempotencyKey,
        { eventId, ifMatch },
        (queryable) =>
          deleteEventInTransaction(
            queryable,
            principal,
            eventId,
            ifMatch,
            requestId,
          ),
      ),
    );
  }

  private async translate<Result>(work: () => Promise<Result>): Promise<Result> {
    try {
      return await work();
    } catch (error) {
      if (databaseErrorCode(error) !== undefined) {
        translateDatabaseError(error);
      }
      throw error;
    }
  }
}

/** Transaction-scoped event creation used by direct and sync APIs. */
export async function createEventInTransaction(
  queryable: Queryable,
  principal: Principal,
  input: CreateEventInput,
  requestId: string,
): Promise<MutationResponse<EventResource>> {
  assertApiKeyDevice(principal, input.deviceId);
  await assertActiveOwnedDevice(queryable, principal.userId, input.deviceId);
  const interval = validateInterval(input.startsAt, input.endsAt);
  const label = validateLabel(input.label);
  const type = validateType(input.type);
  const visibility = validateVisibility(input.visibility);
  const id = input.id ?? randomUUID();
  if (input.id !== undefined) {
    assertUuid(input.id, "id");
  }
  const metadata = input.metadata ?? {};
  assertSerializedJsonSize(metadata, RESOURCE_METADATA_MAX_BYTES, "metadata");
  await queryable.query(
    `INSERT INTO events (
       id, user_id, device_id, visibility, starts_at, ends_at, label, type, metadata
     ) VALUES ($1, $2, $3, $4, $5::timestamptz, $6::timestamptz, $7, $8, $9::jsonb)`,
    [
      id,
      principal.userId,
      input.deviceId,
      visibility,
      interval.startsAt,
      interval.endsAt,
      label,
      type,
      JSON.stringify(metadata),
    ],
  );
  await replaceResourceReferences(queryable, principal.userId, "event", id, input.references ?? []);
  await writeMutationAudit(queryable, principal, "event.create", "event", id, requestId);
  const row = await loadEvent(queryable, principal.userId, id);
  if (row === undefined) {
    throw new Error("Created event could not be reloaded");
  }
  const resource = mapEventRow(row);
  return {
    status: 201,
    headers: {
      location: `/v1/events/${id}`,
      etag: resourceEtag("event", id, resource.revision),
    },
    body: resource,
  };
}

/** Transaction-scoped full replacement used by sync upserts. */
export async function replaceEventInTransaction(
  queryable: Queryable,
  principal: Principal,
  eventId: string,
  input: CreateEventInput,
  ifMatch: string,
  requestId: string,
): Promise<MutationResponse<EventResource>> {
  assertApiKeyDevice(principal, input.deviceId);
  const current = await lockEvent(queryable, principal.userId, eventId);
  if (current === undefined) {
    throw notFound("event");
  }
  requireMatchingEtag(ifMatch, resourceEtag("event", eventId, Number(current.revision)));
  if (input.id !== undefined && input.id !== eventId) {
    throw unprocessable("The body id must match the event identifier.", "event_id_mismatch");
  }
  if (validateVisibility(input.visibility) !== current.visibility) {
    throw unprocessable("Event visibility is immutable.", "visibility_immutable");
  }
  await assertActiveOwnedDevice(queryable, principal.userId, input.deviceId);
  const interval = validateInterval(input.startsAt, input.endsAt);
  const metadata = input.metadata ?? {};
  assertSerializedJsonSize(metadata, RESOURCE_METADATA_MAX_BYTES, "metadata");
  await queryable.query(
    `UPDATE events SET
       device_id = $3,
       starts_at = $4::timestamptz,
       ends_at = $5::timestamptz,
       label = $6,
       type = $7,
       metadata = $8::jsonb,
       updated_at = clock_timestamp()
     WHERE user_id = $1 AND id = $2`,
    [
      principal.userId,
      eventId,
      input.deviceId,
      interval.startsAt,
      interval.endsAt,
      validateLabel(input.label),
      validateType(input.type),
      JSON.stringify(metadata),
    ],
  );
  await replaceResourceReferences(
    queryable,
    principal.userId,
    "event",
    eventId,
    input.references ?? [],
  );
  await writeMutationAudit(
    queryable,
    principal,
    "event.replace",
    "event",
    eventId,
    requestId,
  );
  const row = await loadEvent(queryable, principal.userId, eventId);
  if (row === undefined) {
    throw new Error("Updated event could not be reloaded");
  }
  const resource = mapEventRow(row);
  return {
    status: 200,
    headers: { etag: resourceEtag("event", eventId, resource.revision) },
    body: resource,
  };
}

/** Transaction-scoped soft deletion used by direct and sync APIs. */
export async function deleteEventInTransaction(
  queryable: Queryable,
  principal: Principal,
  eventId: string,
  ifMatch: string,
  requestId: string,
): Promise<MutationResponse<null>> {
  const current = await lockEvent(queryable, principal.userId, eventId);
  if (current === undefined) {
    throw notFound("event");
  }
  requireMatchingEtag(ifMatch, resourceEtag("event", eventId, Number(current.revision)));
  await queryable.query(
    "UPDATE events SET deleted_at = clock_timestamp() WHERE user_id = $1 AND id = $2",
    [principal.userId, eventId],
  );
  await writeMutationAudit(
    queryable,
    principal,
    "event.delete",
    "event",
    eventId,
    requestId,
  );
  return { status: 204, headers: {}, body: null };
}

export async function loadEventResourcesForSync(
  queryable: Queryable,
  userId: string,
  eventIds: readonly string[],
): Promise<ReadonlyMap<string, EventResource>> {
  if (eventIds.length === 0) {
    return new Map();
  }
  const result = await queryable.query<EventRow>(
    `SELECT ${EVENT_COLUMNS}
     FROM events e
     JOIN users author ON author.id = e.user_id
     WHERE e.user_id = $1
       AND e.id = ANY($2::uuid[])
       AND e.deleted_at IS NULL`,
    [userId, eventIds],
  );
  return new Map(result.rows.map((row) => [row.id, mapEventRow(row)]));
}

export function mapEventRow(row: EventRow): EventResource {
  return {
    id: row.id,
    userId: row.user_id,
    author: row.author,
    deviceId: row.device_id,
    visibility: row.visibility,
    startsAt: isoDate(row.starts_at),
    ...(row.ends_at === null ? {} : { endsAt: isoDate(row.ends_at) }),
    label: row.label,
    type: row.type,
    metadata: row.metadata,
    references: row.references,
    revision: Number(row.revision),
    createdAt: isoDate(row.created_at),
    updatedAt: isoDate(row.updated_at),
  };
}

export function publicEventProjection(event: EventResource): PublicEventProjection {
  if (event.visibility !== "public") {
    throw notFound("event");
  }
  return {
    id: event.id,
    userId: event.userId,
    author: event.author,
    visibility: "public",
    startsAt: event.startsAt,
    ...(event.endsAt === undefined ? {} : { endsAt: event.endsAt }),
    label: event.label,
    type: event.type,
    metadata: event.metadata,
    references: event.references,
    revision: event.revision,
    createdAt: event.createdAt,
    updatedAt: event.updatedAt,
  };
}

async function loadEvent(
  queryable: Queryable,
  userId: string,
  eventId: string,
): Promise<EventRow | undefined> {
  const result = await queryable.query<EventRow>(
    `SELECT ${EVENT_COLUMNS}
     FROM events e
     JOIN users author ON author.id = e.user_id
     WHERE e.user_id = $1 AND e.id = $2 AND e.deleted_at IS NULL`,
    [userId, eventId],
  );
  return result.rows[0];
}

async function lockEvent(
  queryable: Queryable,
  userId: string,
  eventId: string,
): Promise<EventRow | undefined> {
  const result = await queryable.query<EventRow>(
    `SELECT ${EVENT_COLUMNS}
     FROM events e
     JOIN users author ON author.id = e.user_id
     WHERE e.user_id = $1 AND e.id = $2 AND e.deleted_at IS NULL
     FOR UPDATE OF e`,
    [userId, eventId],
  );
  return result.rows[0];
}

function validateInterval(
  startsAt: unknown,
  endsAt: unknown,
): { readonly startsAt: string; readonly endsAt: string | null } {
  const start = optionalDate(startsAt, "startsAt");
  if (start === undefined) {
    throw invalidRequest("startsAt is required.");
  }
  const end = endsAt === undefined || endsAt === null ? undefined : optionalDate(endsAt, "endsAt");
  if (end !== undefined && Date.parse(end) < Date.parse(start)) {
    throw unprocessable("endsAt must not precede startsAt.", "invalid_event_interval");
  }
  return { startsAt: start, endsAt: end ?? null };
}

function validateLabel(value: unknown): string {
  if (typeof value !== "string" || value !== value.trim() || value.length < 1 || value.length > 256) {
    throw unprocessable("label must be trimmed and contain 1 to 256 characters.", "invalid_label");
  }
  return value;
}

function validateType(value: unknown): number {
  if (!Number.isInteger(value) || Number(value) < 0 || Number(value) > 2_147_483_647) {
    throw unprocessable("type must be a non-negative 32-bit integer.", "invalid_event_type");
  }
  return Number(value);
}

function validateVisibility(value: unknown): EventVisibility {
  if (value === undefined) {
    return "public";
  }
  if (value !== "public" && value !== "private") {
    throw unprocessable("visibility must be public or private.", "invalid_visibility");
  }
  return value;
}

function normalizeTypes(values: readonly (string | number)[] | undefined): readonly number[] | undefined {
  if (values === undefined) {
    return undefined;
  }
  if (values.length < 1 || values.length > 50) {
    throw invalidRequest("type must contain between 1 and 50 values.");
  }
  return [...new Set(values.map((value) => validateType(Number(value))))];
}

function assertUuid(value: string, name: string): void {
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value)) {
    throw invalidRequest(`${name} must be a UUID.`);
  }
}
