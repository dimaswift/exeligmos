import assert from "node:assert/strict";
import { createHash, randomUUID } from "node:crypto";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { Readable } from "node:stream";
import test from "node:test";

import {
  LocalMediaStorage,
  MediaStorageIntegrityError,
  mediaStorageKey,
  mediaUploadStorageKey,
} from "../src/media/storage.js";
import {
  mapMediaRow,
  mediaEtag,
  type MediaRow,
} from "../src/resources/media.js";

const userId = "e42b4fde-8baf-4b95-8bc8-5395b68d0dd2";
const deviceId = "2dca8eab-00a8-4e94-9bd2-2fcbfe17e890";
const mediaId = "6ec0ed9e-32eb-4e70-8ac3-082b1dc240da";

test("local media storage atomically verifies, retries, streams, and deletes bytes", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "exeligmos-media-"));
  const storage = new LocalMediaStorage(root);
  const key = mediaStorageKey(userId, mediaId);
  const content = Buffer.from("verified media bytes");
  const digest = sha256(content);

  try {
    await storage.writeVerified(key, Readable.from([content]), content.byteLength, digest);
    await storage.writeVerified(
      key,
      Readable.from([content.subarray(0, 4), content.subarray(4)]),
      content.byteLength,
      digest,
    );

    const stored = await storage.open(key);
    assert.equal(stored.byteLength, content.byteLength);
    assert.deepEqual(await readAll(stored.stream), content);

    await assert.rejects(
      storage.writeVerified(
        key,
        Readable.from([Buffer.from("wrong media contents")]),
        content.byteLength,
        digest,
      ),
      (error: unknown) =>
        error instanceof MediaStorageIntegrityError && error.kind === "sha256",
    );
    const retained = await storage.open(key);
    assert.deepEqual(await readAll(retained.stream), content);

    await storage.delete(key);
    await storage.delete(key);
    await assert.rejects(storage.open(key), /missing/i);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("local media storage rejects truncated, oversized, and unsafe writes", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "exeligmos-media-"));
  const storage = new LocalMediaStorage(root);
  const key = mediaStorageKey(userId, randomUUID());
  try {
    await assert.rejects(
      storage.writeVerified(key, Readable.from([Buffer.from("abc")]), 4, sha256(Buffer.from("abcd"))),
      (error: unknown) =>
        error instanceof MediaStorageIntegrityError &&
        error.kind === "byte_length" &&
        error.actual === "3",
    );
    await assert.rejects(
      storage.writeVerified(key, Readable.from([Buffer.from("abcde")]), 4, sha256(Buffer.from("abcd"))),
      (error: unknown) =>
        error instanceof MediaStorageIntegrityError &&
        error.kind === "byte_length" &&
        error.actual === "5",
    );
    await assert.rejects(
      storage.writeVerified("../escaped", Readable.from([Buffer.from("x")]), 1, sha256(Buffer.from("x"))),
      /unsafe/i,
    );
    await assert.rejects(
      storage.writeVerified("media\\escaped", Readable.from([Buffer.from("x")]), 1, sha256(Buffer.from("x"))),
      /unsafe/i,
    );
    assert.throws(() => mediaStorageKey(userId.toUpperCase(), mediaId), /canonical/i);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("upload storage keys are scoped to a reservation instead of a media ID", () => {
  const firstUpload = mediaUploadStorageKey(userId, randomUUID());
  const secondUpload = mediaUploadStorageKey(userId, randomUUID());

  assert.notEqual(firstUpload, secondUpload);
  assert.notEqual(firstUpload, mediaStorageKey(userId, mediaId));
  assert.match(firstUpload, /^uploads\//);
});

test("media row mapping keeps private crypto opaque and public URLs representation-stable", () => {
  const privateRow = row({
    visibility: "private",
    cipher_algorithm: "A256GCM",
    crypto_version: 1,
    key_version: 1,
    nonce: Buffer.alloc(12, 7),
    plaintext_content_type: "image/jpeg",
  });
  const privateResource = mapMediaRow(privateRow);
  assert.deepEqual(privateResource.encryption, {
    algorithm: "A256GCM",
    cryptoVersion: 1,
    keyVersion: 1,
    nonce: Buffer.alloc(12, 7).toString("base64"),
    plaintextContentType: "image/jpeg",
  });
  assert.equal(privateResource.publicContentUrl, undefined);
  assert.equal(mediaEtag(mediaId, 3), `"media-${mediaId}-r3"`);

  const publicResource = mapMediaRow(row({}));
  assert.equal(publicResource.encryption, undefined);
  assert.equal(publicResource.publicContentUrl, `/v1/public/media/${mediaId}/content`);
});

function row(overrides: Partial<MediaRow>): MediaRow {
  return {
    id: mediaId,
    user_id: userId,
    device_id: deviceId,
    visibility: "public",
    status: "ready",
    file_name: "photo.jpg",
    content_type: "image/jpeg",
    byte_size: 12,
    sha256: Buffer.alloc(32, 1),
    storage_key: mediaStorageKey(userId, mediaId),
    cipher_algorithm: null,
    crypto_version: null,
    key_version: null,
    nonce: null,
    plaintext_content_type: null,
    revision: 3,
    created_at: "2026-07-15T10:00:00.000Z",
    updated_at: "2026-07-15T10:00:00.000Z",
    deleted_at: null,
    ...overrides,
  };
}

function sha256(value: Buffer): string {
  return createHash("sha256").update(value).digest("hex");
}

async function readAll(stream: Readable): Promise<Buffer> {
  const chunks: Buffer[] = [];
  for await (const chunk of stream) {
    chunks.push(Buffer.from(chunk));
  }
  return Buffer.concat(chunks);
}
