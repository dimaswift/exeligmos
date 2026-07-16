import { randomUUID } from "node:crypto";
import type { Readable } from "node:stream";

import type { QueryResultRow } from "pg";

import type { Principal } from "../auth/principal.js";
import type { Database, Queryable } from "../db/database.js";
import { HttpProblem } from "../http/problem.js";
import {
  MediaStorageIntegrityError,
  MediaStorageMissingError,
  mediaUploadStorageKey,
  type MediaStorage,
} from "../media/storage.js";
import {
  assertActiveOwnedDevice,
  assertApiKeyDevice,
  databaseErrorCode,
  executeIdempotentMutation,
  isoDate,
  type MutationResponse,
  requireMatchingEtag,
  translateDatabaseError,
  unprocessable,
} from "./shared.js";

export const MAX_MEDIA_BYTE_LENGTH = 5_368_709_120;
export const DEFAULT_MEDIA_UPLOAD_TTL_MS = 24 * 60 * 60 * 1_000;

export interface MediaEncryptionInput {
  readonly algorithm: "A256GCM";
  readonly cryptoVersion: 1;
  readonly keyVersion: 1;
  readonly nonce: string;
  readonly plaintextContentType?: string;
}

export interface CreateMediaUploadInput {
  readonly mediaId?: string;
  readonly deviceId: string;
  readonly fileName: string;
  readonly contentType: string;
  readonly byteLength: number;
  readonly sha256: string;
  readonly encryption?: MediaEncryptionInput;
}

export type MediaUploadStatus =
  | "reserved"
  | "received"
  | "completed"
  | "aborted"
  | "expired";

export interface MediaUploadResource {
  readonly id: string;
  readonly userId: string;
  readonly deviceId: string;
  readonly status: MediaUploadStatus;
  readonly fileName: string;
  readonly contentType: string;
  readonly byteLength: number;
  readonly receivedBytes: number;
  readonly sha256: string;
  readonly encryption?: MediaEncryptionInput;
  readonly uploadUrl: string;
  readonly expiresAt: string;
  readonly createdAt: string;
  readonly mediaId: string;
}

export interface MediaObjectResource {
  readonly id: string;
  readonly userId: string;
  readonly deviceId: string;
  readonly fileName: string;
  readonly contentType: string;
  readonly byteLength: number;
  readonly sha256: string;
  readonly encryption?: MediaEncryptionInput;
  readonly revision: number;
  readonly createdAt: string;
  readonly contentUrl: string;
  readonly publicContentUrl?: string;
}

export interface MediaDownload {
  readonly stream: Readable;
  readonly byteLength: number;
  readonly contentType: string;
  readonly sha256: string;
  readonly etag: string;
}

export interface MediaServiceOptions {
  readonly maxByteLength?: number;
  readonly uploadTtlMs?: number;
}

export interface MediaRow extends QueryResultRow {
  readonly id: string;
  readonly user_id: string;
  readonly device_id: string;
  readonly visibility: "public" | "private";
  readonly status: "ready" | "deleted";
  readonly file_name: string;
  readonly content_type: string;
  readonly byte_size: string | number;
  readonly sha256: Buffer;
  readonly storage_key: string;
  readonly cipher_algorithm: string | null;
  readonly crypto_version: number | null;
  readonly key_version: number | null;
  readonly nonce: Buffer | null;
  readonly plaintext_content_type: string | null;
  readonly revision: string | number;
  readonly created_at: Date | string;
  readonly updated_at: Date | string;
  readonly deleted_at: Date | string | null;
}

interface MediaUploadRow extends QueryResultRow {
  readonly id: string;
  readonly user_id: string;
  readonly device_id: string;
  readonly requested_media_id: string;
  readonly media_id: string | null;
  readonly status: MediaUploadStatus;
  readonly file_name: string;
  readonly content_type: string;
  readonly byte_size: string | number;
  readonly received_bytes: string | number;
  readonly sha256: Buffer;
  readonly temporary_storage_key: string;
  readonly cipher_algorithm: string | null;
  readonly crypto_version: number | null;
  readonly key_version: number | null;
  readonly nonce: Buffer | null;
  readonly plaintext_content_type: string | null;
  readonly created_at: Date | string;
  readonly updated_at: Date | string;
  readonly expires_at: Date | string;
  readonly completed_at: Date | string | null;
  readonly aborted_at: Date | string | null;
}

