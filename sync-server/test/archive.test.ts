import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import {
  mkdir,
  mkdtemp,
  readFile,
  rm,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { runInNewContext } from "node:vm";

import {
  type ArchiveSnapshot,
  writeReadableArchive,
} from "../src/archive/exporter.js";

const userId = "e42b4fde-8baf-4b95-8bc8-5395b68d0dd2";
const deviceId = "2dca8eab-00a8-4e94-9bd2-2fcbfe17e890";
const publicRecordId = "6ec0ed9e-32eb-4e70-8ac3-082b1dc240da";
const privateRecordId = "7ec0ed9e-32eb-4e70-8ac3-082b1dc240db";
const mediaId = "8ec0ed9e-32eb-4e70-8ac3-082b1dc240dc";
const tagId = "9ec0ed9e-32eb-4e70-8ac3-082b1dc240dd";

test("readable archive writes plain hierarchy, verified media, and dependency-free explorer", async () => {
  const scratch = await mkdtemp(path.join(tmpdir(), "fractonica-archive-test-"));
  const mediaRoot = path.join(scratch, "media-source");
  const destination = path.join(scratch, "archive");
  const storageKey = `${userId}/${mediaId}`;
  const mediaBytes = Buffer.from("archived image bytes");
  await mkdir(path.dirname(path.join(mediaRoot, storageKey)), { recursive: true });
  await writeFile(path.join(mediaRoot, storageKey), mediaBytes);

  try {
    const result = await writeReadableArchive(
      snapshot(storageKey, mediaBytes),
      mediaRoot,
      destination,
    );

    assert.deepEqual(result.counts, {
      users: 1,
      records: 2,
      events: 0,
      media: 1,
      mediaBytes: mediaBytes.byteLength,
    });
    const userFolder = path.join(destination, `users/dimas--${userId}`);
    const publicRecordPath = path.join(
      userFolder,
      `records/2026/07/24/${publicRecordId}/record.json`,
    );
    const privateRecordPath = path.join(
      userFolder,
      `records/2026/07/23/${privateRecordId}/record.json`,
    );
    const archivedMediaPath = path.join(
      userFolder,
      `records/2026/07/24/${publicRecordId}/media/01--photo.jpg`,
    );
    const publicRecord = JSON.parse(await readFile(publicRecordPath, "utf8"));
    const privateRecord = JSON.parse(await readFile(privateRecordPath, "utf8"));
    const recordMediaManifest = JSON.parse(
      await readFile(path.join(path.dirname(publicRecordPath), "media/media.json"), "utf8"),
    );

    assert.equal(publicRecord.record.public_payload.title, "A </script> safe title");
    assert.equal(publicRecord.record.public_payload.emoji, "🧭");
    assert.equal(publicRecord.tags[0].name, "field note");
    assert.equal(
      publicRecord.media[0].archive_content_path,
      "media/01--photo.jpg",
    );
    assert.deepEqual(publicRecord.saros.closest, {
      relation: "closest",
      saros: 141,
      octalAddress: "01234567",
      harmonicDepth: 8,
      rarity: "common",
    });
    assert.deepEqual(publicRecord.saros.series, [141, 149]);
    assert.equal(recordMediaManifest.record_id, publicRecordId);
    assert.equal(recordMediaManifest.items[0].archive_content_path, "media/01--photo.jpg");
    assert.deepEqual(await readFile(archivedMediaPath), mediaBytes);
    assert.deepEqual(privateRecord.record.ciphertext, {
      $encoding: "base64",
      $value: Buffer.from("ciphertext").toString("base64"),
    });

    const html = await readFile(path.join(destination, "index.html"), "utf8");
    const app = await readFile(path.join(destination, "app.js"), "utf8");
    const script = await readFile(path.join(destination, "archive-data.js"), "utf8");
    const readme = await readFile(path.join(destination, "ARCHIVE.txt"), "utf8");
    const manifest = JSON.parse(
      await readFile(path.join(destination, "manifest.json"), "utf8"),
    );
    const checksums = await readFile(path.join(destination, "SHA256SUMS"), "utf8");
    assert.match(html, /archive-data\.js/);
    assert.doesNotMatch(html, /https?:\/\//);
    assert.doesNotThrow(() => new Function(app));
    assert.match(script, /A \\u003c\/script> safe title/);
    const browserGlobal: { FRACTONICA_ARCHIVE?: unknown } = {};
    runInNewContext(script, browserGlobal);
    const browserData = browserGlobal.FRACTONICA_ARCHIVE as {
      readonly records: readonly [
        {
          readonly emoji: string;
          readonly media: readonly [{ readonly path: string }];
          readonly saros: {
            readonly closest: { readonly saros: number; readonly octalAddress: string };
            readonly series: readonly number[];
          };
        },
      ];
    };
    assert.equal(
      browserData.records[0].media[0].path,
      `users/dimas--${userId}/records/2026/07/24/${publicRecordId}/media/01--photo.jpg`,
    );
    assert.equal(browserData.records[0].saros.closest.saros, 141);
    assert.equal(browserData.records[0].saros.closest.octalAddress, "01234567");
    assert.equal(browserData.records[0].emoji, "🧭");
    assert.equal(publicRecord.format, "fractonica-readable-record");
    assert.equal("revisions" in publicRecord, false);
    assert.equal(manifest.format, "fractonica-readable-archive");
    assert.equal("formatVersion" in manifest, false);
    assert.match(readme, /not a server backup/i);
    assert.match(
      checksums,
      new RegExp(
        `users/dimas--${userId}/records/2026/07/24/${publicRecordId}/media/01--photo\\.jpg`,
      ),
    );
    assert.equal(await verifyChecksums(destination, checksums), true);

    await assert.rejects(
      writeReadableArchive(snapshot(storageKey, mediaBytes), mediaRoot, destination),
      /already exists/,
    );
  } finally {
    await rm(scratch, { recursive: true, force: true });
  }
});

test("readable archive rejects media whose bytes do not match database metadata", async () => {
  const scratch = await mkdtemp(path.join(tmpdir(), "fractonica-archive-test-"));
  const mediaRoot = path.join(scratch, "media-source");
  const destination = path.join(scratch, "archive");
  const storageKey = `${userId}/${mediaId}`;
  await mkdir(path.dirname(path.join(mediaRoot, storageKey)), { recursive: true });
  await writeFile(path.join(mediaRoot, storageKey), "changed bytes");

  try {
    await assert.rejects(
      writeReadableArchive(
        snapshot(storageKey, Buffer.from("expected bytes")),
        mediaRoot,
        destination,
      ),
      /integrity mismatch/,
    );
    await assert.rejects(readFile(destination), /ENOENT/);
  } finally {
    await rm(scratch, { recursive: true, force: true });
  }
});

function snapshot(storageKey: string, mediaBytes: Buffer): ArchiveSnapshot {
  const createdAt = "2026-07-24T12:00:00.000Z";
  const profile = {
    id: userId,
    login: "dimas",
    display_name: "Dimas",
    role: "user",
    status: "active",
    saros_anchor: 141,
    revision: "1",
    created_at: "2026-07-01T10:00:00.000Z",
    updated_at: createdAt,
    disabled_at: null,
  };
  const publicRecord = {
    id: publicRecordId,
    public_id: "xPAi7",
    user_id: userId,
    device_id: deviceId,
    visibility: "public",
    event_at: "2026-07-24T10:30:00.000Z",
    end_at: null,
    public_payload: {
      emoji: "🧭",
      title: "A </script> safe title",
      text: "Readable public record.",
      context: {
        closestSarosPhase: {
          saros: 141,
          octalAddress: "01234567",
          harmonicDepth: 8,
          rarityRawValue: "common",
        },
        spikes: [
          {
            saros: 149,
            octalAddress: "77777777",
            harmonicDepth: 8,
            rarityRawValue: "mythic-7",
            unixTimestamp: 1_753_353_600,
          },
        ],
      },
    },
    metadata: {},
    revision: "2",
    created_at: "2026-07-24T10:31:00.000Z",
    updated_at: "2026-07-24T11:00:00.000Z",
    deleted_at: null,
  };
  const privateRecord = {
    id: privateRecordId,
    public_id: null,
    user_id: userId,
    device_id: deviceId,
    visibility: "private",
    event_at: null,
    public_payload: null,
    cipher_algorithm: "A256GCM",
    nonce: Buffer.alloc(12, 7),
    ciphertext: Buffer.from("ciphertext"),
    encrypted_content_type: "application/vnd.exeligmos.record+json",
    revision: "1",
    created_at: "2026-07-23T08:00:00.000Z",
    updated_at: "2026-07-23T08:00:00.000Z",
    deleted_at: null,
  };
  const media = {
    id: mediaId,
    user_id: userId,
    device_id: deviceId,
    visibility: "public",
    status: "ready",
    file_name: "photo.jpg",
    content_type: "image/jpeg",
    byte_size: String(mediaBytes.byteLength),
    sha256: createHash("sha256").update(mediaBytes).digest(),
    storage_key: storageKey,
    revision: "1",
    created_at: "2026-07-24T10:32:00.000Z",
    updated_at: "2026-07-24T10:32:00.000Z",
    deleted_at: null,
  };
  const tag = {
    id: tagId,
    user_id: userId,
    name: "field note",
    sort_order: 0,
    metadata: {},
    revision: "1",
    created_at: createdAt,
    updated_at: createdAt,
    deleted_at: null,
  };
  return {
    createdAt,
    users: [
      {
        profile,
        devices: [],
        records: [publicRecord, privateRecord],
        recordTags: [
          {
            user_id: userId,
            record_id: publicRecordId,
            tag_id: tagId,
            created_at: createdAt,
          },
        ],
        recordMedia: [
          {
            user_id: userId,
            record_id: publicRecordId,
            media_id: mediaId,
            position: 0,
            created_at: createdAt,
          },
        ],
        media: [media],
        events: [],
        tags: [tag],
        templates: [],
        subscriptions: [],
        references: [],
      },
    ],
  };
}

async function verifyChecksums(root: string, contents: string): Promise<boolean> {
  for (const line of contents.trim().split("\n")) {
    const match = /^([0-9a-f]{64})  (.+)$/.exec(line);
    assert.ok(match);
    const [, expected, relative] = match;
    assert.ok(expected);
    assert.ok(relative);
    const actual = createHash("sha256")
      .update(await readFile(path.join(root, ...relative.split("/"))))
      .digest("hex");
    if (actual !== expected) {
      return false;
    }
  }
  return true;
}
