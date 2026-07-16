import assert from "node:assert/strict";
import { createHash, randomUUID } from "node:crypto";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";

import Fastify, { type FastifyRequest } from "fastify";
import { Client } from "pg";

import type { Principal } from "../../src/auth/principal.js";
import { createPostgresDatabase } from "../../src/db/database.js";
import { runMigrations } from "../../src/db/migrate.js";
import { HttpProblem, registerProblemHandlers } from "../../src/http/problem.js";
import { LocalMediaStorage } from "../../src/media/storage.js";
import { registerMediaRoutes } from "../../src/routes/media.js";
import { NOOP_RESOURCE_REQUEST_LIMITER } from "../../src/resources/rate-limit.js";
import { testConfig } from "../helpers.js";

const databaseUrl = process.env.TEST_DATABASE_URL?.trim();

test(
  "media HTTP lifecycle verifies streamed bytes, tenancy, privacy, retries, and attachments",
  { skip: databaseUrl === undefined || databaseUrl.length === 0 },
  async () => {
    assert.ok(databaseUrl);
    await runMigrations({
      databaseUrl,
      directory: path.resolve(process.cwd(), "db/migrations"),
    });
    const base = testConfig();
    const database = createPostgresDatabase({ ...base.database, url: databaseUrl });
    const sql = new Client({ connectionString: databaseUrl });
    const storageRoot = await mkdtemp(path.join(tmpdir(), "exeligmos-media-http-"));
    await sql.connect();

    const ownerUserId = randomUUID();
    const otherUserId = randomUUID();
    const ownerDeviceId = randomUUID();
    const otherOwnerDeviceId = randomUUID();
    const otherUserDeviceId = randomUUID();
    await sql.query(
      `INSERT INTO users (id, login, display_name, password_hash)
       VALUES ($1, $2, 'Media owner', 'not-used'), ($3, $4, 'Other owner', 'not-used')`,
      [
        ownerUserId,
        `media-${randomUUID()}`,
        otherUserId,
        `media-other-${randomUUID()}`,
      ],
    );
    await sql.query(
      `INSERT INTO devices (id, user_id, name, kind)
       VALUES
         ($1, $2, 'Owner device', 'agent'),
         ($3, $2, 'Wrong owner device', 'agent'),
         ($4, $5, 'Other tenant device', 'agent')`,
      [ownerDeviceId, ownerUserId, otherOwnerDeviceId, otherUserDeviceId, otherUserId],
    );
    await sql.query(
      `INSERT INTO user_encryption_profiles (user_id, key_check)
       VALUES ($1, $2)`,
      [ownerUserId, Buffer.alloc(32, 4)],
    );

    const owner: Principal = {
      kind: "jwt",
      userId: ownerUserId,
      actorId: randomUUID(),
      deviceId: ownerDeviceId,
      scopes: new Set(),
    };
    const other: Principal = {
      kind: "jwt",
      userId: otherUserId,
      actorId: randomUUID(),
      deviceId: otherUserDeviceId,
      scopes: new Set(),
    };
    const wrongDeviceKey: Principal = {
      kind: "api_key",
      userId: ownerUserId,
      actorId: randomUUID(),
      deviceId: otherOwnerDeviceId,
      scopes: new Set(["media:read", "media:write"]),
    };
    const principals = new Map([
      ["owner", owner],
      ["other", other],
      ["wrong-device", wrongDeviceKey],
    ]);

    const app = Fastify({ bodyLimit: 128 * 1024 });
    registerProblemHandlers(app);
    await app.register(registerMediaRoutes, {
      database,
      storage: new LocalMediaStorage(storageRoot),
      authenticator: {
        async authenticate(request: FastifyRequest): Promise<Principal> {
          const token = request.headers.authorization?.replace(/^Bearer /, "");
          const principal = token === undefined ? undefined : principals.get(token);
          if (principal === undefined) {
            throw new HttpProblem({ status: 401, code: "unauthorized" });
          }
          return principal;
        },
      },
      requestLimiter: NOOP_RESOURCE_REQUEST_LIMITER,
      maxByteLength: 2 * 1024 * 1024,
      uploadTtlMs: 60_000,
    });
    await app.ready();

    try {
      const invalidContentType = await app.inject({
        method: "POST",
        url: "/v1/media-upload-sessions",
        headers: {
          authorization: "Bearer owner",
          "idempotency-key": `media-invalid-content-type-${randomUUID()}`,
        },
        payload: {
          deviceId: ownerDeviceId,
          fileName: "unsafe.bin",
          contentType: "text/html\r\nx-injected: yes",
          byteLength: 1,
          sha256: "0".repeat(64),
        },
      });
      assert.equal(invalidContentType.statusCode, 400, invalidContentType.body);

      // The 1.25 MiB body exceeds Fastify's JSON body limit but is consumed by
      // the bounded streaming parser without buffering it in application memory.
      const bytes = Buffer.alloc(1_310_720, 0x5a);
      const digest = sha256(bytes);
      const createKey = `media-create-${randomUUID()}`;
      const reservationRequest = {
        method: "POST" as const,
        url: "/v1/media-upload-sessions",
        headers: {
          authorization: "Bearer owner",
          "idempotency-key": createKey,
        },
        payload: {
          deviceId: ownerDeviceId,
          fileName: "solar-observation.bin",
          contentType: "application/octet-stream",
          byteLength: bytes.byteLength,
          sha256: digest,
        },
      };
      const reservation = await app.inject(reservationRequest);
      const reservationReplay = await app.inject(reservationRequest);
      assert.equal(reservation.statusCode, 201, reservation.body);
      assert.equal(reservationReplay.statusCode, 201, reservationReplay.body);
      assert.deepEqual(reservationReplay.json(), reservation.json());
      const upload = reservation.json<UploadBody>();
      assert.match(upload.mediaId, /^[a-f0-9-]{36}$/);
      assert.equal(upload.status, "reserved");

      const wrongDevice = await app.inject({
        method: "GET",
        url: `/v1/media-upload-sessions/${upload.id}`,
        headers: { authorization: "Bearer wrong-device" },
      });
      assert.equal(wrongDevice.statusCode, 403, wrongDevice.body);

      const declarationConflict = await app.inject({
        method: "PUT",
        url: upload.uploadUrl,
        headers: {
          authorization: "Bearer owner",
          "content-type": "application/octet-stream",
          "content-length": String(bytes.byteLength),
          "x-content-sha256": "0".repeat(64),
        },
        payload: bytes,
      });
      assert.equal(declarationConflict.statusCode, 409, declarationConflict.body);

      const receiveRequest = {
        method: "PUT" as const,
        url: upload.uploadUrl,
        headers: {
          authorization: "Bearer owner",
          "content-type": "application/octet-stream",
          "content-length": String(bytes.byteLength),
          "x-content-sha256": digest,
        },
        payload: bytes,
      };
      const received = await app.inject(receiveRequest);
      const receivedReplay = await app.inject(receiveRequest);
      assert.equal(received.statusCode, 204, received.body);
      assert.equal(receivedReplay.statusCode, 204, receivedReplay.body);

      const uploadStatus = await app.inject({
        method: "GET",
        url: `/v1/media-upload-sessions/${upload.id}`,
        headers: { authorization: "Bearer owner" },
      });
      assert.equal(uploadStatus.statusCode, 200, uploadStatus.body);
      assert.equal(uploadStatus.json().status, "received");
      assert.equal(uploadStatus.json().receivedBytes, bytes.byteLength);

      const completionRequest = {
        method: "POST" as const,
        url: `/v1/media-upload-sessions/${upload.id}/complete`,
        headers: {
          authorization: "Bearer owner",
          "idempotency-key": `media-complete-${randomUUID()}`,
        },
      };
      const completed = await app.inject(completionRequest);
      const completedReplay = await app.inject(completionRequest);
      assert.equal(completed.statusCode, 200, completed.body);
      assert.equal(completedReplay.statusCode, 200, completedReplay.body);
      assert.deepEqual(completedReplay.json(), completed.json());
      const media = completed.json<MediaBody>();
      assert.equal(media.id, upload.mediaId);
      assert.equal(media.publicContentUrl, `/v1/public/media/${media.id}/content`);
      const mediaEtag = requiredHeader(completed.headers.etag);

      const otherTenantMetadata = await app.inject({
        method: "GET",
        url: `/v1/media/${media.id}`,
        headers: { authorization: "Bearer other" },
      });
      assert.equal(otherTenantMetadata.statusCode, 404, otherTenantMetadata.body);
      const ownerDownload = await app.inject({
        method: "GET",
        url: media.contentUrl,
        headers: { authorization: "Bearer owner" },
      });
      assert.equal(ownerDownload.statusCode, 200, ownerDownload.body);
      assert.deepEqual(ownerDownload.rawPayload, bytes);
      assert.equal(ownerDownload.headers["x-content-sha256"], digest);
      assert.equal(
        ownerDownload.headers["content-security-policy"],
        "sandbox; default-src 'none'",
      );

      // Reusing a completed media ID must never overwrite the immutable bytes
      // before the duplicate ID is rejected at completion.
      const conflictingBytes = Buffer.alloc(bytes.byteLength, 0x59);
      const conflictingDigest = sha256(conflictingBytes);
      const conflictingReservation = await app.inject({
        method: "POST",
        url: "/v1/media-upload-sessions",
        headers: {
          authorization: "Bearer owner",
          "idempotency-key": `media-conflict-create-${randomUUID()}`,
        },
        payload: {
          mediaId: media.id,
          deviceId: ownerDeviceId,
          fileName: "conflicting.bin",
          contentType: "application/octet-stream",
          byteLength: conflictingBytes.byteLength,
          sha256: conflictingDigest,
        },
      });
      assert.equal(conflictingReservation.statusCode, 201, conflictingReservation.body);
      const conflictingUpload = conflictingReservation.json<UploadBody>();
      assert.equal((await app.inject({
        method: "PUT",
        url: conflictingUpload.uploadUrl,
        headers: {
          authorization: "Bearer owner",
          "content-type": "application/octet-stream",
          "content-length": String(conflictingBytes.byteLength),
          "x-content-sha256": conflictingDigest,
        },
        payload: conflictingBytes,
      })).statusCode, 204);
      const conflictingCompletion = await app.inject({
        method: "POST",
        url: `/v1/media-upload-sessions/${conflictingUpload.id}/complete`,
        headers: {
          authorization: "Bearer owner",
          "idempotency-key": `media-conflict-complete-${randomUUID()}`,
        },
      });
      assert.equal(conflictingCompletion.statusCode, 409, conflictingCompletion.body);
      const retainedDownload = await app.inject({
        method: "GET",
        url: media.contentUrl,
        headers: { authorization: "Bearer owner" },
      });
      assert.deepEqual(retainedDownload.rawPayload, bytes);
      assert.equal((await app.inject({
        method: "DELETE",
        url: `/v1/media-upload-sessions/${conflictingUpload.id}`,
        headers: { authorization: "Bearer owner" },
      })).statusCode, 204);

      const hiddenUnattached = await app.inject({
        method: "GET",
        url: `/v1/public/media/${media.id}/content`,
      });
      assert.equal(hiddenUnattached.statusCode, 404, hiddenUnattached.body);

      const recordId = randomUUID();
      await sql.query(
        `INSERT INTO records (
           id, user_id, device_id, visibility, event_at, public_payload
         ) VALUES ($1, $2, $3, 'public', clock_timestamp(), '{"text":"public"}'::jsonb)`,
        [recordId, ownerUserId, ownerDeviceId],
      );
      await sql.query(
        `INSERT INTO record_media (user_id, record_id, media_id, position)
         VALUES ($1, $2, $3, 0)`,
        [ownerUserId, recordId, media.id],
      );

      const publicDownload = await app.inject({
        method: "GET",
        url: `/v1/public/media/${media.id}/content`,
      });
      assert.equal(publicDownload.statusCode, 200, publicDownload.body);
      assert.deepEqual(publicDownload.rawPayload, bytes);
      assert.equal(
        publicDownload.headers["cache-control"],
        "public, max-age=31536000, immutable",
      );
      assert.equal(
        publicDownload.headers["content-security-policy"],
        "sandbox; default-src 'none'",
      );

      const attachedDelete = await app.inject({
        method: "DELETE",
        url: `/v1/media/${media.id}`,
        headers: {
          authorization: "Bearer owner",
          "if-match": mediaEtag,
          "idempotency-key": `media-delete-attached-${randomUUID()}`,
        },
      });
      assert.equal(attachedDelete.statusCode, 409, attachedDelete.body);

      // A soft-deleted record is still retained and still blocks media deletion.
      await sql.query("UPDATE records SET deleted_at = clock_timestamp() WHERE id = $1", [recordId]);
      const retainedDelete = await app.inject({
        method: "DELETE",
        url: `/v1/media/${media.id}`,
        headers: {
          authorization: "Bearer owner",
          "if-match": mediaEtag,
          "idempotency-key": `media-delete-retained-${randomUUID()}`,
        },
      });
      assert.equal(retainedDelete.statusCode, 409, retainedDelete.body);

      await sql.query("DELETE FROM record_media WHERE record_id = $1", [recordId]);
      const deleteKey = `media-delete-${randomUUID()}`;
      const deleteRequest = {
        method: "DELETE" as const,
        url: `/v1/media/${media.id}`,
        headers: {
          authorization: "Bearer owner",
          "if-match": mediaEtag,
          "idempotency-key": deleteKey,
        },
      };
      const deleted = await app.inject(deleteRequest);
      const deletedReplay = await app.inject(deleteRequest);
      assert.equal(deleted.statusCode, 204, deleted.body);
      assert.equal(deletedReplay.statusCode, 204, deletedReplay.body);
      const recompleteDeleted = await app.inject({
        method: "POST",
        url: `/v1/media-upload-sessions/${upload.id}/complete`,
        headers: {
          authorization: "Bearer owner",
          "idempotency-key": `media-recomplete-deleted-${randomUUID()}`,
        },
      });
      assert.equal(recompleteDeleted.statusCode, 409, recompleteDeleted.body);
      assert.equal(recompleteDeleted.json().code, "completed_media_deleted");
      const deletedDownload = await app.inject({
        method: "GET",
        url: media.contentUrl,
        headers: { authorization: "Bearer owner" },
      });
      assert.equal(deletedDownload.statusCode, 404, deletedDownload.body);

      await verifyPrivateAndAbortFlows(app, ownerDeviceId);
    } finally {
      await app.close();
      await database.close();
      await sql.query("DELETE FROM users WHERE id = ANY($1::uuid[])", [
        [ownerUserId, otherUserId],
      ]).catch(() => undefined);
      await sql.end();
      await rm(storageRoot, { recursive: true, force: true });
    }
  },
);