interface LinkRow extends QueryResultRow {
  readonly linked: boolean;
}

const MEDIA_COLUMNS = `
  m.id,
  m.user_id,
  m.device_id,
  m.visibility,
  m.status,
  m.file_name,
  m.content_type,
  m.byte_size,
  m.sha256,
  m.storage_key,
  m.cipher_algorithm,
  m.crypto_version,
  m.key_version,
  m.nonce,
  m.plaintext_content_type,
  m.revision,
  m.created_at,
  m.updated_at,
  m.deleted_at
`;

const MEDIA_CONTENT_TYPE_PATTERN =
  /^[A-Za-z0-9][A-Za-z0-9.+_-]{0,126}\/[A-Za-z0-9][A-Za-z0-9.+_-]{0,126}$/;

const UPLOAD_COLUMNS = `
  id,
  user_id,
  device_id,
  requested_media_id,
  media_id,
  status,
  file_name,
  content_type,
  byte_size,
  received_bytes,
  sha256,
  temporary_storage_key,
  cipher_algorithm,
  crypto_version,
  key_version,
  nonce,
  plaintext_content_type,
  created_at,
  updated_at,
  expires_at,
  completed_at,
  aborted_at
`;

export class MediaService {
  private readonly maxByteLength: number;
  private readonly uploadTtlMs: number;

  constructor(
    private readonly database: Database,
    private readonly storage: MediaStorage,
    options: MediaServiceOptions = {},
  ) {
    this.maxByteLength = options.maxByteLength ?? MAX_MEDIA_BYTE_LENGTH;
    this.uploadTtlMs = options.uploadTtlMs ?? DEFAULT_MEDIA_UPLOAD_TTL_MS;
    if (
      !Number.isSafeInteger(this.maxByteLength) ||
      this.maxByteLength < 1 ||
      this.maxByteLength > MAX_MEDIA_BYTE_LENGTH
    ) {
      throw new Error(`maxByteLength must be between 1 and ${MAX_MEDIA_BYTE_LENGTH}`);
    }
    if (!Number.isSafeInteger(this.uploadTtlMs) || this.uploadTtlMs < 60_000) {
      throw new Error("uploadTtlMs must be a safe integer of at least 60000");
    }
  }

  async createUpload(
    principal: Principal,
    input: CreateMediaUploadInput,
    idempotencyKey: string,
    requestId: string,
  ): Promise<MutationResponse<MediaUploadResource>> {
    const declaration = validateUploadDeclaration(input, this.maxByteLength);
    assertApiKeyDevice(principal, declaration.deviceId);

    return this.translate(() =>
      executeIdempotentMutation(
        this.database,
        principal,
        "createMediaUpload",
        idempotencyKey,
        { input: declaration },
        async (queryable) => {
          await assertActiveOwnedDevice(queryable, principal.userId, declaration.deviceId);
          if (declaration.encryption !== undefined) {
            await assertEncryptionProfile(queryable, principal.userId);
          }

          const uploadId = randomUUID();
          const mediaId = declaration.mediaId ?? randomUUID();
          const storageKey = mediaUploadStorageKey(principal.userId, uploadId);
          const result = await queryable.query<MediaUploadRow>(
            `INSERT INTO media_upload_sessions (
               id, user_id, device_id, requested_media_id, status,
               file_name, content_type, byte_size, sha256,
               temporary_storage_key,
               cipher_algorithm, crypto_version, key_version, nonce,
               plaintext_content_type, expires_at
             ) VALUES (
               $1, $2, $3, $4, 'reserved',
               $5, $6, $7, decode($8, 'hex'),
               $9,
               $10, $11, $12, $13, $14,
               clock_timestamp() + ($15::bigint * interval '1 millisecond')
             )
             RETURNING ${UPLOAD_COLUMNS}`,
            [
              uploadId,
              principal.userId,
              declaration.deviceId,
              mediaId,
              declaration.fileName,
              declaration.contentType,
              declaration.byteLength,
              declaration.sha256,
              storageKey,
              declaration.encryption?.algorithm ?? null,
              declaration.encryption?.cryptoVersion ?? null,
              declaration.encryption?.keyVersion ?? null,
              declaration.encryption === undefined
                ? null
                : Buffer.from(declaration.encryption.nonce, "base64"),
              declaration.encryption?.plaintextContentType ?? null,
              this.uploadTtlMs,
            ],
          );
          const row = requiredRow(result.rows[0], "Created media upload could not be reloaded");
          await writeMediaAudit(
            queryable,
            principal,
            "media.upload.create",
            uploadId,
            requestId,
          );
          return {
            status: 201,
            headers: { location: `/v1/media-upload-sessions/${uploadId}` },
            body: mapMediaUploadRow(row),
          };
        },
      ),
    );
  }

