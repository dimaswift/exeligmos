import { randomBytes, randomUUID } from "node:crypto";

import {
  Ajv2020,
  type ErrorObject,
  type ValidateFunction,
} from "ajv/dist/2020.js";
import * as formatsModule from "ajv-formats";
import type { FormatsPlugin } from "ajv-formats";
import Mustache from "mustache";
import type { QueryResultRow } from "pg";

import type { Principal } from "../auth/principal.js";
import type { Database, Queryable } from "../db/database.js";
import { HttpProblem } from "../http/problem.js";
import {
  assertSerializedJsonSize,
  PRIVATE_RECORD_CIPHERTEXT_MAX_BYTES,
  PUBLIC_RECORD_PAYLOAD_MAX_BYTES,
  parseRecordPageLimit,
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

export type RecordVisibility = "public" | "private";

export const RECORD_PUBLIC_ID_SCHEMA_PATTERN = "^[A-Za-z0-9_-]{5}$";
const RECORD_PUBLIC_ID_PATTERN = new RegExp(RECORD_PUBLIC_ID_SCHEMA_PATTERN);
const RECORD_PUBLIC_ID_ALLOCATION_ATTEMPTS = 64;

export function generateRecordPublicId(): string {
  return randomBytes(4).toString("base64url").slice(0, 5);
}

export function assertRecordPublicId(value: string, name = "record id"): void {
  if (!RECORD_PUBLIC_ID_PATTERN.test(value)) {
    throw invalidRequest(`${name} must be a five-character Base64URL identifier.`);
  }
}

export interface SourceReference {
  readonly kind: "client" | "agent" | "import" | "server";
  readonly provider: string;
  readonly externalId?: string;
  readonly url?: string;
  readonly metadata?: JsonObject;
}

export interface TemplateRenderRequest {
  readonly templateId: string;
  readonly version?: number;
  readonly variables: JsonObject;
}

export interface CiphertextEnvelope {
  readonly algorithm: "A256GCM";
  readonly cryptoVersion: 1;
  readonly keyVersion: 1;
  readonly nonce: string;
  readonly ciphertext: string;
  readonly contentType: "application/vnd.exeligmos.record+json";
}

export interface PublicRecordInput {
  readonly id?: string;
  readonly originId?: string;
  readonly deviceId: string;
  readonly visibility?: "public";
  readonly occurredAt: string;
  readonly endedAt?: string;
  readonly payload?: JsonObject;
  readonly render?: TemplateRenderRequest;
  readonly tagIds?: readonly string[];
  readonly mediaIds?: readonly string[];
  readonly metadata?: JsonObject;
  readonly source?: SourceReference;
  readonly references?: readonly ResourceReferenceInput[];
}

export interface PrivateRecordInput {
  readonly id: string;
  readonly originId: string;
  readonly deviceId: string;
  readonly visibility: "private";
  readonly encryption: CiphertextEnvelope;
  readonly mediaIds?: readonly string[];
  readonly references?: readonly ResourceReferenceInput[];
}

export type CreateRecordInput = PublicRecordInput | PrivateRecordInput;
export type ReplaceRecordInput = PublicRecordInput | PrivateRecordInput;

export interface PublicRecordPatch {
  readonly visibility: "public";
  readonly deviceId?: string;
  readonly occurredAt?: string;
  readonly endedAt?: string | null;
  readonly payload?: JsonObject;
  readonly tagIds?: readonly string[];
  readonly mediaIds?: readonly string[];
  readonly metadata?: JsonObject;
  readonly source?: SourceReference | null;
  readonly references?: readonly ResourceReferenceInput[];
}

export interface PrivateRecordPatch {
  readonly visibility: "private";
  readonly deviceId?: string;
  readonly encryption: CiphertextEnvelope;
  readonly mediaIds?: readonly string[];
  readonly references?: readonly ResourceReferenceInput[];
}

export type UpdateRecordInput = PublicRecordPatch | PrivateRecordPatch;

export interface MediaObject {
  readonly id: string;
  readonly userId: string;
  readonly deviceId: string;
  readonly fileName: string;
  readonly contentType: string;
  readonly byteLength: number;
  readonly sha256: string;
  readonly encryption?: {
    readonly algorithm: "A256GCM";
    readonly cryptoVersion: 1;
    readonly keyVersion: 1;
    readonly nonce: string;
    readonly plaintextContentType?: string;
  };
  readonly revision: number;
  readonly createdAt: string;
  readonly contentUrl: string;
  readonly publicContentUrl?: string;
}

interface RecordCommon {
  readonly id: string;
  /** Owner-only UUID used for storage identity and crypto profile v1. */
  readonly originId: string;
  readonly userId: string;
  readonly deviceId: string;
  readonly revision: number;
  readonly createdAt: string;
  readonly updatedAt: string;
  readonly references: readonly ResourceReference[];
}

export interface PublicRecordResource extends RecordCommon {
  readonly visibility: "public";
  readonly occurredAt: string;
  readonly author: PublicUserSummary;
  readonly endedAt?: string;
  readonly payload: JsonObject;
  readonly template?: { readonly templateId: string; readonly version: number };
  readonly tagIds: readonly string[];
  readonly tags: readonly PublicTagSummary[];
  readonly media: readonly MediaObject[];
  readonly metadata: JsonObject;
  readonly source?: SourceReference;
}

export interface PrivateRecordResource extends RecordCommon {
  readonly visibility: "private";
  readonly encryption: CiphertextEnvelope;
  readonly media: readonly MediaObject[];
}

export type RecordResource = PublicRecordResource | PrivateRecordResource;

export interface PublicMediaObject {
  readonly id: string;
  readonly fileName: string;
  readonly contentType: string;
  readonly byteLength: number;
  readonly sha256: string;
  readonly createdAt: string;
  readonly publicContentUrl: string;
}

export interface PublicRecordProjection {
  readonly id: string;
  readonly userId: string;
  readonly author: PublicUserSummary;
  readonly visibility: "public";
  readonly occurredAt: string;
  readonly endedAt?: string;
  readonly payload: JsonObject;
  readonly template?: { readonly templateId: string; readonly version: number };
  readonly tagIds: readonly string[];
  readonly tags: readonly PublicTagSummary[];
  readonly media: readonly PublicMediaObject[];
  readonly metadata: JsonObject;
  readonly references: readonly ResourceReference[];
  readonly source?: SourceReference;
  readonly revision: number;
  readonly createdAt: string;
  readonly updatedAt: string;
}

export interface PublicTagSummary {
  readonly id: string;
  readonly name: string;
  readonly emoji?: string;
  readonly color?: string;
}

export interface Page<Resource> {
  readonly data: readonly Resource[];
  readonly hasMore: boolean;
  readonly nextCursor?: string;
}

export interface OwnerRecordListQuery {
  readonly cursor?: string;
  readonly limit?: unknown;
  readonly visibility?: RecordVisibility;
  readonly deviceId?: string;
  readonly tagId?: string;
  readonly occurredAfter?: string;
  readonly occurredBefore?: string;
  readonly updatedAfter?: string;
  readonly sourceProvider?: string;
  readonly sourceExternalId?: string;
}

export interface PublicRecordListQuery {
  readonly cursor?: string;
  readonly limit?: unknown;
  readonly occurredAfter?: string;
  readonly occurredBefore?: string;
  readonly userId?: string;
  readonly tagId?: string;
}

interface RecordRow extends QueryResultRow {
  readonly id: string;
  readonly public_id: string;
  readonly user_id: string;
  readonly device_id: string;
  readonly visibility: RecordVisibility;
  readonly event_at: Date | string | null;
  readonly end_at: Date | string | null;
  readonly public_payload: JsonObject | null;
  readonly metadata: JsonObject;
  readonly template_id: string | null;
  readonly template_version: number | null;
  readonly source_kind: SourceReference["kind"] | null;
  readonly source_provider: string | null;
  readonly source_external_id: string | null;
  readonly source_url: string | null;
  readonly source_metadata: JsonObject;
  readonly cipher_algorithm: string | null;
  readonly crypto_version: number | null;
  readonly key_version: number | null;
  readonly nonce: Buffer | null;
  readonly ciphertext: Buffer | null;
  readonly encrypted_content_type: string | null;
  readonly revision: string | number;
  readonly created_at: Date | string;
  readonly updated_at: Date | string;
  readonly deleted_at: Date | string | null;
  readonly tag_ids: readonly string[];
  readonly media: readonly MediaObject[];
  readonly references: readonly ResourceReference[];
  readonly author: PublicUserSummary;
  readonly public_tags: readonly PublicTagSummary[];
}

interface TemplateRow extends QueryResultRow {
  readonly id: string;
  readonly version: number;
  readonly body: JsonObject;
  readonly variable_schema: JsonObject;
}

interface CountRow extends QueryResultRow {
  readonly count: number;
}

const RECORD_COLUMNS = `
  r.id,
  r.public_id,
  r.user_id,
  r.device_id,
  r.visibility,
  r.event_at,
  r.end_at,
  r.public_payload,
  r.metadata,
  r.template_id,
  r.template_version,
  r.source_kind,
  r.source_provider,
  r.source_external_id,
  r.source_url,
  r.source_metadata,
  r.cipher_algorithm,
  r.crypto_version,
  r.key_version,
  r.nonce,
  r.ciphertext,
  r.encrypted_content_type,
  r.revision,
  r.created_at,
  r.updated_at,
  r.deleted_at,
  jsonb_build_object(
    'id', author.id,
    'login', author.login,
    'displayName', author.display_name
  ) AS author,
  ARRAY(
    SELECT rt.tag_id::text
    FROM record_tags rt
    WHERE rt.record_id = r.id
    ORDER BY rt.tag_id
  ) AS tag_ids,
  COALESCE((
    SELECT jsonb_agg(
      jsonb_strip_nulls(jsonb_build_object(
        'id', t.id,
        'name', t.name,
        'emoji', t.emoji,
        'color', t.color
      )) ORDER BY rt.created_at, t.id
    )
    FROM record_tags rt
    JOIN tags t ON t.user_id = rt.user_id AND t.id = rt.tag_id
    WHERE rt.record_id = r.id AND t.deleted_at IS NULL
  ), '[]'::jsonb) AS public_tags,
  COALESCE((
    SELECT jsonb_agg(
      jsonb_strip_nulls(jsonb_build_object(
        'id', m.id,
        'userId', m.user_id,
        'deviceId', m.device_id,
        'fileName', m.file_name,
        'contentType', m.content_type,
        'byteLength', m.byte_size,
        'sha256', encode(m.sha256, 'hex'),
        'encryption', CASE WHEN m.visibility = 'private' THEN jsonb_strip_nulls(jsonb_build_object(
          'algorithm', m.cipher_algorithm,
          'cryptoVersion', m.crypto_version,
          'keyVersion', m.key_version,
          'nonce', encode(m.nonce, 'base64'),
          'plaintextContentType', m.plaintext_content_type
        )) END,
        'revision', m.revision,
        'createdAt', m.created_at,
        'contentUrl', '/v1/media/' || m.id::text || '/content',
        'publicContentUrl', CASE WHEN r.visibility = 'public'
          THEN '/v1/public/media/' || m.id::text || '/content' END
      )) ORDER BY rm.position
    )
    FROM record_media rm
    JOIN media_objects m ON m.user_id = rm.user_id AND m.id = rm.media_id
    WHERE rm.record_id = r.id AND m.status = 'ready' AND m.deleted_at IS NULL
  ), '[]'::jsonb) AS media,
  ${referenceProjectionSql("r", "record")}
`;

const addFormats = formatsModule.default as unknown as FormatsPlugin;
const templateValidatorCache = new Map<
  string,
  {
    readonly schemaSignature: string;
    readonly validate: ValidateFunction<unknown>;
  }
>();
const MAX_TEMPLATE_VALIDATORS = 1_000;

export class RecordService {
  constructor(private readonly database: Database) {}

  async listOwner(
    principal: Principal,
    query: OwnerRecordListQuery,
  ): Promise<Page<RecordResource>> {
    const limit = parseRecordPageLimit(query.limit);
    const occurredAfter = optionalDate(query.occurredAfter, "occurredAfter");
    const occurredBefore = optionalDate(query.occurredBefore, "occurredBefore");
    const updatedAfter = optionalDate(query.updatedAfter, "updatedAfter");
    assertDateOrder(
      occurredAfter,
      occurredBefore,
      "occurredAfter",
      "occurredBefore",
    );
    const binding = {
      userId: principal.userId,
      visibility: query.visibility,
      deviceId: query.deviceId,
      tagId: query.tagId,
      occurredAfter,
      occurredBefore,
      updatedAfter,
      sourceProvider: query.sourceProvider,
      sourceExternalId: query.sourceExternalId,
    };
    const signature = cursorSignature(binding);
    const cursor = decodeCursor(query.cursor, "owner-records", signature);
    const values: unknown[] = [principal.userId];
    const where = ["r.user_id = $1", "r.deleted_at IS NULL"];
    addEquality(where, values, "r.visibility", query.visibility);
    addUuidEquality(where, values, "r.device_id", query.deviceId);
    if (query.tagId !== undefined) {
      values.push(query.tagId);
      where.push(
        `EXISTS (SELECT 1 FROM record_tags filter_tag
          WHERE filter_tag.record_id = r.id AND filter_tag.tag_id = $${values.length}::uuid)`,
      );
    }
    addTimestampBound(where, values, "r.event_at", ">=", occurredAfter);
    addTimestampBound(where, values, "r.event_at", "<", occurredBefore);
    addTimestampBound(where, values, "r.updated_at", ">=", updatedAfter);
    addEquality(where, values, "r.source_provider", query.sourceProvider);
    addEquality(where, values, "r.source_external_id", query.sourceExternalId);
    if (cursor !== undefined) {
      values.push(cursor.sort, cursor.id);
      where.push(
        `(COALESCE(r.event_at, r.created_at), r.id) < ($${values.length - 1}::timestamptz, $${values.length}::uuid)`,
      );
    }
    values.push(limit + 1);
    const result = await this.database.query<RecordRow>(
      `SELECT ${RECORD_COLUMNS}
       FROM records r
       JOIN users author ON author.id = r.user_id
       WHERE ${where.join(" AND ")}
       ORDER BY COALESCE(r.event_at, r.created_at) DESC, r.id DESC
       LIMIT $${values.length}`,
      values,
    );
    return recordPage(
      result.rows,
      limit,
      "owner-records",
      signature,
      "owner_start",
      mapRecordRow,
    );
  }

  async listPublic(
    query: PublicRecordListQuery,
  ): Promise<Page<PublicRecordProjection>> {
    const limit = parseRecordPageLimit(query.limit);
    const occurredAfter = optionalDate(query.occurredAfter, "occurredAfter");
    const occurredBefore = optionalDate(query.occurredBefore, "occurredBefore");
    assertDateOrder(
      occurredAfter,
      occurredBefore,
      "occurredAfter",
      "occurredBefore",
    );
    const binding = {
      userId: query.userId,
      tagId: query.tagId,
      occurredAfter,
      occurredBefore,
    };
    const signature = cursorSignature(binding);
    const cursor = decodeCursor(query.cursor, "public-records", signature);
    const values: unknown[] = [];
    const where = [
      "r.visibility = 'public'",
      "r.deleted_at IS NULL",
      "author.status = 'active'",
    ];
    addUuidEquality(where, values, "r.user_id", query.userId);
    if (query.tagId !== undefined) {
      values.push(query.tagId);
      where.push(
        `EXISTS (SELECT 1 FROM record_tags filter_tag
          WHERE filter_tag.record_id = r.id AND filter_tag.tag_id = $${values.length}::uuid)`,
      );
    }
    addTimestampBound(where, values, "r.event_at", ">=", occurredAfter);
    addTimestampBound(where, values, "r.event_at", "<", occurredBefore);
    if (cursor !== undefined) {
      values.push(cursor.sort, cursor.id);
      where.push(
        `(r.event_at, r.id) < ($${values.length - 1}::timestamptz, $${values.length}::uuid)`,
      );
    }
    values.push(limit + 1);
    const result = await this.database.query<RecordRow>(
      `SELECT ${RECORD_COLUMNS}
       FROM records r
       JOIN users author ON author.id = r.user_id
       WHERE ${where.join(" AND ")}
       ORDER BY r.event_at DESC, r.id DESC
       LIMIT $${values.length}`,
      values,
    );
    return recordPage(
      result.rows,
      limit,
      "public-records",
      signature,
      "event_at",
      (row) => publicProjection(mapRecordRow(row)),
    );
  }

  async getOwner(userId: string, recordId: string): Promise<RecordResource> {
    const row = await loadRecord(this.database, recordId, userId, false);
    if (row === undefined) {
      throw notFound("record");
    }
    return mapRecordRow(row);
  }

  async getPublic(recordId: string): Promise<PublicRecordProjection> {
    const row = await loadRecord(this.database, recordId, undefined, true);
    if (row === undefined) {
      throw notFound("record");
    }
    return publicProjection(mapRecordRow(row));
  }

  async create(
    principal: Principal,
    input: CreateRecordInput,
    idempotencyKey: string,
    requestId: string,
  ): Promise<MutationResponse<RecordResource>> {
    assertApiKeyDevice(principal, input.deviceId);
    return this.translate(() =>
      executeIdempotentMutation(
        this.database,
        principal,
        "createRecord",
        idempotencyKey,
        { input },
        (queryable) =>
          createRecordInTransaction(queryable, principal, input, requestId),
      ),
    );
  }

  async replace(
    principal: Principal,
    recordId: string,
    input: ReplaceRecordInput,
    ifMatch: string,
    idempotencyKey: string,
    requestId: string,
  ): Promise<MutationResponse<RecordResource>> {
    assertApiKeyDevice(principal, input.deviceId);
    return this.translate(() =>
      executeIdempotentMutation(
        this.database,
        principal,
        "replaceRecord",
        idempotencyKey,
        { recordId, ifMatch, input },
        (queryable) =>
          replaceRecordInTransaction(
            queryable,
            principal,
            recordId,
            input,
            ifMatch,
            requestId,
          ),
      ),
    );
  }

  async patch(
    principal: Principal,
    recordId: string,
    input: UpdateRecordInput,
    ifMatch: string,
    idempotencyKey: string,
    requestId: string,
  ): Promise<MutationResponse<RecordResource>> {
    return this.mutateExisting(
      principal,
      "updateRecord",
      recordId,
      idempotencyKey,
      { recordId, ifMatch, input },
      async (queryable, current) => {
        requireMatchingEtag(
          ifMatch,
          resourceEtag("record", recordId, Number(current.revision)),
        );
        if (input.visibility !== current.visibility) {
          throw unprocessable(
            "Record visibility is immutable.",
            "visibility_immutable",
          );
        }
        const deviceId = input.deviceId ?? current.device_id;
        assertApiKeyDevice(principal, deviceId);
        await assertActiveOwnedDevice(queryable, principal.userId, deviceId);
        if (input.visibility === "private") {
          await patchPrivateRecord(
            queryable,
            principal.userId,
            current.id,
            current,
            input,
          );
        } else {
          await patchPublicRecord(
            queryable,
            principal.userId,
            current.id,
            current,
            input,
          );
        }
        await writeMutationAudit(
          queryable,
          principal,
          "record.update",
          "record",
          current.id,
          requestId,
        );
        return this.updatedResponse(queryable, principal.userId, recordId);
      },
    );
  }

  async delete(
    principal: Principal,
    recordId: string,
    ifMatch: string,
    idempotencyKey: string,
    requestId: string,
  ): Promise<MutationResponse<null>> {
    return this.translate(() =>
      executeIdempotentMutation(
        this.database,
        principal,
        "deleteRecord",
        idempotencyKey,
        { recordId, ifMatch },
        (queryable) =>
          deleteRecordInTransaction(
            queryable,
            principal,
            recordId,
            ifMatch,
            requestId,
          ),
      ),
    );
  }

  private async mutateExisting(
    principal: Principal,
    operationId: string,
    recordId: string,
    idempotencyKey: string,
    fingerprint: unknown,
    work: (
      queryable: Queryable,
      current: RecordRow,
    ) => Promise<MutationResponse<RecordResource>>,
  ): Promise<MutationResponse<RecordResource>> {
    return this.translate(() =>
      executeIdempotentMutation(
        this.database,
        principal,
        operationId,
        idempotencyKey,
        fingerprint,
        async (queryable) => {
          const current = await lockRecord(
            queryable,
            principal.userId,
            recordId,
          );
          if (current === undefined) {
            throw notFound("record");
          }
          return work(queryable, current);
        },
      ),
    );
  }

  private async updatedResponse(
    queryable: Queryable,
    userId: string,
    recordId: string,
  ): Promise<MutationResponse<RecordResource>> {
    const row = await loadRecord(queryable, recordId, userId, false);
    if (row === undefined) {
      throw new Error("Updated record could not be reloaded");
    }
    const resource = mapRecordRow(row);
    return {
      status: 200,
      headers: { etag: resourceEtag("record", recordId, resource.revision) },
      body: resource,
    };
  }

  private async translate<Result>(
    work: () => Promise<Result>,
  ): Promise<Result> {
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

/** Transaction-scoped record creation used by direct and sync APIs. */
export async function createRecordInTransaction(
  queryable: Queryable,
  principal: Principal,
  input: CreateRecordInput,
  requestId: string,
): Promise<MutationResponse<RecordResource>> {
  assertApiKeyDevice(principal, input.deviceId);
  await assertActiveOwnedDevice(queryable, principal.userId, input.deviceId);
  const visibility = input.visibility ?? "public";
  const internalId = input.originId ?? randomUUID();
  if (!isUuid(internalId)) {
    throw invalidRequest("originId must be a UUID.");
  }
  if (input.id !== undefined) {
    assertRecordPublicId(input.id);
  }
  if (visibility === "private" && input.originId === undefined) {
    throw unprocessable(
      "Private records require a client-generated originId for crypto profile v1.",
      "private_record_origin_id_required",
    );
  }
  let publicId: string;
  if (visibility === "private") {
    publicId = await createPrivateRecord(
      queryable,
      principal.userId,
      internalId,
      input as PrivateRecordInput,
    );
  } else {
    publicId = await createPublicRecord(
      queryable,
      principal.userId,
      internalId,
      input as PublicRecordInput,
    );
  }
  await writeMutationAudit(
    queryable,
    principal,
    "record.create",
    "record",
    internalId,
    requestId,
  );
  const row = await loadRecord(queryable, publicId, principal.userId, false);
  if (row === undefined) {
    throw new Error("Created record could not be reloaded");
  }
  const resource = mapRecordRow(row);
  return {
    status: 201,
    headers: {
      location: `/v1/records/${publicId}`,
      etag: resourceEtag("record", publicId, resource.revision),
    },
    body: resource,
  };
}

/** Transaction-scoped full replacement used by direct and sync APIs. */
export async function replaceRecordInTransaction(
  queryable: Queryable,
  principal: Principal,
  recordId: string,
  input: ReplaceRecordInput,
  ifMatch: string,
  requestId: string,
  includeDeleted = false,
): Promise<MutationResponse<RecordResource>> {
  assertApiKeyDevice(principal, input.deviceId);
  const current = await lockRecord(
    queryable,
    principal.userId,
    recordId,
    includeDeleted,
  );
  if (current === undefined) {
    throw notFound("record");
  }
  requireMatchingEtag(
    ifMatch,
    resourceEtag("record", recordId, Number(current.revision)),
  );
  if (input.id !== undefined && input.id !== recordId) {
    throw unprocessable(
      "The body id must match the record path id.",
      "record_id_mismatch",
    );
  }
  if (
    input.originId !== undefined &&
    input.originId.toLowerCase() !== current.id.toLowerCase()
  ) {
    throw unprocessable(
      "The body originId must match the record's immutable originId.",
      "record_origin_id_mismatch",
    );
  }
  const visibility = input.visibility ?? "public";
  if (visibility !== current.visibility) {
    throw unprocessable(
      "Record visibility is immutable.",
      "visibility_immutable",
    );
  }
  await assertActiveOwnedDevice(queryable, principal.userId, input.deviceId);
  if (visibility === "private") {
    await replacePrivateRecord(
      queryable,
      principal.userId,
      current.id,
      input as PrivateRecordInput,
    );
  } else {
    await replacePublicRecord(
      queryable,
      principal.userId,
      current.id,
      input as PublicRecordInput,
    );
  }
  await writeMutationAudit(
    queryable,
    principal,
    "record.replace",
    "record",
    current.id,
    requestId,
  );
  const row = await loadRecord(queryable, recordId, principal.userId, false);
  if (row === undefined) {
    throw new Error("Updated record could not be reloaded");
  }
  const resource = mapRecordRow(row);
  return {
    status: 200,
    headers: { etag: resourceEtag("record", recordId, resource.revision) },
    body: resource,
  };
}

/** Transaction-scoped soft deletion used by direct and sync APIs. */
export async function deleteRecordInTransaction(
  queryable: Queryable,
  principal: Principal,
  recordId: string,
  ifMatch: string,
  requestId: string,
): Promise<MutationResponse<null>> {
  const current = await lockRecord(queryable, principal.userId, recordId);
  if (current === undefined) {
    throw notFound("record");
  }
  requireMatchingEtag(
    ifMatch,
    resourceEtag("record", recordId, Number(current.revision)),
  );
  if (current.visibility === "private") {
    await queryable.query(
      `UPDATE records
       SET deleted_at = clock_timestamp(),
           cipher_algorithm = NULL,
           crypto_version = NULL,
           key_version = NULL,
           nonce = NULL,
           ciphertext = NULL,
           encrypted_content_type = NULL
      WHERE user_id = $1 AND id = $2`,
      [principal.userId, current.id],
    );
  } else {
    await queryable.query(
      "UPDATE records SET deleted_at = clock_timestamp() WHERE user_id = $1 AND id = $2",
      [principal.userId, current.id],
    );
  }
  await writeMutationAudit(
    queryable,
    principal,
    "record.delete",
    "record",
    current.id,
    requestId,
  );
  return { status: 204, headers: {}, body: null };
}

export async function loadRecordResourcesForSync(
  queryable: Queryable,
  userId: string,
  recordIds: readonly string[],
): Promise<ReadonlyMap<string, RecordResource>> {
  if (recordIds.length === 0) {
    return new Map();
  }
  const result = await queryable.query<RecordRow>(
    `SELECT ${RECORD_COLUMNS}
     FROM records r
     JOIN users author ON author.id = r.user_id
     WHERE r.user_id = $1
       AND r.id = ANY($2::uuid[])
       AND r.deleted_at IS NULL`,
    [userId, recordIds],
  );
  return new Map(result.rows.map((row) => [row.id, mapRecordRow(row)]));
}

export function mapRecordRow(row: RecordRow): RecordResource {
  const common: RecordCommon = {
    id: row.public_id,
    originId: row.id,
    userId: row.user_id,
    deviceId: row.device_id,
    revision: Number(row.revision),
    createdAt: isoDate(row.created_at),
    updatedAt: isoDate(row.updated_at),
    references: row.references,
  };
  if (row.visibility === "private") {
    if (
      row.nonce === null ||
      row.ciphertext === null ||
      row.cipher_algorithm !== "A256GCM" ||
      row.crypto_version !== 1 ||
      row.key_version !== 1 ||
      row.encrypted_content_type !== "application/vnd.exeligmos.record+json"
    ) {
      throw new Error("Private record has an invalid encryption envelope");
    }
    return {
      ...common,
      visibility: "private",
      encryption: {
        algorithm: "A256GCM",
        cryptoVersion: 1,
        keyVersion: 1,
        nonce: row.nonce.toString("base64"),
        ciphertext: row.ciphertext.toString("base64"),
        contentType: "application/vnd.exeligmos.record+json",
      },
      media: row.media,
    };
  }
  if (row.event_at === null || row.public_payload === null) {
    throw new Error("Public record has no occurrence time or payload");
  }
  const source = sourceFromRow(row);
  return {
    ...common,
    visibility: "public",
    author: row.author,
    occurredAt: isoDate(row.event_at),
    ...(row.end_at === null ? {} : { endedAt: isoDate(row.end_at) }),
    payload: row.public_payload,
    ...(row.template_id === null || row.template_version === null
      ? {}
      : {
          template: {
            templateId: row.template_id,
            version: row.template_version,
          },
        }),
    tagIds: row.tag_ids,
    tags: row.public_tags,
    media: row.media,
    metadata: row.metadata,
    ...(source === undefined ? {} : { source }),
  };
}

export function publicProjection(
  record: RecordResource,
): PublicRecordProjection {
  if (record.visibility !== "public") {
    throw notFound("record");
  }
  return {
    id: record.id,
    userId: record.userId,
    author: record.author,
    visibility: "public",
    occurredAt: record.occurredAt,
    ...(record.endedAt === undefined ? {} : { endedAt: record.endedAt }),
    payload: record.payload,
    ...(record.template === undefined ? {} : { template: record.template }),
    tagIds: record.tagIds,
    tags: record.tags,
    media: record.media.map((media) => {
      if (media.publicContentUrl === undefined) {
        throw new Error("Public record contains media without a public URL");
      }
      return {
        id: media.id,
        fileName: media.fileName,
        contentType: media.contentType,
        byteLength: media.byteLength,
        sha256: media.sha256,
        createdAt: media.createdAt,
        publicContentUrl: media.publicContentUrl,
      };
    }),
    metadata: record.metadata,
    references: record.references,
    ...(record.source === undefined ? {} : { source: record.source }),
    revision: record.revision,
    createdAt: record.createdAt,
    updatedAt: record.updatedAt,
  };
}

async function createPublicRecord(
  queryable: Queryable,
  userId: string,
  internalId: string,
  input: PublicRecordInput,
): Promise<string> {
  const content = await publicContent(queryable, userId, input);
  assertEndAfterStart(input.occurredAt, input.endedAt);
  const tagIds = normalizedIds(input.tagIds ?? [], "tagIds");
  const mediaIds = normalizedIds(input.mediaIds ?? [], "mediaIds");
  await assertTagIds(queryable, userId, tagIds);
  await assertMediaIds(queryable, userId, mediaIds, "public");
  const source = input.source;
  const metadata = input.metadata ?? {};
  const sourceMetadata = source?.metadata ?? {};
  assertPublicRecordDocumentSizes(content.payload, metadata, sourceMetadata);
  const publicId = await insertWithRecordPublicId(
    input.id,
    async (candidate) =>
      queryable.query(
        `INSERT INTO records (
           id, public_id, user_id, device_id, visibility, event_at, end_at,
           public_payload, metadata, template_id, template_version, source_kind,
           source_provider, source_external_id, source_url, source_metadata
         ) VALUES (
           $1, $2, $3, $4, 'public', $5::timestamptz, $6::timestamptz,
           $7::jsonb, $8::jsonb, $9, $10, $11, $12, $13, $14, $15::jsonb
         )
         ON CONFLICT (public_id) DO NOTHING
         RETURNING id`,
        [
          internalId,
          candidate,
          userId,
          input.deviceId,
          requiredDate(input.occurredAt, "occurredAt"),
          nullableDate(input.endedAt, "endedAt"),
          JSON.stringify(content.payload),
          JSON.stringify(metadata),
          content.templateId,
          content.templateVersion,
          source?.kind ?? null,
          source?.provider ?? null,
          source?.externalId ?? null,
          source?.url ?? null,
          JSON.stringify(sourceMetadata),
        ],
      ),
  );
  await replaceAssociations(queryable, userId, internalId, tagIds, mediaIds, true);
  await replaceResourceReferences(
    queryable,
    userId,
    "record",
    internalId,
    input.references ?? [],
  );
  return publicId;
}

async function createPrivateRecord(
  queryable: Queryable,
  userId: string,
  internalId: string,
  input: PrivateRecordInput,
): Promise<string> {
  if (input.originId !== internalId) {
    throw unprocessable(
      "Private record originId must be client generated.",
      "private_record_origin_id_required",
    );
  }
  await assertEncryptionProfile(queryable, userId);
  const encryption = validateEncryption(input.encryption);
  const mediaIds = normalizedIds(input.mediaIds ?? [], "mediaIds");
  await assertMediaIds(queryable, userId, mediaIds, "private");
  const publicId = await insertWithRecordPublicId(
    input.id,
    async (candidate) =>
      queryable.query(
        `INSERT INTO records (
           id, public_id, user_id, device_id, visibility, cipher_algorithm,
           crypto_version, key_version, nonce, ciphertext, encrypted_content_type
         ) VALUES ($1, $2, $3, $4, 'private', 'A256GCM', 1, 1, $5, $6,
           'application/vnd.exeligmos.record+json')
         ON CONFLICT (public_id) DO NOTHING
         RETURNING id`,
        [
          internalId,
          candidate,
          userId,
          input.deviceId,
          encryption.nonce,
          encryption.ciphertext,
        ],
      ),
  );
  await replaceAssociations(queryable, userId, internalId, [], mediaIds, false);
  await replaceResourceReferences(
    queryable,
    userId,
    "record",
    internalId,
    input.references ?? [],
  );
  return publicId;
}

async function insertWithRecordPublicId(
  requestedId: string | undefined,
  insert: (candidate: string) => Promise<{ readonly rowCount: number | null }>,
): Promise<string> {
  if (requestedId !== undefined) {
    assertRecordPublicId(requestedId);
  }
  for (let attempt = 0; attempt < RECORD_PUBLIC_ID_ALLOCATION_ATTEMPTS; attempt += 1) {
    const candidate = requestedId ?? generateRecordPublicId();
    const result = await insert(candidate);
    if (result.rowCount === 1) {
      return candidate;
    }
    if (requestedId !== undefined) {
      throw recordIdCollision(requestedId);
    }
  }
  throw new Error("Could not allocate a unique record public identifier");
}

function recordIdCollision(id: string): HttpProblem {
  return new HttpProblem({
    status: 409,
    code: "record_id_collision",
    title: "Conflict",
    type: "urn:exeligmos:problem:record-id-collision",
    detail: `Record ID ${id} is already allocated. Generate a new ID and retry.`,
  });
}

async function replacePublicRecord(
  queryable: Queryable,
  userId: string,
  id: string,
  input: PublicRecordInput,
): Promise<void> {
  const content = await publicContent(queryable, userId, input);
  const tagIds = normalizedIds(input.tagIds ?? [], "tagIds");
  const mediaIds = normalizedIds(input.mediaIds ?? [], "mediaIds");
  await assertTagIds(queryable, userId, tagIds);
  await assertMediaIds(queryable, userId, mediaIds, "public");
  assertEndAfterStart(input.occurredAt, input.endedAt);
  const source = input.source;
  const metadata = input.metadata ?? {};
  const sourceMetadata = source?.metadata ?? {};
  assertPublicRecordDocumentSizes(content.payload, metadata, sourceMetadata);
  await queryable.query(
    `UPDATE records SET
       deleted_at = NULL,
       device_id = $3,
       event_at = $4::timestamptz,
       end_at = $5::timestamptz,
       public_payload = $6::jsonb,
       metadata = $7::jsonb,
       template_id = $8,
       template_version = $9,
       source_kind = $10,
       source_provider = $11,
       source_external_id = $12,
       source_url = $13,
       source_metadata = $14::jsonb,
       updated_at = clock_timestamp()
     WHERE user_id = $1 AND id = $2`,
    [
      userId,
      id,
      input.deviceId,
      requiredDate(input.occurredAt, "occurredAt"),
      nullableDate(input.endedAt, "endedAt"),
      JSON.stringify(content.payload),
      JSON.stringify(metadata),
      content.templateId,
      content.templateVersion,
      source?.kind ?? null,
      source?.provider ?? null,
      source?.externalId ?? null,
      source?.url ?? null,
      JSON.stringify(sourceMetadata),
    ],
  );
  await replaceAssociations(queryable, userId, id, tagIds, mediaIds, true);
  await replaceResourceReferences(
    queryable,
    userId,
    "record",
    id,
    input.references ?? [],
  );
}

async function replacePrivateRecord(
  queryable: Queryable,
  userId: string,
  id: string,
  input: PrivateRecordInput,
): Promise<void> {
  await assertEncryptionProfile(queryable, userId);
  const encryption = validateEncryption(input.encryption);
  const mediaIds = normalizedIds(input.mediaIds ?? [], "mediaIds");
  await assertMediaIds(queryable, userId, mediaIds, "private");
  await queryable.query(
    `UPDATE records SET
       deleted_at = NULL,
       device_id = $3,
       cipher_algorithm = 'A256GCM',
       crypto_version = 1,
       key_version = 1,
       nonce = $4,
       ciphertext = $5,
       encrypted_content_type = 'application/vnd.exeligmos.record+json',
       updated_at = clock_timestamp()
     WHERE user_id = $1 AND id = $2`,
    [userId, id, input.deviceId, encryption.nonce, encryption.ciphertext],
  );
  await replaceAssociations(queryable, userId, id, [], mediaIds, false);
  await replaceResourceReferences(
    queryable,
    userId,
    "record",
    id,
    input.references ?? [],
  );
}

async function patchPublicRecord(
  queryable: Queryable,
  userId: string,
  id: string,
  current: RecordRow,
  input: PublicRecordPatch,
): Promise<void> {
  const occurredAt =
    input.occurredAt ?? dateString(current.event_at, "event_at");
  const endedAt =
    input.endedAt === undefined
      ? dateStringOrUndefined(current.end_at)
      : input.endedAt;
  assertEndAfterStart(occurredAt, endedAt ?? undefined);
  const source =
    input.source === undefined
      ? sourceFromRow(current)
      : (input.source ?? undefined);
  const payload =
    input.payload === undefined
      ? current.public_payload
      : mergeJsonObject(current.public_payload ?? {}, input.payload);
  if (payload === null || Object.keys(payload).length === 0) {
    throw unprocessable(
      "A public record payload cannot become empty.",
      "invalid_payload",
    );
  }
  const metadata =
    input.metadata === undefined
      ? current.metadata
      : mergeJsonObject(current.metadata, input.metadata);
  const sourceMetadata = source?.metadata ?? {};
  assertPublicRecordDocumentSizes(payload, metadata, sourceMetadata);
  await queryable.query(
    `UPDATE records SET
       device_id = $3,
       event_at = $4::timestamptz,
       end_at = $5::timestamptz,
       public_payload = $6::jsonb,
       metadata = $7::jsonb,
       source_kind = $8,
       source_provider = $9,
       source_external_id = $10,
       source_url = $11,
       source_metadata = $12::jsonb,
       updated_at = clock_timestamp()
     WHERE user_id = $1 AND id = $2`,
    [
      userId,
      id,
      input.deviceId ?? current.device_id,
      requiredDate(occurredAt, "occurredAt"),
      nullableDate(endedAt ?? undefined, "endedAt"),
      JSON.stringify(payload),
      JSON.stringify(metadata),
      source?.kind ?? null,
      source?.provider ?? null,
      source?.externalId ?? null,
      source?.url ?? null,
      JSON.stringify(sourceMetadata),
    ],
  );
  if (input.tagIds !== undefined) {
    const tagIds = normalizedIds(input.tagIds, "tagIds");
    await assertTagIds(queryable, userId, tagIds);
    await replaceTags(queryable, userId, id, tagIds);
  }
  if (input.mediaIds !== undefined) {
    const mediaIds = normalizedIds(input.mediaIds, "mediaIds");
    await assertMediaIds(queryable, userId, mediaIds, "public");
    await replaceMedia(queryable, userId, id, mediaIds);
  }
  if (input.references !== undefined) {
    await replaceResourceReferences(
      queryable,
      userId,
      "record",
      id,
      input.references,
    );
  }
}

async function patchPrivateRecord(
  queryable: Queryable,
  userId: string,
  id: string,
  current: RecordRow,
  input: PrivateRecordPatch,
): Promise<void> {
  await assertEncryptionProfile(queryable, userId);
  const encryption = validateEncryption(input.encryption);
  await queryable.query(
    `UPDATE records SET
       device_id = $3,
       nonce = $4,
       ciphertext = $5,
       updated_at = clock_timestamp()
     WHERE user_id = $1 AND id = $2`,
    [
      userId,
      id,
      input.deviceId ?? current.device_id,
      encryption.nonce,
      encryption.ciphertext,
    ],
  );
  if (input.mediaIds !== undefined) {
    const mediaIds = normalizedIds(input.mediaIds, "mediaIds");
    await assertMediaIds(queryable, userId, mediaIds, "private");
    await replaceMedia(queryable, userId, id, mediaIds);
  }
  if (input.references !== undefined) {
    await replaceResourceReferences(
      queryable,
      userId,
      "record",
      id,
      input.references,
    );
  }
}

async function publicContent(
  queryable: Queryable,
  userId: string,
  input: PublicRecordInput,
): Promise<{
  readonly payload: JsonObject;
  readonly templateId: string | null;
  readonly templateVersion: number | null;
}> {
  const hasPayload = input.payload !== undefined;
  const hasRender = input.render !== undefined;
  if (hasPayload === hasRender) {
    throw unprocessable(
      "A public record requires exactly one of payload or render.",
      "record_content_ambiguous",
    );
  }
  if (input.payload !== undefined) {
    if (!isObject(input.payload) || Object.keys(input.payload).length === 0) {
      throw unprocessable(
        "payload must be a non-empty JSON object.",
        "invalid_payload",
      );
    }
    return { payload: input.payload, templateId: null, templateVersion: null };
  }
  const render = input.render as TemplateRenderRequest;
  const result = await queryable.query<TemplateRow>(
    `SELECT t.id, tv.version, tv.body, tv.variable_schema
     FROM templates t
     JOIN template_versions tv
       ON tv.user_id = t.user_id AND tv.template_id = t.id
      AND tv.version = COALESCE($3::integer, t.version)
     WHERE t.user_id = $1 AND t.id = $2 AND t.deleted_at IS NULL AND t.retired_at IS NULL`,
    [userId, render.templateId, render.version ?? null],
  );
  const template = result.rows[0];
  if (template === undefined) {
    throw notFound("template");
  }
  validateTemplateVariables(template, render.variables);
  return {
    payload: renderTemplateBody(template.body, render.variables),
    templateId: template.id,
    templateVersion: template.version,
  };
}

function validateTemplateVariables(
  template: TemplateRow,
  variables: JsonObject,
): void {
  const key = `${template.id}:${template.version}`;
  const schemaSignature = cursorSignature(template.variable_schema);
  let cached = templateValidatorCache.get(key);
  if (cached === undefined || cached.schemaSignature !== schemaSignature) {
    let validate: ValidateFunction<unknown>;
    try {
      // Keep schema registries tenant-local. Reusing one Ajv instance lets a
      // user-controlled `$id` collide with another template's otherwise valid
      // schema. Async validators are not part of this synchronous render path.
      validate = createTemplateSchemaAjv().compile(template.variable_schema);
      if (
        (validate as ValidateFunction<unknown> & { readonly $async?: boolean })
          .$async === true
      ) {
        throw new Error("Async JSON Schemas are unsupported");
      }
    } catch {
      throw templateValidationProblem("invalid_template_schema", [
        {
          path: "/render/variables",
          code: "invalid_schema",
          message: "The selected template has an invalid variable schema.",
        },
      ]);
    }
    cached = { schemaSignature, validate };
    templateValidatorCache.set(key, cached);
    if (templateValidatorCache.size > MAX_TEMPLATE_VALIDATORS) {
      const oldest = templateValidatorCache.keys().next().value as
        string | undefined;
      if (oldest !== undefined) {
        templateValidatorCache.delete(oldest);
      }
    }
  }
  if (!cached.validate(variables)) {
    throw templateValidationProblem(
      "template_variables_invalid",
      (cached.validate.errors ?? []).slice(0, 100).map(templateFieldError),
    );
  }
}

function createTemplateSchemaAjv(): Ajv2020 {
  return addFormats(
    new Ajv2020({ allErrors: true, strict: true, validateFormats: true }),
  );
}

function templateFieldError(error: ErrorObject): {
  readonly path: string;
  readonly code: string;
  readonly message: string;
} {
  const missingProperty =
    error.keyword === "required" && "missingProperty" in error.params
      ? String(error.params.missingProperty)
      : undefined;
  const path = `${error.instancePath || "/"}${
    missingProperty === undefined
      ? ""
      : `${error.instancePath.length === 0 ? "" : "/"}${escapeJsonPointer(missingProperty)}`
  }`;
  return {
    path: path.startsWith("/")
      ? `/render/variables${path === "/" ? "" : path}`
      : "/render/variables",
    code: `schema_${error.keyword.replaceAll(/[^a-zA-Z0-9_]/g, "_").toLowerCase()}`,
    message:
      error.message ?? "The value does not match the template variable schema.",
  };
}

function templateValidationProblem(
  code: string,
  errors: readonly {
    readonly path: string;
    readonly code: string;
    readonly message: string;
  }[],
): HttpProblem {
  return new HttpProblem({
    status: 422,
    code,
    title: "Unprocessable Content",
    type: `urn:exeligmos:problem:${code.replaceAll("_", "-")}`,
    detail: "Template variables do not satisfy the selected template schema.",
    extensions: { errors },
  });
}

function escapeJsonPointer(value: string): string {
  return value.replaceAll("~", "~0").replaceAll("/", "~1");
}

export function renderTemplateBody(
  body: JsonObject,
  variables: JsonObject,
): JsonObject {
  const rendered = renderTemplateValue(body, variables);
  if (!isObject(rendered) || Object.keys(rendered).length === 0) {
    throw unprocessable(
      "The rendered template body must be a non-empty object.",
      "invalid_render",
    );
  }
  return rendered;
}

function renderTemplateValue(value: unknown, variables: JsonObject): unknown {
  if (Array.isArray(value)) {
    return value.map((child) => renderTemplateValue(child, variables));
  }
  if (isObject(value)) {
    return Object.fromEntries(
      Object.entries(value).map(([key, child]) => [
        key,
        renderTemplateValue(child, variables),
      ]),
    );
  }
  if (typeof value !== "string") {
    return value;
  }
  if (/\{\{\s*>/.test(value)) {
    throw unprocessable(
      "Template partials are not supported because templates have no partial registry.",
      "template_partial_unsupported",
    );
  }
  const exact = value.match(/^\s*\{\{\{?\s*([A-Za-z0-9_.]+)\s*\}?\}\}\s*$/);
  if (exact?.[1] !== undefined) {
    const resolved = resolveVariable(variables, exact[1]);
    if (resolved === undefined) {
      throw unprocessable(
        `Template variable ${exact[1]} is missing.`,
        "template_variable_missing",
      );
    }
    return resolved;
  }
  try {
    return Mustache.render(value, variables);
  } catch {
    throw unprocessable(
      "The template contains invalid Mustache syntax.",
      "invalid_template",
    );
  }
}

function resolveVariable(variables: JsonObject, path: string): unknown {
  let current: unknown = variables;
  for (const segment of path.split(".")) {
    if (
      !isObject(current) ||
      !Object.prototype.hasOwnProperty.call(current, segment)
    ) {
      return undefined;
    }
    current = current[segment];
  }
  return current;
}

async function lockRecord(
  queryable: Queryable,
  userId: string,
  recordId: string,
  includeDeleted = false,
): Promise<RecordRow | undefined> {
  const result = await queryable.query<RecordRow>(
    `SELECT ${RECORD_COLUMNS}
     FROM records r
     JOIN users author ON author.id = r.user_id
     WHERE r.user_id = $1 AND r.public_id = $2
       AND ($3::boolean OR r.deleted_at IS NULL)
     FOR UPDATE OF r`,
    [userId, recordId, includeDeleted],
  );
  return result.rows[0];
}

async function loadRecord(
  queryable: Queryable,
  recordId: string,
  userId: string | undefined,
  publicOnly: boolean,
): Promise<RecordRow | undefined> {
  const values: unknown[] = [recordId];
  const where = ["r.public_id = $1", "r.deleted_at IS NULL"];
  if (userId !== undefined) {
    values.push(userId);
    where.push(`r.user_id = $${values.length}`);
  }
  if (publicOnly) {
    where.push("r.visibility = 'public'");
    where.push("author.status = 'active'");
  }
  const result = await queryable.query<RecordRow>(
    `SELECT ${RECORD_COLUMNS}
     FROM records r
     JOIN users author ON author.id = r.user_id
     WHERE ${where.join(" AND ")}`,
    values,
  );
  return result.rows[0];
}

async function assertTagIds(
  queryable: Queryable,
  userId: string,
  tagIds: readonly string[],
): Promise<void> {
  if (tagIds.length === 0) {
    return;
  }
  // Hold shared row locks until the record mutation commits. Tag retirement
  // takes the corresponding update lock, so it cannot race a newly attached
  // active record past the tag-in-use check.
  const result = await queryable.query(
    `SELECT id
     FROM tags
     WHERE user_id = $1 AND id = ANY($2::uuid[]) AND deleted_at IS NULL
     FOR SHARE`,
    [userId, tagIds],
  );
  if (result.rowCount !== tagIds.length) {
    throw unprocessable("One or more tagIds do not exist.", "invalid_tag_ids");
  }
}

async function assertEncryptionProfile(
  queryable: Queryable,
  userId: string,
): Promise<void> {
  const result = await queryable.query(
    `SELECT 1
     FROM user_encryption_profiles
     WHERE user_id = $1 AND crypto_version = 1 AND key_version = 1`,
    [userId],
  );
  if (result.rowCount === 0) {
    throw unprocessable(
      "Initialize encryption profile v1 before storing private records.",
      "encryption_profile_required",
    );
  }
}

async function assertMediaIds(
  queryable: Queryable,
  userId: string,
  mediaIds: readonly string[],
  visibility: RecordVisibility,
): Promise<void> {
  if (mediaIds.length === 0) {
    return;
  }
  const result = await queryable.query<CountRow>(
    `SELECT count(*)::integer AS count
     FROM media_objects
     WHERE user_id = $1 AND id = ANY($2::uuid[]) AND visibility = $3
       AND status = 'ready' AND deleted_at IS NULL`,
    [userId, mediaIds, visibility],
  );
  if (result.rows[0]?.count !== mediaIds.length) {
    throw unprocessable(
      "One or more mediaIds do not exist or do not match record visibility.",
      "invalid_media_ids",
    );
  }
}

async function replaceAssociations(
  queryable: Queryable,
  userId: string,
  recordId: string,
  tagIds: readonly string[],
  mediaIds: readonly string[],
  includeTags: boolean,
): Promise<void> {
  if (includeTags) {
    await replaceTags(queryable, userId, recordId, tagIds);
  }
  await replaceMedia(queryable, userId, recordId, mediaIds);
}

async function replaceTags(
  queryable: Queryable,
  userId: string,
  recordId: string,
  tagIds: readonly string[],
): Promise<void> {
  await queryable.query(
    "DELETE FROM record_tags WHERE user_id = $1 AND record_id = $2",
    [userId, recordId],
  );
  if (tagIds.length > 0) {
    await queryable.query(
      `INSERT INTO record_tags (user_id, record_id, tag_id)
       SELECT $1, $2, value::uuid FROM unnest($3::text[]) AS value`,
      [userId, recordId, tagIds],
    );
  }
}

async function replaceMedia(
  queryable: Queryable,
  userId: string,
  recordId: string,
  mediaIds: readonly string[],
): Promise<void> {
  await queryable.query(
    "DELETE FROM record_media WHERE user_id = $1 AND record_id = $2",
    [userId, recordId],
  );
  if (mediaIds.length > 0) {
    await queryable.query(
      `INSERT INTO record_media (user_id, record_id, media_id, position)
       SELECT $1, $2, value::uuid, (ordinality - 1)::integer
       FROM unnest($3::text[]) WITH ORDINALITY AS media(value, ordinality)`,
      [userId, recordId, mediaIds],
    );
  }
}

function validateEncryption(encryption: CiphertextEnvelope): {
  readonly nonce: Buffer;
  readonly ciphertext: Buffer;
} {
  if (
    encryption.algorithm !== "A256GCM" ||
    encryption.cryptoVersion !== 1 ||
    encryption.keyVersion !== 1 ||
    encryption.contentType !== "application/vnd.exeligmos.record+json"
  ) {
    throw unprocessable(
      "The encryption profile is not supported.",
      "unsupported_encryption",
    );
  }
  const nonce = strictBase64(encryption.nonce, "encryption.nonce");
  const ciphertext = strictBase64(
    encryption.ciphertext,
    "encryption.ciphertext",
  );
  if (nonce.length !== 12 || ciphertext.length < 16) {
    throw unprocessable(
      "The encryption nonce must be 12 bytes and ciphertext must include a 16-byte tag.",
      "invalid_encryption",
    );
  }
  if (ciphertext.length > PRIVATE_RECORD_CIPHERTEXT_MAX_BYTES) {
    throw unprocessable(
      `encryption.ciphertext must decode to at most ${PRIVATE_RECORD_CIPHERTEXT_MAX_BYTES} bytes.`,
      "ciphertext_too_large",
    );
  }
  return { nonce, ciphertext };
}

function assertPublicRecordDocumentSizes(
  payload: JsonObject,
  metadata: JsonObject,
  sourceMetadata: JsonObject,
): void {
  assertSerializedJsonSize(payload, PUBLIC_RECORD_PAYLOAD_MAX_BYTES, "payload");
  assertSerializedJsonSize(metadata, RESOURCE_METADATA_MAX_BYTES, "metadata");
  assertSerializedJsonSize(
    sourceMetadata,
    RESOURCE_METADATA_MAX_BYTES,
    "source.metadata",
  );
}

function strictBase64(value: string, name: string): Buffer {
  if (
    !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(
      value,
    )
  ) {
    throw unprocessable(
      `${name} must be canonical base64.`,
      "invalid_encryption",
    );
  }
  return Buffer.from(value, "base64");
}

function normalizedIds(
  values: readonly string[],
  name: string,
): readonly string[] {
  if (values.length > 200) {
    throw unprocessable(
      `${name} cannot contain more than 200 ids.`,
      `invalid_${name}`,
    );
  }
  if (
    new Set(values).size !== values.length ||
    values.some((value) => !isUuid(value))
  ) {
    throw unprocessable(
      `${name} must contain unique UUIDs.`,
      `invalid_${name}`,
    );
  }
  return values;
}

function sourceFromRow(row: RecordRow): SourceReference | undefined {
  if (row.source_kind === null || row.source_provider === null) {
    return undefined;
  }
  return {
    kind: row.source_kind,
    provider: row.source_provider,
    ...(row.source_external_id === null
      ? {}
      : { externalId: row.source_external_id }),
    ...(row.source_url === null ? {} : { url: row.source_url }),
    ...(Object.keys(row.source_metadata).length === 0
      ? {}
      : { metadata: row.source_metadata }),
  };
}

function recordPage<Resource>(
  rows: readonly RecordRow[],
  limit: number,
  kind: string,
  signature: string,
  sortColumn: "updated_at" | "event_at" | "owner_start",
  mapper: (row: RecordRow) => Resource,
): Page<Resource> {
  const hasMore = rows.length > limit;
  const visible = rows.slice(0, limit);
  const last = visible.at(-1);
  return {
    data: visible.map(mapper),
    hasMore,
    ...(hasMore && last !== undefined
      ? {
          nextCursor: encodeCursor(
            kind,
            signature,
            isoDate(
              sortColumn === "updated_at"
                ? last.updated_at
                : sortColumn === "owner_start"
                  ? (last.event_at ?? last.created_at)
                  : dateValue(last.event_at),
            ),
            last.id,
          ),
        }
      : {}),
  };
}

function addEquality(
  where: string[],
  values: unknown[],
  column: string,
  value: string | undefined,
): void {
  if (value !== undefined) {
    values.push(value);
    where.push(`${column} = $${values.length}`);
  }
}

function addUuidEquality(
  where: string[],
  values: unknown[],
  column: string,
  value: string | undefined,
): void {
  if (value !== undefined) {
    if (!isUuid(value)) {
      throw invalidRequest(
        `${column.split(".").at(-1) ?? "id"} must be a UUID.`,
      );
    }
    values.push(value);
    where.push(`${column} = $${values.length}::uuid`);
  }
}

function addTimestampBound(
  where: string[],
  values: unknown[],
  column: string,
  operator: ">=" | "<",
  value: string | undefined,
): void {
  if (value !== undefined) {
    values.push(value);
    where.push(`${column} ${operator} $${values.length}::timestamptz`);
  }
}

function assertDateOrder(
  lower: string | undefined,
  upper: string | undefined,
  lowerName: string,
  upperName: string,
): void {
  if (
    lower !== undefined &&
    upper !== undefined &&
    Date.parse(lower) >= Date.parse(upper)
  ) {
    throw invalidRequest(`${lowerName} must precede ${upperName}.`);
  }
}

function assertEndAfterStart(
  startsAt: string,
  endsAt: string | undefined,
): void {
  const start = requiredDate(startsAt, "occurredAt");
  const end = nullableDate(endsAt, "endedAt");
  if (end !== null && Date.parse(end) < Date.parse(start)) {
    throw unprocessable(
      "endedAt must not precede occurredAt.",
      "invalid_record_interval",
    );
  }
}

function requiredDate(value: unknown, name: string): string {
  const parsed = optionalDate(value, name);
  if (parsed === undefined) {
    throw invalidRequest(`${name} is required.`);
  }
  return parsed;
}

function nullableDate(value: unknown, name: string): string | null {
  return value === undefined || value === null
    ? null
    : requiredDate(value, name);
}

function dateString(value: Date | string | null, column: string): string {
  if (value === null) {
    throw new Error(`Record ${column} is unexpectedly null`);
  }
  return isoDate(value);
}

function dateStringOrUndefined(
  value: Date | string | null,
): string | undefined {
  return value === null ? undefined : isoDate(value);
}

function dateValue(value: Date | string | null): Date | string {
  if (value === null) {
    throw new Error("Cursor sort value is unexpectedly null");
  }
  return value;
}

function isObject(value: unknown): value is JsonObject {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function isUuid(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(
    value,
  );
}
