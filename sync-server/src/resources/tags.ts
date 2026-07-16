import { randomUUID } from "node:crypto";

import type { QueryResultRow } from "pg";

import type { Principal } from "../auth/principal.js";
import type { Database, Queryable } from "../db/database.js";
import { HttpProblem } from "../http/problem.js";
import {
  assertSerializedJsonSize,
  RESOURCE_METADATA_MAX_BYTES,
} from "./limits.js";
import {
  cursorSignature,
  databaseErrorCode,
  executeIdempotentMutation,
  invalidRequest,
  isoDate,
  type JsonObject,
  mergeJsonObject,
  type MutationResponse,
  optionalDate,
  parsePageLimit,
  requireMatchingEtag,
  translateDatabaseError,
  unprocessable,
} from "./shared.js";

export interface CreateTagInput {
  readonly id?: string;
  readonly name: string;
  readonly color?: string;
  readonly emoji?: string;
  readonly sortOrder?: number;
  readonly metadata?: JsonObject;
}

export interface UpdateTagInput {
  readonly name?: string;
  readonly color?: string | null;
  readonly emoji?: string | null;
  readonly sortOrder?: number;
  readonly metadata?: JsonObject;
}

export interface TagResource {
  readonly id: string;
  readonly userId: string;
  readonly name: string;
  readonly color?: string;
  readonly emoji?: string;
  readonly sortOrder: number;
  readonly metadata: JsonObject;
  readonly revision: number;
  readonly createdAt: string;
  readonly updatedAt: string;
}

export interface TagPage {
  readonly data: readonly TagResource[];
  readonly hasMore: boolean;
  readonly nextCursor?: string;
}

export interface TagListQuery {
  readonly cursor?: string;
  readonly limit?: unknown;
  readonly updatedAfter?: string;
}

interface TagRow extends QueryResultRow {
  readonly id: string;
  readonly user_id: string;
  readonly name: string;
  readonly emoji: string | null;
  readonly color: string | null;
  readonly sort_order: number;
  readonly metadata: JsonObject;
  readonly revision: string | number;
  readonly created_at: Date | string;
  readonly updated_at: Date | string;
  readonly deleted_at: Date | string | null;
}

interface TagCursor {
  readonly v: 1;
  readonly kind: "tags";
  readonly signature: string;
  readonly sortOrder: number;
  readonly name: string;
  readonly id: string;
}

export class TagService {
  constructor(private readonly database: Database) {}

  async list(principal: Principal, query: TagListQuery): Promise<TagPage> {
    const limit = parsePageLimit(query.limit);
    const updatedAfter = optionalDate(query.updatedAfter, "updatedAfter");
    const signature = cursorSignature({ userId: principal.userId, updatedAfter });
    const cursor = decodeTagCursor(query.cursor, signature);
    const values: unknown[] = [principal.userId];
    const where = ["user_id = $1", "deleted_at IS NULL"];
    if (updatedAfter !== undefined) {
      values.push(updatedAfter);
      where.push(`updated_at >= $${values.length}::timestamptz`);
    }
    if (cursor !== undefined) {
      values.push(cursor.sortOrder, cursor.name, cursor.id);
      where.push(
        `(sort_order, name, id) > ` +
          `($${values.length - 2}::integer, $${values.length - 1}::text, $${values.length}::uuid)`,
      );
    }
    values.push(limit + 1);
    const result = await this.database.query<TagRow>(
      `SELECT *
       FROM tags
       WHERE ${where.join(" AND ")}
       ORDER BY sort_order ASC, name ASC, id ASC
       LIMIT $${values.length}`,
      values,
    );
    const hasMore = result.rows.length > limit;
    const rows = result.rows.slice(0, limit);
    const last = rows.at(-1);
    return {
      data: rows.map(mapTagRow),
      hasMore,
      ...(hasMore && last !== undefined
        ? { nextCursor: encodeTagCursor(signature, last) }
        : {}),
    };
  }

  async get(userId: string, tagId: string): Promise<TagResource> {
    assertUuid(tagId, "tagId");
    const row = await loadTag(this.database, userId, tagId);
    if (row === undefined) {
      throw tagNotFound();
    }
    return mapTagRow(row);
  }

  async create(
    principal: Principal,
    input: CreateTagInput,
    idempotencyKey: string,
    requestId: string,
  ): Promise<MutationResponse<TagResource>> {
    return this.translate(() =>
      executeIdempotentMutation(
        this.database,
        principal,
        "createTag",
        idempotencyKey,
        { input },
        async (queryable) => {
          const resource = await createTagInTransaction(queryable, principal, input, requestId);
          return {
            status: 201,
            headers: {
              location: `/v1/tags/${resource.id}`,
              etag: tagEtag(resource.id, resource.revision),
            },
            body: resource,
          };
        },
      ),
    );
  }