  async getUpload(principal: Principal, uploadId: string): Promise<MediaUploadResource> {
    await this.expireUpload(principal.userId, uploadId);
    const row = await loadUpload(this.database, principal.userId, uploadId, false);
    if (row === undefined) {
      throw mediaUploadNotFound();
    }
    assertApiKeyDevice(principal, row.device_id);
    if (row.status === "expired" || row.status === "aborted") {
      await this.storage.delete(row.temporary_storage_key);
    }
    return mapMediaUploadRow(row);
  }

  async abortUpload(
    principal: Principal,
    uploadId: string,
    requestId: string,
  ): Promise<void> {
    await this.expireUpload(principal.userId, uploadId);
    const result = await this.database.transaction(async (queryable) => {
      const row = await loadUpload(queryable, principal.userId, uploadId, true);
      if (row === undefined) {
        throw mediaUploadNotFound();
      }
      assertApiKeyDevice(principal, row.device_id);
      if (row.status === "completed") {
        throw mediaConflict(
          "completed_upload",
          "A completed media upload cannot be aborted.",
        );
      }
      if (row.status === "reserved" || row.status === "received") {
        await queryable.query(
          `UPDATE media_upload_sessions
           SET status = 'aborted', aborted_at = clock_timestamp(), updated_at = clock_timestamp()
           WHERE user_id = $1 AND id = $2`,
          [principal.userId, uploadId],
        );
        await writeMediaAudit(
          queryable,
          principal,
          "media.upload.abort",
          uploadId,
          requestId,
        );
      }
      return row.temporary_storage_key;
    });
    // Deletion after commit is retry-safe: repeated abort calls return 204 and
    // retry the idempotent unlink if an earlier filesystem operation failed.
    await this.storage.delete(result);
  }

  async receiveUpload(
    principal: Principal,
    uploadId: string,
    source: AsyncIterable<Uint8Array | string>,
    declaredByteLength: number,
    declaredSha256: string,
    requestId: string,
  ): Promise<void> {
    await this.expireUpload(principal.userId, uploadId);
    const existing = await loadUpload(this.database, principal.userId, uploadId, false);
    if (existing === undefined) {
      throw mediaUploadNotFound();
    }
    assertApiKeyDevice(principal, existing.device_id);
    assertUploadAcceptsBytes(existing);
    if (declaredByteLength !== numeric(existing.byte_size)) {
      throw mediaConflict(
        "media_length_conflict",
        "Content-Length differs from the upload reservation.",
      );
    }
    const expectedSha256 = existing.sha256.toString("hex");
    if (declaredSha256 !== expectedSha256) {
      throw mediaConflict(
        "media_sha256_conflict",
        "X-Content-SHA256 differs from the upload reservation.",
      );
    }

    try {
      await this.storage.writeVerified(
        existing.temporary_storage_key,
        source,
        declaredByteLength,
        declaredSha256,
      );
    } catch (error) {
      translateStorageIntegrityError(error);
    }

    const outcome = await this.database.transaction(async (queryable) => {
      const current = await loadUpload(queryable, principal.userId, uploadId, true);
      if (current === undefined) {
        return "missing" as const;
      }
      assertApiKeyDevice(principal, current.device_id);
      if (current.status === "completed") {
        return "completed" as const;
      }
      if (current.status === "aborted" || current.status === "expired") {
        return "cleanup" as const;
      }
      if (new Date(current.expires_at).getTime() <= Date.now()) {
        await queryable.query(
          `UPDATE media_upload_sessions
           SET status = 'expired', aborted_at = clock_timestamp(), updated_at = clock_timestamp()
           WHERE user_id = $1 AND id = $2`,
          [principal.userId, uploadId],
        );
        return "cleanup" as const;
      }
      await queryable.query(
        `UPDATE media_upload_sessions
         SET status = 'received', received_bytes = byte_size, updated_at = clock_timestamp()
         WHERE user_id = $1 AND id = $2`,
        [principal.userId, uploadId],
      );
      await writeMediaAudit(
        queryable,
        principal,
        "media.upload.receive",
        uploadId,
        requestId,
      );
      return "received" as const;
    });

    if (outcome === "missing") {
      await this.storage.delete(existing.temporary_storage_key);
      throw mediaUploadNotFound();
    }
    if (outcome === "cleanup") {
      await this.storage.delete(existing.temporary_storage_key);
      throw mediaConflict("inactive_upload", "The upload is no longer active.");
    }
    // A verified retry may race completion. It rewrites identical immutable
    // bytes, so both "received" and "completed" are successful outcomes.
  }

