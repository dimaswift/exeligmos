import assert from "node:assert/strict";
import path from "node:path";
import test from "node:test";
import { randomUUID } from "node:crypto";
import { Client, type DatabaseError } from "pg";

import { runMigrations } from "../../src/db/migrate.js";

const databaseUrl = process.env.TEST_DATABASE_URL?.trim();

test(
  "initial migration enforces pgvector, privacy, revisions, changes, and lightweight events",
  { skip: databaseUrl === undefined || databaseUrl.length === 0 },
  async () => {
    assert.ok(databaseUrl);
    const migrationDirectory = path.resolve(process.cwd(), "db/migrations");
    await runMigrations({ databaseUrl, directory: migrationDirectory });
    assert.deepEqual(
      await runMigrations({ databaseUrl, directory: migrationDirectory }),
      [],
      "the migration should already be applied and remain idempotent",
    );

    const client = new Client({ connectionString: databaseUrl });
    await client.connect();

    const login = `integration-${randomUUID()}`;
    let userId: string | undefined;
    try {
      const extension = await client.query<{ extversion: string }>(
        "SELECT extversion FROM pg_extension WHERE extname = 'vector'",
      );
      assert.match(extension.rows[0]?.extversion ?? "", /^0\.8\./);

      const compactJsonLengths = await client.query<{
        compact_object: string;
        expanded_number: string;
      }>(
        `SELECT
           exeligmos_jsonb_compact_octet_length('{"a":1,"b":[2,3]}'::jsonb)::text
             AS compact_object,
           exeligmos_jsonb_compact_octet_length('{"n":1e21}'::jsonb)::text
             AS expanded_number`,
      );
      assert.deepEqual(compactJsonLengths.rows[0], {
        compact_object: "17",
        expanded_number: "28",
      });

      const recordContentConstraint = await client.query<{
        conname: string;
        convalidated: boolean;
      }>(
        `SELECT conname, convalidated
         FROM pg_constraint
         WHERE conrelid = 'records'::regclass
           AND conname IN ('records_check2', 'records_visibility_content_check')`,
      );
      assert.deepEqual(recordContentConstraint.rows, [
        { conname: "records_visibility_content_check", convalidated: true },
      ]);

      const user = await client.query<{ id: string }>(
        `INSERT INTO users (login, display_name, password_hash)
         VALUES ($1, 'Integration Test', 'not-a-real-password-hash')
         RETURNING id`,
        [login],
      );
      userId = user.rows[0]?.id;
      assert.ok(userId);

      const encryptionProfile = await client.query<{
        crypto_version: number;
        key_version: number;
        key_check_length: number;
      }>(
        `INSERT INTO user_encryption_profiles (user_id, crypto_version, key_version, key_check)
         VALUES ($1, 1, 1, $2)
         RETURNING crypto_version, key_version, octet_length(key_check) AS key_check_length`,
        [userId, Buffer.alloc(32, 1)],
      );
      assert.deepEqual(encryptionProfile.rows[0], {
        crypto_version: 1,
        key_version: 1,
        key_check_length: 32,
      });
      await assert.rejects(
        client.query(
          "UPDATE user_encryption_profiles SET key_check = $2 WHERE user_id = $1",
          [userId, Buffer.alloc(32, 9)],
        ),
        isConstraintViolation,
      );
      const passwordSession = await client.query<{ device_id: string | null }>(
        `INSERT INTO auth_sessions (user_id, refresh_token_hash, expires_at)
         VALUES ($1, $2, now() + interval '1 day')
         RETURNING device_id`,
        [userId, Buffer.alloc(32, 2)],
      );
      assert.equal(passwordSession.rows[0]?.device_id, null);

      await client.query("UPDATE users SET display_name = 'Integration Test Updated' WHERE id = $1", [
        userId,
      ]);
      const userChanges = await client.query<{ operation: string; revision: string }>(
        `SELECT operation, revision
         FROM change_log
         WHERE user_id = $1 AND entity_type = 'user' AND entity_id = $1
         ORDER BY revision`,
        [userId],
      );
      assert.deepEqual(userChanges.rows, [
        { operation: "upsert", revision: "1" },
        { operation: "upsert", revision: "2" },
      ]);

      const device = await client.query<{ id: string }>(
        `INSERT INTO devices (user_id, name, kind)
         VALUES ($1, 'Integration Agent', 'agent')
         RETURNING id`,
        [userId],
      );
      const deviceId = device.rows[0]?.id;
      assert.ok(deviceId);

      const contractDeviceKinds = ["ios", "macos", "web", "agent", "server", "other"];
      for (const kind of contractDeviceKinds.filter((value) => value !== "agent")) {
        await client.query(
          `INSERT INTO devices (user_id, name, kind)
           VALUES ($1, $2, $3)`,
          [userId, `Integration ${kind}`, kind],
        );
      }
      const storedDeviceKinds = await client.query<{ kind: string }>(
        "SELECT kind FROM devices WHERE user_id = $1 ORDER BY kind",
        [userId],
      );
      assert.deepEqual(
        storedDeviceKinds.rows.map((row) => row.kind),
        [...contractDeviceKinds].sort(),
      );
      const alternateDevice = await client.query<{ id: string }>(
        "SELECT id FROM devices WHERE user_id = $1 AND kind = 'server'",
        [userId],
      );
      const alternateDeviceId = alternateDevice.rows[0]?.id;
      assert.ok(alternateDeviceId);

      const apiKey = await client.query<{ key_prefix: string; scopes: string[] }>(
        `INSERT INTO api_keys (
           user_id, device_id, name, key_prefix, key_hash, scopes
         ) VALUES ($1, $2, 'Integration API key', 'exk_AbC12345', $3, $4::text[])
         RETURNING key_prefix, scopes`,
        [userId, deviceId, Buffer.alloc(32, 3), ["records:read", "events:write", "sync:read"]],
      );
      assert.equal(apiKey.rows[0]?.key_prefix, "exk_AbC12345");
      assert.deepEqual(apiKey.rows[0]?.scopes, ["records:read", "events:write", "sync:read"]);
      await assert.rejects(
        client.query(
          `INSERT INTO api_keys (
             user_id, device_id, name, key_prefix, key_hash, scopes
           ) VALUES ($1, $2, 'Invalid scope', 'exk_BadScope', $3, $4::text[])`,
          [userId, deviceId, Buffer.alloc(32, 4), ["records:read", "users:write"]],
        ),
        isConstraintViolation,
      );
      await assert.rejects(
        client.query(
          `INSERT INTO api_keys (
             user_id, device_id, name, key_prefix, key_hash, scopes
           ) VALUES ($1, $2, 'Duplicate scope', 'exk_Duplicate', $3, $4::text[])`,
          [userId, deviceId, Buffer.alloc(32, 10), ["records:read", "records:read"]],
        ),
        isConstraintViolation,
      );

      const publicRecord = await client.query<{ id: string; revision: string }>(
        `INSERT INTO records (
           user_id, device_id, event_at, public_payload, metadata
         ) VALUES ($1, $2, now(), $3::jsonb, $4::jsonb)
         RETURNING id, revision`,
        [userId, deviceId, JSON.stringify({ text: "public" }), JSON.stringify({ test: true })],
      );
      const publicRecordId = publicRecord.rows[0]?.id;
      assert.ok(publicRecordId);
      assert.equal(Number(publicRecord.rows[0]?.revision), 1);

      const privateRecord = await client.query<{ id: string }>(
        `INSERT INTO records (
           user_id, device_id, visibility, cipher_algorithm, crypto_version,
           key_version, nonce, ciphertext, encrypted_content_type
         ) VALUES ($1, $2, 'private', 'A256GCM', 1, 1, $3, $4,
           'application/vnd.exeligmos.record+json')
         RETURNING id`,
        [userId, deviceId, Buffer.alloc(12, 1), Buffer.alloc(16, 2)],
      );
      const privateRecordId = privateRecord.rows[0]?.id;
      assert.ok(privateRecordId);

      await assert.rejects(
        client.query("UPDATE records SET device_id = $2 WHERE id = $1", [
          privateRecordId,
          alternateDeviceId,
        ]),
        isConstraintViolation,
      );
      const refreshedPrivateRecord = await client.query<{ revision: string }>(
        `UPDATE records
         SET device_id = $2, nonce = $3, ciphertext = $4
         WHERE id = $1
         RETURNING revision`,
        [privateRecordId, alternateDeviceId, Buffer.alloc(12, 5), Buffer.alloc(17, 6)],
      );
      assert.equal(Number(refreshedPrivateRecord.rows[0]?.revision), 2);

      await assert.rejects(
        client.query(
          `INSERT INTO records (
             user_id, device_id, visibility, cipher_algorithm, crypto_version,
             key_version, nonce, encrypted_content_type
           ) VALUES ($1, $2, 'private', 'A256GCM', 1, 1, $3,
             'application/vnd.exeligmos.record+json')`,
          [userId, deviceId, Buffer.alloc(12, 1)],
        ),
        isConstraintViolation,
      );

      await assert.rejects(
        client.query(
          `INSERT INTO records (
             user_id, device_id, visibility, cipher_algorithm, key_version,
             nonce, ciphertext, encrypted_content_type
           ) VALUES ($1, $2, 'private', 'A256GCM', 1, $3, $4,
             'application/vnd.exeligmos.record+json')`,
          [userId, deviceId, Buffer.alloc(12, 1), Buffer.alloc(16, 2)],
        ),
        isRecordContentConstraintViolation,
      );

      await assert.rejects(
        client.query(
          `INSERT INTO records (
             user_id, device_id, visibility, event_at, cipher_algorithm,
             crypto_version, key_version, nonce, ciphertext, encrypted_content_type
           ) VALUES ($1, $2, 'private', now(), 'A256GCM', 1, 1, $3, $4,
             'application/vnd.exeligmos.record+json')`,
          [userId, deviceId, Buffer.alloc(12, 1), Buffer.alloc(16, 2)],
        ),
        isConstraintViolation,
      );

      await assert.rejects(
        client.query("UPDATE records SET visibility = 'private' WHERE id = $1", [publicRecordId]),
        isConstraintViolation,
      );
      await assert.rejects(
        client.query("UPDATE records SET visibility = 'public' WHERE id = $1", [privateRecordId]),
        isConstraintViolation,
      );
      await assert.rejects(
        client.query("UPDATE records SET ciphertext = $2 WHERE id = $1", [
          privateRecordId,
          Buffer.alloc(16, 10),
        ]),
        isConstraintViolation,
      );
      const secondPrivateRevision = await client.query<{ revision: string }>(
        `UPDATE records
         SET nonce = $2, ciphertext = $3
         WHERE id = $1
         RETURNING revision`,
        [privateRecordId, Buffer.alloc(12, 11), Buffer.alloc(16, 12)],
      );
      assert.equal(Number(secondPrivateRevision.rows[0]?.revision), 3);

      const tag = await client.query<{
        id: string;
        color: string;
        sort_order: number;
      }>(
        `INSERT INTO tags (user_id, name, color, sort_order)
         VALUES ($1, 'Test', '#123456AB', 37)
         RETURNING id, color, sort_order`,
        [userId],
      );
      const tagId = tag.rows[0]?.id;
      assert.ok(tagId);
      assert.equal(tag.rows[0]?.color, "#123456AB");
      assert.equal(tag.rows[0]?.sort_order, 37);
      await assert.rejects(
        client.query(
          "INSERT INTO tags (user_id, name, metadata) VALUES ($1, 'Oversized', $2::jsonb)",
          [userId, JSON.stringify({ value: "x".repeat(32_768) })],
        ),
        isConstraintViolation,
      );
      await assert.rejects(
        client.query(
          `INSERT INTO templates (user_id, name, body, variable_schema)
           VALUES ($1, 'Oversized', $2::jsonb, '{"type":"object"}'::jsonb)`,
          [userId, JSON.stringify({ value: "x".repeat(262_144) })],
        ),
        isConstraintViolation,
      );

      await client.query(
        "INSERT INTO record_tags (user_id, record_id, tag_id) VALUES ($1, $2, $3)",
        [userId, publicRecordId, tagId],
      );
      await assert.rejects(
        client.query(
          "INSERT INTO record_tags (user_id, record_id, tag_id) VALUES ($1, $2, $3)",
          [userId, privateRecordId, tagId],
        ),
        isConstraintViolation,
      );

      await client.query(
        `INSERT INTO record_embeddings (
           user_id, record_id, record_revision, model_key, dimensions,
           content_hash, embedding
         ) VALUES ($1, $2, 1, 'integration-3d', 3, $3, $4::vector)`,
        [userId, publicRecordId, Buffer.alloc(32, 3), "[1,0,0]"],
      );
      await assert.rejects(
        client.query(
          `INSERT INTO record_embeddings (
             user_id, record_id, record_revision, model_key, dimensions,
             content_hash, embedding
           ) VALUES ($1, $2, 1, 'integration-3d', 3, $3, $4::vector)`,
          [userId, privateRecordId, Buffer.alloc(32, 3), "[1,0,0]"],
        ),
        isConstraintViolation,
      );

      const distance = await client.query<{ distance: number }>(
        `SELECT embedding <=> '[1,0,0]'::vector AS distance
         FROM record_embeddings
         WHERE record_id = $1`,
        [publicRecordId],
      );
      assert.equal(Number(distance.rows[0]?.distance), 0);

      const publicMedia = await client.query<{ id: string }>(
        `INSERT INTO media_objects (
           user_id, device_id, file_name, content_type, byte_size,
           sha256, storage_key
         ) VALUES ($1, $2, 'public.jpg', 'image/jpeg', 128, $3, 'integration/public.jpg')
         RETURNING id`,
        [userId, deviceId, Buffer.alloc(32, 5)],
      );
      const publicMediaId = publicMedia.rows[0]?.id;
      assert.ok(publicMediaId);
      await assert.rejects(
        client.query(
          `INSERT INTO media_objects (
             user_id, device_id, file_name, content_type, byte_size, sha256, storage_key
           ) VALUES ($1, $2, 'unsafe.bin', $3, 1, $4, 'integration/unsafe.bin')`,
          [userId, deviceId, "text/html\r\nx-injected: yes", Buffer.alloc(32, 15)],
        ),
        isConstraintViolation,
      );

      const privateMedia = await client.query<{ id: string }>(
        `INSERT INTO media_objects (
           user_id, device_id, visibility, file_name, content_type, byte_size,
           sha256, storage_key, cipher_algorithm, crypto_version, key_version,
           nonce, plaintext_content_type
         ) VALUES (
           $1, $2, 'private', 'private.enc', 'application/octet-stream', 144,
           $3, 'integration/private.enc', 'A256GCM', 1, 1, $4, 'image/jpeg'
         )
         RETURNING id`,
        [userId, deviceId, Buffer.alloc(32, 6), Buffer.alloc(12, 2)],
      );
      const privateMediaId = privateMedia.rows[0]?.id;
      assert.ok(privateMediaId);

      await client.query(
        `INSERT INTO record_media (user_id, record_id, media_id, position)
         VALUES ($1, $2, $3, 0)`,
        [userId, publicRecordId, publicMediaId],
      );
      await client.query("BEGIN");
      try {
        await client.query(
          `UPDATE records
           SET nonce = $2, ciphertext = $3
           WHERE id = $1`,
          [privateRecordId, Buffer.alloc(12, 7), Buffer.alloc(18, 8)],
        );
        await client.query(
          `INSERT INTO record_media (user_id, record_id, media_id, position)
           VALUES ($1, $2, $3, 0)`,
          [userId, privateRecordId, privateMediaId],
        );
        await client.query("COMMIT");
      } catch (error) {
        await client.query("ROLLBACK");
        throw error;
      }
      await assert.rejects(
        client.query(
          `INSERT INTO record_media (user_id, record_id, media_id, position)
           VALUES ($1, $2, $3, 1)`,
          [userId, publicRecordId, privateMediaId],
        ),
        isConstraintViolation,
      );
      await assert.rejects(
        client.query(
          `INSERT INTO record_media (user_id, record_id, media_id, position)
           VALUES ($1, $2, $3, 1)`,
          [userId, privateRecordId, publicMediaId],
        ),
        isConstraintViolation,
      );

      const privateBeforeDelete = await client.query<{
        revision: string;
        nonce: Buffer;
        ciphertext: Buffer;
      }>("SELECT revision, nonce, ciphertext FROM records WHERE id = $1", [privateRecordId]);
      const privateLiveRevision = Number(privateBeforeDelete.rows[0]?.revision);
      assert.ok(privateBeforeDelete.rows[0]?.nonce);
      assert.ok(privateBeforeDelete.rows[0]?.ciphertext);

      await assert.rejects(
        client.query("UPDATE records SET deleted_at = now() WHERE id = $1", [privateRecordId]),
        isRecordContentConstraintViolation,
      );
      const privateDelete = await client.query<{ revision: string }>(
        `UPDATE records
         SET deleted_at = now(),
             cipher_algorithm = NULL,
             crypto_version = NULL,
             key_version = NULL,
             nonce = NULL,
             ciphertext = NULL,
             encrypted_content_type = NULL
         WHERE id = $1
         RETURNING revision`,
        [privateRecordId],
      );
      const privateTombstoneRevision = Number(privateDelete.rows[0]?.revision);
      assert.equal(privateTombstoneRevision, privateLiveRevision + 1);

      const privateTombstone = await client.query<{
        deleted: boolean;
        cipher_algorithm: string | null;
        crypto_version: number | null;
        key_version: number | null;
        nonce: Buffer | null;
        ciphertext: Buffer | null;
        encrypted_content_type: string | null;
        live_snapshot: Record<string, unknown>;
        tombstone_snapshot: Record<string, unknown>;
        operation: string;
        change_revision: string;
      }>(
        `SELECT
           r.deleted_at IS NOT NULL AS deleted,
           r.cipher_algorithm,
           r.crypto_version,
           r.key_version,
           r.nonce,
           r.ciphertext,
           r.encrypted_content_type,
           live.snapshot AS live_snapshot,
           tombstone.snapshot AS tombstone_snapshot,
           change.operation,
           change.revision AS change_revision
         FROM records AS r
         JOIN record_revisions AS live
           ON live.record_id = r.id AND live.revision = $2
         JOIN record_revisions AS tombstone
           ON tombstone.record_id = r.id AND tombstone.revision = r.revision
         JOIN change_log AS change
           ON change.entity_type = 'record'
          AND change.entity_id = r.id
          AND change.revision = r.revision
         WHERE r.id = $1`,
        [privateRecordId, privateLiveRevision],
      );
      const privateTombstoneRow = privateTombstone.rows[0];
      assert.ok(privateTombstoneRow);
      assert.equal(privateTombstoneRow.deleted, true);
      assert.deepEqual(
        [
          privateTombstoneRow.cipher_algorithm,
          privateTombstoneRow.crypto_version,
          privateTombstoneRow.key_version,
          privateTombstoneRow.nonce,
          privateTombstoneRow.ciphertext,
          privateTombstoneRow.encrypted_content_type,
        ],
        [null, null, null, null, null, null],
      );
      assert.equal(typeof privateTombstoneRow.live_snapshot.nonce, "string");
      assert.equal(typeof privateTombstoneRow.live_snapshot.ciphertext, "string");
      assert.equal(privateTombstoneRow.tombstone_snapshot.nonce, null);
      assert.equal(privateTombstoneRow.tombstone_snapshot.ciphertext, null);
      assert.equal(privateTombstoneRow.operation, "delete");
      assert.equal(Number(privateTombstoneRow.change_revision), privateTombstoneRevision);

      const retainedPrivateMedia = await client.query<{
        attachment_count: string;
        status: string;
        deleted_at: Date | null;
      }>(
        `SELECT
           (SELECT count(*) FROM record_media WHERE record_id = $1) AS attachment_count,
           status,
           deleted_at
         FROM media_objects
         WHERE id = $2`,
        [privateRecordId, privateMediaId],
      );
      assert.equal(Number(retainedPrivateMedia.rows[0]?.attachment_count), 1);
      assert.equal(retainedPrivateMedia.rows[0]?.status, "ready");
      assert.equal(retainedPrivateMedia.rows[0]?.deleted_at, null);
      await assert.rejects(
        client.query(
          "UPDATE media_objects SET status = 'deleted', deleted_at = now() WHERE id = $1",
          [privateMediaId],
        ),
        isConstraintViolation,
      );
      await assert.rejects(
        client.query("DELETE FROM media_objects WHERE id = $1", [privateMediaId]),
        isConstraintViolation,
      );

      const publicUpload = await client.query<{
        status: string;
        media_id: string | null;
        received_bytes: string;
        completed_at: Date | null;
        aborted_at: Date | null;
      }>(
        `INSERT INTO media_upload_sessions (
           user_id, device_id, file_name, content_type, byte_size, sha256, expires_at
         ) VALUES (
           $1, $2, 'upload.jpg', 'image/jpeg', 256, $3, now() + interval '1 hour'
         )
         RETURNING status, media_id, received_bytes, completed_at, aborted_at`,
        [userId, deviceId, Buffer.alloc(32, 7)],
      );
      assert.deepEqual(publicUpload.rows[0], {
        status: "reserved",
        media_id: null,
        received_bytes: "0",
        completed_at: null,
        aborted_at: null,
      });

      const requestedPrivateMediaId = randomUUID();
      const privateUpload = await client.query<{
        status: string;
        requested_media_id: string;
        media_id: string | null;
      }>(
        `INSERT INTO media_upload_sessions (
           user_id, device_id, requested_media_id, file_name, content_type,
           byte_size, sha256, cipher_algorithm, crypto_version, key_version,
           nonce, plaintext_content_type, expires_at
         ) VALUES (
           $1, $2, $3, 'upload.enc', 'application/octet-stream',
           272, $4, 'A256GCM', 1, 1, $5, 'image/jpeg', now() + interval '1 hour'
         )
         RETURNING status, requested_media_id, media_id`,
        [
          userId,
          deviceId,
          requestedPrivateMediaId,
          Buffer.alloc(32, 8),
          Buffer.alloc(12, 3),
        ],
      );
      assert.deepEqual(privateUpload.rows[0], {
        status: "reserved",
        requested_media_id: requestedPrivateMediaId,
        media_id: null,
      });
      await assert.rejects(
        client.query(
          `INSERT INTO media_upload_sessions (
             user_id, device_id, file_name, content_type, byte_size, sha256,
             cipher_algorithm, crypto_version, key_version, nonce, expires_at
           ) VALUES (
             $1, $2, 'invalid.enc', 'application/octet-stream', 272, $3,
             'A256GCM', 1, 1, $4, now() + interval '1 hour'
           )`,
          [userId, deviceId, Buffer.alloc(32, 9), Buffer.alloc(12, 4)],
        ),
        isConstraintViolation,
      );

      const noOpBefore = await client.query<{
        revision: string;
        updated_at: string;
        revision_count: string;
        change_count: string;
      }>(
        `SELECT
           revision,
           updated_at::text,
           (SELECT count(*) FROM record_revisions WHERE record_id = records.id) AS revision_count,
           (SELECT count(*) FROM change_log WHERE entity_type = 'record' AND entity_id = records.id)
             AS change_count
         FROM records
         WHERE id = $1`,
        [publicRecordId],
      );
      await client.query("UPDATE records SET metadata = metadata WHERE id = $1", [publicRecordId]);
      const noOpAfter = await client.query<{
        revision: string;
        updated_at: string;
        revision_count: string;
        change_count: string;
      }>(
        `SELECT
           revision,
           updated_at::text,
           (SELECT count(*) FROM record_revisions WHERE record_id = records.id) AS revision_count,
           (SELECT count(*) FROM change_log WHERE entity_type = 'record' AND entity_id = records.id)
             AS change_count
         FROM records
         WHERE id = $1`,
        [publicRecordId],
      );
      assert.deepEqual(noOpAfter.rows[0], noOpBefore.rows[0]);

      const event = await client.query<{ id: string }>(
        `INSERT INTO events (
           user_id, device_id, starts_at, ends_at, label, type, metadata
         ) VALUES ($1, $2, now(), now(), 'Solar flare', 1, $3::jsonb)
         RETURNING id`,
        [userId, deviceId, JSON.stringify({ class: "X1.7" })],
      );
      const eventId = event.rows[0]?.id;
      assert.ok(eventId);

      await client.query("UPDATE records SET metadata = $2::jsonb WHERE id = $1", [
        publicRecordId,
        JSON.stringify({ test: "updated" }),
      ]);
      await client.query("UPDATE events SET label = 'Solar flare updated' WHERE id = $1", [
        eventId,
      ]);

      const revisionCounts = await client.query<{
        record_revision_count: string;
        event_revision_count: string;
      }>(
        `SELECT
           (SELECT count(*) FROM record_revisions WHERE record_id = $1) AS record_revision_count,
           (SELECT count(*) FROM event_revisions WHERE event_id = $2) AS event_revision_count`,
        [publicRecordId, eventId],
      );
      assert.equal(Number(revisionCounts.rows[0]?.record_revision_count), 2);
      assert.equal(Number(revisionCounts.rows[0]?.event_revision_count), 2);

      const publicDelete = await client.query<{ revision: string }>(
        "UPDATE records SET deleted_at = now() WHERE id = $1 RETURNING revision",
        [publicRecordId],
      );
      const publicTombstoneRevision = Number(publicDelete.rows[0]?.revision);
      assert.equal(publicTombstoneRevision, 3);
      const publicTombstone = await client.query<{
        deleted: boolean;
        public_payload: Record<string, unknown>;
        snapshot_payload: Record<string, unknown>;
        snapshot_deleted_at: string;
        operation: string;
        change_revision: string;
      }>(
        `SELECT
           r.deleted_at IS NOT NULL AS deleted,
           r.public_payload,
           rr.snapshot -> 'public_payload' AS snapshot_payload,
           rr.snapshot ->> 'deleted_at' AS snapshot_deleted_at,
           change.operation,
           change.revision AS change_revision
         FROM records AS r
         JOIN record_revisions AS rr
           ON rr.record_id = r.id AND rr.revision = r.revision
         JOIN change_log AS change
           ON change.entity_type = 'record'
          AND change.entity_id = r.id
          AND change.revision = r.revision
         WHERE r.id = $1`,
        [publicRecordId],
      );
      const publicTombstoneRow = publicTombstone.rows[0];
      assert.ok(publicTombstoneRow);
      assert.equal(publicTombstoneRow.deleted, true);
      assert.deepEqual(publicTombstoneRow.public_payload, { text: "public" });
      assert.deepEqual(publicTombstoneRow.snapshot_payload, { text: "public" });
      assert.ok(publicTombstoneRow.snapshot_deleted_at);
      assert.equal(publicTombstoneRow.operation, "delete");
      assert.equal(Number(publicTombstoneRow.change_revision), publicTombstoneRevision);

      const changes = await client.query<{ entity_type: string; operation: string }>(
        `SELECT entity_type, operation
         FROM change_log
         WHERE user_id = $1
         ORDER BY sequence`,
        [userId],
      );
      assert.ok(changes.rows.some((row) => row.entity_type === "record" && row.operation === "upsert"));
      assert.ok(changes.rows.some((row) => row.entity_type === "event" && row.operation === "upsert"));
      assert.ok(changes.rows.some((row) => row.entity_type === "user" && row.operation === "upsert"));
    } finally {
      if (userId !== undefined) {
        await client.query("DELETE FROM record_media WHERE user_id = $1", [userId]);
        await client.query("DELETE FROM users WHERE id = $1", [userId]);
      }
      await client.end();
    }
  },
);

function isConstraintViolation(error: unknown): boolean {
  return (
    error instanceof Error &&
    "code" in error &&
    ["23001", "23503", "23514"].includes(String((error as DatabaseError).code))
  );
}

function isRecordContentConstraintViolation(error: unknown): boolean {
  return (
    isConstraintViolation(error) &&
    String((error as DatabaseError).constraint) === "records_visibility_content_check"
  );
}