  async patch(
    principal: Principal,
    tagId: string,
    input: UpdateTagInput,
    ifMatch: string,
    idempotencyKey: string,
    requestId: string,
  ): Promise<MutationResponse<TagResource>> {
    return this.translate(() =>
      executeIdempotentMutation(
        this.database,
        principal,
        "updateTag",
        idempotencyKey,
        { tagId, ifMatch, input },
        async (queryable) => {
          const resource = await patchTagInTransaction(
            queryable,
            principal,
            tagId,
            input,
            ifMatch,
            requestId,
          );
          return {
            status: 200,
            headers: { etag: tagEtag(resource.id, resource.revision) },
            body: resource,
          };
        },
      ),
    );
  }

  async delete(
    principal: Principal,
    tagId: string,
    ifMatch: string,
    idempotencyKey: string,
    requestId: string,
  ): Promise<MutationResponse<null>> {
    return this.translate(() =>
      executeIdempotentMutation(
        this.database,
        principal,
        "deleteTag",
        idempotencyKey,
        { tagId, ifMatch },
        async (queryable) => {
          await deleteTagInTransaction(
            queryable,
            principal,
            tagId,
            ifMatch,
            requestId,
          );
          return { status: 204, headers: {}, body: null };
        },
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

/** Transaction-scoped create used by both direct HTTP and atomic sync batches. */
export async function createTagInTransaction(
  queryable: Queryable,
  principal: Principal,
  input: CreateTagInput,
  requestId: string,
): Promise<TagResource> {
  const definition = validateTagDefinition(input);
  const id = input.id ?? randomUUID();
  if (input.id !== undefined) {
    assertUuid(input.id, "id");
  }
  await queryable.query(
    `INSERT INTO tags (
       id, user_id, name, emoji, color, sort_order, metadata
     ) VALUES ($1, $2, $3, $4, $5, $6, $7::jsonb)`,
    [
      id,
      principal.userId,
      definition.name,
      definition.emoji,
      definition.color,
      definition.sortOrder,
      JSON.stringify(definition.metadata),
    ],
  );
  await writeCatalogAudit(queryable, principal, "tag.create", "tag", id, requestId);
  const row = await loadTag(queryable, principal.userId, id);
  if (row === undefined) {
    throw new Error("Created tag could not be reloaded");
  }
  return mapTagRow(row);
}

/** RFC 7396 patch semantics for the direct tag endpoint. */
export async function patchTagInTransaction(
  queryable: Queryable,
  principal: Principal,
  tagId: string,
  input: UpdateTagInput,
  ifMatch: string,
  requestId: string,
): Promise<TagResource> {
  assertUuid(tagId, "tagId");
  if (Object.keys(input).length === 0) {
    throw invalidRequest("The tag patch must contain at least one property.");
  }
  const current = await lockTag(queryable, principal.userId, tagId);
  if (current === undefined) {
    throw tagNotFound();
  }
  requireMatchingEtag(ifMatch, tagEtag(tagId, Number(current.revision)));
  const metadata = input.metadata === undefined
    ? current.metadata
    : mergeJsonObject(current.metadata, input.metadata);
  const definition = validateTagDefinition({
    name: input.name ?? current.name,
    ...(input.color === undefined
      ? current.color === null ? {} : { color: current.color }
      : input.color === null ? {} : { color: input.color }),
    ...(input.emoji === undefined
      ? current.emoji === null ? {} : { emoji: current.emoji }
      : input.emoji === null ? {} : { emoji: input.emoji }),
    sortOrder: input.sortOrder ?? current.sort_order,
    metadata,
  });
  return updateLockedTag(queryable, principal, tagId, definition, requestId);
}

/** Full replacement semantics used by sync upserts of an existing tag. */
export async function replaceTagInTransaction(
  queryable: Queryable,
  principal: Principal,
  tagId: string,
  input: CreateTagInput,
  ifMatch: string,
  requestId: string,
): Promise<TagResource> {
  assertUuid(tagId, "tagId");
  if (input.id !== undefined && input.id !== tagId) {
    throw invalidRequest("tag.id must match the resource ID being replaced.");
  }
  const current = await lockTag(queryable, principal.userId, tagId);
  if (current === undefined) {
    throw tagNotFound();
  }
  requireMatchingEtag(ifMatch, tagEtag(tagId, Number(current.revision)));
  return updateLockedTag(queryable, principal, tagId, validateTagDefinition(input), requestId);
}

export async function deleteTagInTransaction(
  queryable: Queryable,
  principal: Principal,
  tagId: string,
  ifMatch: string,
  requestId: string,
): Promise<void> {
  assertUuid(tagId, "tagId");
  const current = await lockTag(queryable, principal.userId, tagId);
  if (current === undefined) {
    throw tagNotFound();
  }
  requireMatchingEtag(ifMatch, tagEtag(tagId, Number(current.revision)));
  const attached = await queryable.query(
    `SELECT 1
     FROM record_tags rt
     JOIN records r ON r.user_id = rt.user_id AND r.id = rt.record_id
     WHERE rt.user_id = $1 AND rt.tag_id = $2 AND r.deleted_at IS NULL
     LIMIT 1`,
    [principal.userId, tagId],
  );
  if (attached.rowCount > 0) {
    throw new HttpProblem({
      status: 409,
      code: "tag_in_use",
      title: "Conflict",
      type: "urn:exeligmos:problem:tag-in-use",
      detail: "The tag cannot be deleted while active records reference it.",
    });
  }
  await queryable.query(
    `UPDATE tags
     SET deleted_at = clock_timestamp(), updated_at = clock_timestamp()
     WHERE user_id = $1 AND id = $2`,
    [principal.userId, tagId],
  );
  await writeCatalogAudit(queryable, principal, "tag.delete", "tag", tagId, requestId);
}

export async function loadActiveTagResource(
  queryable: Queryable,
  userId: string,
  tagId: string,
): Promise<TagResource | undefined> {
  const row = await loadTag(queryable, userId, tagId);
  return row === undefined ? undefined : mapTagRow(row);
}

export async function loadActiveTagResources(
  queryable: Queryable,
  userId: string,
  tagIds: readonly string[],
): Promise<ReadonlyMap<string, TagResource>> {
  if (tagIds.length === 0) {
    return new Map();
  }
  const result = await queryable.query<TagRow>(
    `SELECT * FROM tags
     WHERE user_id = $1 AND id = ANY($2::uuid[]) AND deleted_at IS NULL`,
    [userId, tagIds],
  );
  return new Map(result.rows.map((row) => [row.id, mapTagRow(row)]));
}

export function validateTagDefinition(input: CreateTagInput): {
  readonly name: string;
  readonly color: string | null;
  readonly emoji: string | null;
  readonly sortOrder: number;
  readonly metadata: JsonObject;
} {
  const name = validateName(input.name);
  const color = validateColor(input.color);
  const emoji = validateEmoji(input.emoji);
  const sortOrder = validateSortOrder(input.sortOrder ?? 0);
  const metadata = validateMetadata(input.metadata ?? {});
  return { name, color, emoji, sortOrder, metadata };
}

export function tagEtag(tagId: string, revision: number): string {
  return `"tag-${tagId}-r${revision}"`;
}

export function mapTagRow(row: TagRow): TagResource {
  return {
    id: row.id,
    userId: row.user_id,
    name: row.name,
    ...(row.color === null ? {} : { color: row.color }),
    ...(row.emoji === null ? {} : { emoji: row.emoji }),
    sortOrder: row.sort_order,
    metadata: row.metadata,
    revision: Number(row.revision),
    createdAt: isoDate(row.created_at),
    updatedAt: isoDate(row.updated_at),
  };
}

async function updateLockedTag(
  queryable: Queryable,
  principal: Principal,
  tagId: string,
  definition: ReturnType<typeof validateTagDefinition>,
  requestId: string,
): Promise<TagResource> {
  await queryable.query(
    `UPDATE tags SET
       name = $3,
       emoji = $4,
       color = $5,
       sort_order = $6,
       metadata = $7::jsonb,
       updated_at = clock_timestamp()
     WHERE user_id = $1 AND id = $2`,
    [
      principal.userId,
      tagId,
      definition.name,
      definition.emoji,
      definition.color,
      definition.sortOrder,
      JSON.stringify(definition.metadata),
    ],
  );
  await writeCatalogAudit(queryable, principal, "tag.update", "tag", tagId, requestId);
  const row = await loadTag(queryable, principal.userId, tagId);
  if (row === undefined) {
    throw new Error("Updated tag could not be reloaded");
  }
  return mapTagRow(row);
}

async function loadTag(
  queryable: Queryable,
  userId: string,
  tagId: string,
): Promise<TagRow | undefined> {
  const result = await queryable.query<TagRow>(
    `SELECT * FROM tags
     WHERE user_id = $1 AND id = $2 AND deleted_at IS NULL`,
    [userId, tagId],
  );
  return result.rows[0];
}

async function lockTag(
  queryable: Queryable,
  userId: string,
  tagId: string,
): Promise<TagRow | undefined> {
  const result = await queryable.query<TagRow>(
    `SELECT * FROM tags
     WHERE user_id = $1 AND id = $2 AND deleted_at IS NULL
     FOR UPDATE`,
    [userId, tagId],
  );
  return result.rows[0];
}

async function writeCatalogAudit(
  queryable: Queryable,
  principal: Principal,
  action: string,
  entityType: "tag" | "template",
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

function encodeTagCursor(signature: string, row: TagRow): string {
  const cursor: TagCursor = {
    v: 1,
    kind: "tags",
    signature,
    sortOrder: row.sort_order,
    name: row.name,
    id: row.id,
  };
  return Buffer.from(JSON.stringify(cursor), "utf8").toString("base64url");
}

function decodeTagCursor(value: string | undefined, signature: string): TagCursor | undefined {
  if (value === undefined) {
    return undefined;
  }
  try {
    const decoded: unknown = JSON.parse(Buffer.from(value, "base64url").toString("utf8"));
    if (!isTagCursor(decoded) || decoded.signature !== signature) {
      throw new Error("Invalid tag cursor");
    }
    return decoded;
  } catch {
    throw invalidRequest(
      "The cursor is malformed or does not belong to this query.",
      "invalid_cursor",
    );
  }
}

function isTagCursor(value: unknown): value is TagCursor {
  if (value === null || typeof value !== "object") {
    return false;
  }
  const cursor = value as Partial<TagCursor>;
  return (
    cursor.v === 1 &&
    cursor.kind === "tags" &&
    typeof cursor.signature === "string" &&
    Number.isInteger(cursor.sortOrder) &&
    Number(cursor.sortOrder) >= -2_147_483_648 &&
    Number(cursor.sortOrder) <= 2_147_483_647 &&
    typeof cursor.name === "string" &&
    codePointLength(cursor.name) >= 1 &&
    codePointLength(cursor.name) <= 120 &&
    typeof cursor.id === "string" &&
    isUuid(cursor.id)
  );
}

function validateName(value: unknown): string {
  if (
    typeof value !== "string" ||
    value !== value.trim() ||
    codePointLength(value) < 1 ||
    codePointLength(value) > 120
  ) {
    throw unprocessable(
      "name must be trimmed and contain 1 to 120 characters.",
      "invalid_tag_name",
    );
  }
  assertSerializedJsonSize(value, 1_024, "name");
  return value;
}

function validateColor(value: unknown): string | null {
  if (value === undefined) {
    return null;
  }
  if (typeof value !== "string" || !/^#[0-9A-Fa-f]{6}(?:[0-9A-Fa-f]{2})?$/.test(value)) {
    throw unprocessable("color must be a six- or eight-digit hexadecimal color.", "invalid_color");
  }
  return value;
}

function validateEmoji(value: unknown): string | null {
  if (value === undefined) {
    return null;
  }
  if (typeof value !== "string" || codePointLength(value) > 32) {
    throw unprocessable("emoji must contain at most 32 characters.", "invalid_emoji");
  }
  assertSerializedJsonSize(value, 1_024, "emoji");
  return value;
}

function validateSortOrder(value: unknown): number {
  if (
    !Number.isInteger(value) ||
    Number(value) < -2_147_483_648 ||
    Number(value) > 2_147_483_647
  ) {
    throw unprocessable("sortOrder must be a signed 32-bit integer.", "invalid_sort_order");
  }
  return Number(value);
}

function validateMetadata(value: unknown): JsonObject {
  if (!isObject(value)) {
    throw unprocessable("metadata must be a JSON object.", "invalid_metadata");
  }
  assertSerializedJsonSize(value, RESOURCE_METADATA_MAX_BYTES, "metadata");
  return value;
}

function tagNotFound(): HttpProblem {
  return new HttpProblem({
    status: 404,
    code: "tag_not_found",
    title: "Not Found",
    type: "urn:exeligmos:problem:tag-not-found",
    detail: "The requested tag does not exist.",
  });
}

function assertUuid(value: string, name: string): void {
  if (!isUuid(value)) {
    throw invalidRequest(`${name} must be a UUID.`);
  }
}

function isUuid(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(
    value,
  );
}

function isObject(value: unknown): value is JsonObject {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function codePointLength(value: string): number {
  return [...value].length;
}