  async completeUpload(
    principal: Principal,
    uploadId: string,
    idempotencyKey: string,
    requestId: string,
  ): Promise<MutationResponse<MediaObjectResource>> {
    await this.expireUpload(principal.userId, uploadId);
    return this.translate(() =>
      executeIdempotentMutation(
        this.database,
        principal,
        "completeMediaUpload",
        idempotencyKey,
        { uploadId },
        async (queryable) => {
          const upload = await loadUpload(queryable, principal.userId, uploadId, true);
          if (upload === undefined) {
            throw mediaUploadNotFound();
          }
          assertApiKeyDevice(principal, upload.device_id);
          if (upload.status === "aborted" || upload.status === "expired") {
            throw mediaConflict("inactive_upload", "The upload is no longer active.");
          }
          if (upload.status === "completed") {
            const completed = await loadOwnedMedia(
              queryable,
              principal.userId,
              requiredValue(upload.media_id, "Completed upload has no media ID"),
              { includeDeleted: true },
            );
            if (completed === undefined) {
              throw storageInconsistent();
            }
            if (completed.status === "deleted" || completed.deleted_at !== null) {
              throw mediaConflict(
                "completed_media_deleted",
                "The media object created by this upload has been deleted.",
              );
            }
            const resource = mapMediaRow(completed);
            return {
              status: 200,
              headers: { etag: mediaEtag(resource.id, resource.revision) },
              body: resource,
            };
          }
          if (upload.status !== "received") {
            throw mediaConflict(
              "upload_not_received",
              "Upload bytes must be received before completion.",
            );
          }

          const stored = await openStoredMedia(
            this.storage,
            upload.temporary_storage_key,
            numeric(upload.byte_size),
          );
          stored.stream.destroy();
          const mediaId = upload.requested_media_id;
          await queryable.query(
            `INSERT INTO media_objects (
               id, user_id, device_id, visibility, status,
               file_name, content_type, byte_size, sha256, storage_key,
               cipher_algorithm, crypto_version, key_version, nonce,
               plaintext_content_type, metadata
             ) VALUES (
               $1, $2, $3, $4, 'ready',
               $5, $6, $7, $8, $9,
               $10, $11, $12, $13, $14, '{}'::jsonb
             )`,
            [
              mediaId,
              principal.userId,
              upload.device_id,
              upload.cipher_algorithm === null ? "public" : "private",
              upload.file_name,
              upload.content_type,
              numeric(upload.byte_size),
              upload.sha256,
              upload.temporary_storage_key,
              upload.cipher_algorithm,
              upload.crypto_version,
              upload.key_version,
              upload.nonce,
              upload.plaintext_content_type,
            ],
          );
          await queryable.query(
            `UPDATE media_upload_sessions
             SET status = 'completed', media_id = $3, completed_at = clock_timestamp(),
                 updated_at = clock_timestamp()
             WHERE user_id = $1 AND id = $2`,
            [principal.userId, uploadId, mediaId],
          );
          await writeMediaAudit(
            queryable,
            principal,
            "media.upload.complete",
            mediaId,
            requestId,
          );
          const row = await loadOwnedMedia(queryable, principal.userId, mediaId);
          if (row === undefined) {
            throw new Error("Completed media object could not be reloaded");
          }
          const resource = mapMediaRow(row);
          return {
            status: 200,
            headers: { etag: mediaEtag(resource.id, resource.revision) },
            body: resource,
          };
        },
      ),
    );
  }