async function verifyPrivateAndAbortFlows(
  app: ReturnType<typeof Fastify>,
  deviceId: string,
): Promise<void> {
  const privateBytes = Buffer.from("opaque ciphertext plus tag");
  const privateMediaId = randomUUID();
  const reservation = await app.inject({
    method: "POST",
    url: "/v1/media-upload-sessions",
    headers: {
      authorization: "Bearer owner",
      "idempotency-key": `private-create-${randomUUID()}`,
    },
    payload: {
      mediaId: privateMediaId,
      deviceId,
      fileName: "private.bin",
      contentType: "application/octet-stream",
      byteLength: privateBytes.byteLength,
      sha256: sha256(privateBytes),
      encryption: {
        algorithm: "A256GCM",
        cryptoVersion: 1,
        keyVersion: 1,
        nonce: Buffer.alloc(12, 2).toString("base64"),
      },
    },
  });
  assert.equal(reservation.statusCode, 201, reservation.body);
  const upload = reservation.json() as UploadBody;
  assert.equal(upload.mediaId, privateMediaId);
  const receive = await app.inject({
    method: "PUT",
    url: upload.uploadUrl,
    headers: {
      authorization: "Bearer owner",
      "content-type": "application/octet-stream",
      "content-length": String(privateBytes.byteLength),
      "x-content-sha256": sha256(privateBytes),
    },
    payload: privateBytes,
  });
  assert.equal(receive.statusCode, 204, receive.body);
  const completed = await app.inject({
    method: "POST",
    url: `/v1/media-upload-sessions/${upload.id}/complete`,
    headers: {
      authorization: "Bearer owner",
      "idempotency-key": `private-complete-${randomUUID()}`,
    },
  });
  assert.equal(completed.statusCode, 200, completed.body);
  assert.equal(completed.json().encryption.algorithm, "A256GCM");
  const hidden = await app.inject({
    method: "GET",
    url: `/v1/public/media/${privateMediaId}/content`,
  });
  assert.equal(hidden.statusCode, 404, hidden.body);

  const abortedBytes = Buffer.from("temporary");
  const abortedReservation = await app.inject({
    method: "POST",
    url: "/v1/media-upload-sessions",
    headers: {
      authorization: "Bearer owner",
      "idempotency-key": `abort-create-${randomUUID()}`,
    },
    payload: {
      deviceId,
      fileName: "abort.bin",
      contentType: "application/octet-stream",
      byteLength: abortedBytes.byteLength,
      sha256: sha256(abortedBytes),
    },
  });
  assert.equal(abortedReservation.statusCode, 201, abortedReservation.body);
  const abortedUpload = abortedReservation.json() as UploadBody;
  const abortRequest = {
    method: "DELETE" as const,
    url: `/v1/media-upload-sessions/${abortedUpload.id}`,
    headers: { authorization: "Bearer owner" },
  };
  assert.equal((await app.inject(abortRequest)).statusCode, 204);
  assert.equal((await app.inject(abortRequest)).statusCode, 204);
  const completeAborted = await app.inject({
    method: "POST",
    url: `/v1/media-upload-sessions/${abortedUpload.id}/complete`,
    headers: {
      authorization: "Bearer owner",
      "idempotency-key": `abort-complete-${randomUUID()}`,
    },
  });
  assert.equal(completeAborted.statusCode, 409, completeAborted.body);
}

interface UploadBody {
  readonly id: string;
  readonly mediaId: string;
  readonly status: string;
  readonly uploadUrl: string;
}

interface MediaBody {
  readonly id: string;
  readonly contentUrl: string;
  readonly publicContentUrl?: string;
}

function sha256(value: Buffer): string {
  return createHash("sha256").update(value).digest("hex");
}

function requiredHeader(value: string | string[] | undefined): string {
  if (typeof value !== "string") {
    throw new Error("Expected a scalar response header");
  }
  return value;
}