  async getOwner(userId: string, mediaId: string): Promise<MediaObjectResource> {
    const row = await loadOwnedMedia(this.database, userId, mediaId);
    if (row === undefined) {
      throw mediaNotFound();
    }
    return mapMediaRow(row);
  }

  async downloadOwner(userId: string, mediaId: string): Promise<MediaDownload> {
    const row = await loadOwnedMedia(this.database, userId, mediaId);
    if (row === undefined) {
      throw mediaNotFound();
    }
    return this.download(row);
  }

  async downloadPublic(mediaId: string): Promise<MediaDownload> {
    const result = await this.database.query<MediaRow>(
      `SELECT ${MEDIA_COLUMNS}
       FROM media_objects m
       WHERE m.id = $1
         AND m.visibility = 'public'
         AND m.status = 'ready'
         AND m.deleted_at IS NULL
         AND EXISTS (
           SELECT 1
           FROM record_media public_link
           JOIN records public_record
             ON public_record.user_id = public_link.user_id
            AND public_record.id = public_link.record_id
           WHERE public_link.user_id = m.user_id
             AND public_link.media_id = m.id
             AND public_record.visibility = 'public'
             AND public_record.deleted_at IS NULL
         )`,
      [mediaId],
    );
    const row = result.rows[0];
    if (row === undefined) {
      throw mediaNotFound();
    }
    return this.download(row);
  }

  async delete(
    principal: Principal,
    mediaId: string,
    ifMatch: string,
    idempotencyKey: string,
    requestId: string,
  ): Promise<MutationResponse<null>> {
    const response = await this.translate(() =>
      executeIdempotentMutation(
        this.database,
        principal,
        "deleteMedia",
        idempotencyKey,
        { mediaId, ifMatch },
        async (queryable) => {
          const current = await loadOwnedMedia(
            queryable,
            principal.userId,
            mediaId,
            { forUpdate: true },
          );
          if (current === undefined) {
            throw mediaNotFound();
          }
          requireMatchingEtag(ifMatch, mediaEtag(mediaId, numeric(current.revision)));
          const link = await queryable.query<LinkRow>(
            `SELECT EXISTS (
               SELECT 1 FROM record_media
               WHERE user_id = $1 AND media_id = $2
             ) AS linked`,
            [principal.userId, mediaId],
          );
          if (link.rows[0]?.linked === true) {
            throw mediaConflict(
              "media_still_attached",
              "Media cannot be deleted while a retained record still references it.",
            );
          }
          await queryable.query(
            `UPDATE media_objects
             SET status = 'deleted', deleted_at = clock_timestamp()
             WHERE user_id = $1 AND id = $2`,
            [principal.userId, mediaId],
          );
          await writeMediaAudit(
            queryable,
            principal,
            "media.delete",
            mediaId,
            requestId,
          );
          return { status: 204, headers: {}, body: null };
        },
      ),
    );

    const deleted = await loadOwnedMedia(
      this.database,
      principal.userId,
      mediaId,
      { includeDeleted: true },
    );
    if (deleted?.status === "deleted") {
      // The database tombstone and replayable response commit first. A failed
      // unlink is safe to retry with the same idempotency key.
      await this.storage.delete(deleted.storage_key);
    }
    return response;
  }

  private async download(row: MediaRow): Promise<MediaDownload> {
    const stored = await openStoredMedia(this.storage, row.storage_key, numeric(row.byte_size));
    return {
      stream: stored.stream,
      byteLength: stored.byteLength,
      contentType: row.content_type,
      sha256: row.sha256.toString("hex"),
      etag: mediaEtag(row.id, numeric(row.revision)),
    };
  }

  private async expireUpload(userId: string, uploadId: string): Promise<void> {
    const expired = await this.database.query<MediaUploadRow>(
      `UPDATE media_upload_sessions
       SET status = 'expired', aborted_at = clock_timestamp(), updated_at = clock_timestamp()
       WHERE user_id = $1 AND id = $2
         AND status IN ('reserved', 'received')
         AND expires_at <= clock_timestamp()
       RETURNING ${UPLOAD_COLUMNS}`,
      [userId, uploadId],
    );
    const row = expired.rows[0];
    if (row !== undefined) {
      await this.storage.delete(row.temporary_storage_key);
    }
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

export function mediaEtag(mediaId: string, revision: number): string {
  return `"media-${mediaId}-r${revision}"`;
}

export function mapMediaRow(row: MediaRow): MediaObjectResource {
  const encryption = encryptionFromRow(row);
  return {
    id: row.id,
    userId: row.user_id,
    deviceId: row.device_id,
    fileName: row.file_name,
    contentType: row.content_type,
    byteLength: numeric(row.byte_size),
    sha256: row.sha256.toString("hex"),
    ...(encryption === undefined ? {} : { encryption }),
    revision: numeric(row.revision),
    createdAt: isoDate(row.created_at),
    contentUrl: `/v1/media/${row.id}/content`,
    ...(row.visibility === "public"
      ? { publicContentUrl: `/v1/public/media/${row.id}/content` }
      : {}),
  };
}

export async function loadOwnedMedia(
  queryable: Queryable,
  userId: string,
  mediaId: string,
  options: { readonly includeDeleted?: boolean; readonly forUpdate?: boolean } = {},
): Promise<MediaRow | undefined> {
  const where = ["m.user_id = $1", "m.id = $2"];
  if (options.includeDeleted !== true) {
    where.push("m.status = 'ready'", "m.deleted_at IS NULL");
  }
  const result = await queryable.query<MediaRow>(
    `SELECT ${MEDIA_COLUMNS}
     FROM media_objects m
     WHERE ${where.join(" AND ")}
     ${options.forUpdate === true ? "FOR UPDATE OF m" : ""}`,
    [userId, mediaId],
  );
  return result.rows[0];
}

export async function loadMediaResourcesForSync(
  queryable: Queryable,
  userId: string,
  mediaIds: readonly string[],
): Promise<Map<string, MediaObjectResource>> {
  if (mediaIds.length === 0) {
    return new Map();
  }
  const result = await queryable.query<MediaRow>(
    `SELECT ${MEDIA_COLUMNS}
     FROM media_objects m
     WHERE m.user_id = $1
       AND m.id = ANY($2::uuid[])
       AND m.status = 'ready'
       AND m.deleted_at IS NULL`,
    [userId, mediaIds],
  );
  return new Map(result.rows.map((row) => [row.id, mapMediaRow(row)]));
}

function mapMediaUploadRow(row: MediaUploadRow): MediaUploadResource {
  const encryption = encryptionFromRow(row);
  return {
    id: row.id,
    userId: row.user_id,
    deviceId: row.device_id,
    status: row.status,
    fileName: row.file_name,
    contentType: row.content_type,
    byteLength: numeric(row.byte_size),
    receivedBytes: numeric(row.received_bytes),
    sha256: row.sha256.toString("hex"),
    ...(encryption === undefined ? {} : { encryption }),
    uploadUrl: `/v1/media-upload-sessions/${row.id}/content`,
    expiresAt: isoDate(row.expires_at),
    createdAt: isoDate(row.created_at),
    mediaId: row.media_id ?? row.requested_media_id,
  };
}

function encryptionFromRow(row: {
  readonly visibility?: "public" | "private";
  readonly cipher_algorithm: string | null;
  readonly crypto_version: number | null;
  readonly key_version: number | null;
  readonly nonce: Buffer | null;
  readonly plaintext_content_type: string | null;
}): MediaEncryptionInput | undefined {
  const encrypted = row.cipher_algorithm !== null;
  if (!encrypted) {
    if (
      row.visibility === "private" ||
      row.crypto_version !== null ||
      row.key_version !== null ||
      row.nonce !== null ||
      row.plaintext_content_type !== null
    ) {
      throw new Error("Media encryption columns are inconsistent");
    }
    return undefined;
  }
  if (
    row.cipher_algorithm !== "A256GCM" ||
    row.crypto_version !== 1 ||
    row.key_version !== 1 ||
    row.nonce === null ||
    row.nonce.byteLength !== 12 ||
    row.visibility === "public"
  ) {
    throw new Error("Media encryption columns are inconsistent");
  }
  return {
    algorithm: "A256GCM",
    cryptoVersion: 1,
    keyVersion: 1,
    nonce: row.nonce.toString("base64"),
    ...(row.plaintext_content_type === null
      ? {}
      : { plaintextContentType: row.plaintext_content_type }),
  };
}

function validateUploadDeclaration(
  input: CreateMediaUploadInput,
  maxByteLength: number,
): Required<Omit<CreateMediaUploadInput, "mediaId" | "encryption">> & {
  readonly mediaId?: string;
  readonly encryption?: MediaEncryptionInput;
} {
  if (!isUuid(input.deviceId)) {
    throw unprocessable("deviceId must be a UUID.", "invalid_device_id");
  }
  const fileName = input.fileName;
  if (
    typeof fileName !== "string" ||
    fileName !== fileName.trim() ||
    [...fileName].length < 1 ||
    [...fileName].length > 255 ||
    /[/\\]/.test(fileName)
  ) {
    throw unprocessable(
      "fileName must be 1 to 255 trimmed characters without path separators.",
      "invalid_file_name",
    );
  }
  const contentType = input.contentType;
  if (
    typeof contentType !== "string" ||
    contentType !== contentType.trim() ||
    contentType.length < 3 ||
    contentType.length > 255 ||
    !MEDIA_CONTENT_TYPE_PATTERN.test(contentType)
  ) {
    throw unprocessable(
      "contentType must be a concrete type/subtype media type without parameters.",
      "invalid_content_type",
    );
  }
  if (
    !Number.isSafeInteger(input.byteLength) ||
    input.byteLength < 1 ||
    input.byteLength > maxByteLength
  ) {
    throw new HttpProblem({
      status: 413,
      code: "media_too_large",
      title: "Payload Too Large",
      type: "urn:exeligmos:problem:media-too-large",
      detail: `byteLength must be between 1 and ${maxByteLength}.`,
    });
  }
  if (!/^[a-f0-9]{64}$/.test(input.sha256)) {
    throw unprocessable("sha256 must be lowercase hexadecimal SHA-256.", "invalid_sha256");
  }
  if (input.mediaId !== undefined && !isUuid(input.mediaId)) {
    throw unprocessable("mediaId must be a UUID.", "invalid_media_id");
  }

  let encryption: MediaEncryptionInput | undefined;
  if (input.encryption !== undefined) {
    if (input.mediaId === undefined) {
      throw unprocessable(
        "mediaId is required for encrypted media key derivation.",
        "media_id_required",
      );
    }
    if (!isCanonicalUuid(input.mediaId)) {
      throw unprocessable(
        "Encrypted mediaId must be a canonical lowercase UUID.",
        "invalid_media_id",
      );
    }
    const candidate = input.encryption;
    if (
      candidate.algorithm !== "A256GCM" ||
      candidate.cryptoVersion !== 1 ||
      candidate.keyVersion !== 1 ||
      !/^[A-Za-z0-9+/]{16}$/.test(candidate.nonce) ||
      Buffer.from(candidate.nonce, "base64").byteLength !== 12
    ) {
      throw unprocessable(
        "encryption must use the supported A256GCM v1 envelope and a 12-byte nonce.",
        "invalid_encryption",
      );
    }
    const plaintextContentType = candidate.plaintextContentType;
    if (
      plaintextContentType !== undefined &&
      (plaintextContentType !== plaintextContentType.trim() ||
        plaintextContentType.length < 3 ||
        plaintextContentType.length > 255 ||
        !MEDIA_CONTENT_TYPE_PATTERN.test(plaintextContentType))
    ) {
      throw unprocessable(
        "plaintextContentType must be a concrete type/subtype media type without parameters when present.",
        "invalid_encryption",
      );
    }
    encryption = {
      algorithm: "A256GCM",
      cryptoVersion: 1,
      keyVersion: 1,
      nonce: candidate.nonce,
      ...(plaintextContentType === undefined ? {} : { plaintextContentType }),
    };
  }
  return {
    deviceId: input.deviceId,
    fileName,
    contentType,
    byteLength: input.byteLength,
    sha256: input.sha256,
    ...(input.mediaId === undefined ? {} : { mediaId: input.mediaId.toLowerCase() }),
    ...(encryption === undefined ? {} : { encryption }),
  };
}

async function loadUpload(
  queryable: Queryable,
  userId: string,
  uploadId: string,
  forUpdate: boolean,
): Promise<MediaUploadRow | undefined> {
  const result = await queryable.query<MediaUploadRow>(
    `SELECT ${UPLOAD_COLUMNS}
     FROM media_upload_sessions
     WHERE user_id = $1 AND id = $2
     ${forUpdate ? "FOR UPDATE" : ""}`,
    [userId, uploadId],
  );
  return result.rows[0];
}

function assertUploadAcceptsBytes(row: MediaUploadRow): void {
  if (row.status !== "reserved" && row.status !== "received") {
    throw mediaConflict("inactive_upload", "The upload no longer accepts bytes.");
  }
}

async function assertEncryptionProfile(queryable: Queryable, userId: string): Promise<void> {
  const result = await queryable.query(
    `SELECT 1
     FROM user_encryption_profiles
     WHERE user_id = $1 AND crypto_version = 1 AND key_version = 1`,
    [userId],
  );
  if (result.rowCount === 0) {
    throw unprocessable(
      "Initialize encryption profile v1 before storing private media.",
      "encryption_profile_required",
    );
  }
}

async function writeMediaAudit(
  queryable: Queryable,
  principal: Principal,
  action: string,
  entityId: string,
  requestId: string,
): Promise<void> {
  await queryable.query(
    `INSERT INTO audit_log (
       user_id, actor_type, actor_id, action, entity_type, entity_id, request_id
     ) VALUES ($1, $2, $3, $4, 'media', $5, $6)`,
    [principal.userId, principal.kind, principal.actorId, action, entityId, requestId],
  );
}

async function openStoredMedia(
  storage: MediaStorage,
  storageKey: string,
  expectedByteLength: number,
): Promise<{ readonly stream: Readable; readonly byteLength: number }> {
  try {
    const stored = await storage.open(storageKey);
    if (stored.byteLength !== expectedByteLength) {
      stored.stream.destroy();
      throw storageInconsistent();
    }
    return stored;
  } catch (error) {
    if (error instanceof MediaStorageMissingError) {
      throw storageInconsistent();
    }
    throw error;
  }
}

function translateStorageIntegrityError(error: unknown): never {
  if (!(error instanceof MediaStorageIntegrityError)) {
    throw error;
  }
  if (error.kind === "byte_length" && Number(error.actual) > Number(error.expected)) {
    throw new HttpProblem({
      status: 413,
      code: "media_too_large",
      title: "Payload Too Large",
      type: "urn:exeligmos:problem:media-too-large",
      detail: "The uploaded byte stream exceeds the reserved byte length.",
    });
  }
  throw unprocessable(
    error.kind === "byte_length"
      ? "The uploaded byte stream length does not match Content-Length."
      : "The uploaded byte stream does not match X-Content-SHA256.",
    error.kind === "byte_length" ? "media_length_mismatch" : "media_sha256_mismatch",
  );
}

function mediaNotFound(): HttpProblem {
  return new HttpProblem({
    status: 404,
    code: "media_not_found",
    title: "Not Found",
    type: "urn:exeligmos:problem:media-not-found",
    detail: "The requested media does not exist.",
  });
}

function mediaUploadNotFound(): HttpProblem {
  return new HttpProblem({
    status: 404,
    code: "media_upload_not_found",
    title: "Not Found",
    type: "urn:exeligmos:problem:media-upload-not-found",
    detail: "The requested media upload does not exist.",
  });
}

function mediaConflict(code: string, detail: string): HttpProblem {
  return new HttpProblem({
    status: 409,
    code,
    title: "Conflict",
    type: `urn:exeligmos:problem:${code.replaceAll("_", "-")}`,
    detail,
  });
}

function storageInconsistent(): HttpProblem {
  return new HttpProblem({
    status: 500,
    code: "media_storage_inconsistent",
    title: "Internal Server Error",
    type: "urn:exeligmos:problem:media-storage-inconsistent",
    detail: "The media metadata and stored byte stream are inconsistent.",
  });
}

function numeric(value: string | number): number {
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < 0) {
    throw new Error("Database returned an invalid media integer");
  }
  return parsed;
}

function requiredRow<Row>(row: Row | undefined, message: string): Row {
  if (row === undefined) {
    throw new Error(message);
  }
  return row;
}

function requiredValue<Value>(value: Value | null, message: string): Value {
  if (value === null) {
    throw new Error(message);
  }
  return value;
}

function isUuid(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(
    value,
  );
}

function isCanonicalUuid(value: string): boolean {
  return value === value.toLowerCase() && isUuid(value);
}
