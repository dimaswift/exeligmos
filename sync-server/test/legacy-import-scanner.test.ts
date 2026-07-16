import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import {
  LegacyStoreValidationError,
  scanLegacyStore,
} from "../src/legacy-import/scanner.js";
import {
  LegacyImportMappingError,
  mappedDeviceId,
  validateLegacyImportMapping,
} from "../src/legacy-import/mapping.js";

const TAG_ID = "11111111-1111-4111-8111-111111111111";
const ENTRY_ID = "22222222-2222-4222-8222-222222222222";
const MEDIA_ID = "33333333-3333-4333-8333-333333333333";

test("legacy scan validates relationships and produces a stable byte-level manifest", async () => {
  const root = await fixture();
  try {
    const progress: string[] = [];
    const first = await scanLegacyStore(root, {
      onProgress: (value) => progress.push(value.phase),
    });
    const second = await scanLegacyStore(root);

    assert.deepEqual(first.manifest, second.manifest);
    assert.match(first.manifest.sourceChecksum, /^[a-f0-9]{64}$/);
    assert.equal(first.manifest.tagCount, 1);
    assert.equal(first.manifest.recordCount, 1);
    assert.equal(first.manifest.mediaCount, 1);
    assert.equal(first.manifest.mediaBytes, 12);
    assert.deepEqual(first.manifest.deviceIds, ["LEGACY-PHONE"]);
    assert.equal(first.tags[0]?.compactId, "007");
    assert.equal(first.entries[0]?.tagCompactIds[0], "007");
    assert.equal(first.entries[0]?.media[0]?.sha256.length, 64);
    assert.ok(progress.includes("tags"));
    assert.ok(progress.includes("entries"));
    assert.ok(progress.includes("media"));

    await writeFile(first.entries[0]!.media[0]!.absolutePath, "hello world!");
    const changed = await scanLegacyStore(root);
    assert.notEqual(changed.manifest.sourceChecksum, first.manifest.sourceChecksum);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("legacy scan rejects unresolved compact tag references", async () => {
  const root = await fixture({ tagIds: ["010"] });
  try {
    await assert.rejects(
      scanLegacyStore(root),
      (error: unknown) => {
        assert.ok(error instanceof LegacyStoreValidationError);
        assert.match(error.message, /references missing tag 010/);
        return true;
      },
    );
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("legacy scan rejects values that the v2 tag and media constraints cannot store", async () => {
  const root = await fixture({
    tagCreatedAt: "not-a-timestamp",
    contentType: "text/plain\r\nx-injected: yes",
  });
  try {
    await assert.rejects(
      scanLegacyStore(root),
      (error: unknown) => {
        assert.ok(error instanceof LegacyStoreValidationError);
        assert.match(error.message, /tag\.json#\/createdAt must be an RFC 3339 timestamp/);
        assert.match(error.message, /contentType must be a concrete type\/subtype/);
        return true;
      },
    );
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("legacy mapping requires an explicit owned-device mapping for every source ID", async () => {
  const root = await fixture();
  try {
    const scan = await scanLegacyStore(root);
    assert.throws(
      () => validateLegacyImportMapping({
        schemaVersion: 1,
        userId: "44444444-4444-4444-8444-444444444444",
        devices: {},
      }, scan),
      (error: unknown) => {
        assert.ok(error instanceof LegacyImportMappingError);
        assert.match(error.message, /LEGACY-PHONE/);
        return true;
      },
    );

    const mapping = validateLegacyImportMapping({
      schemaVersion: 1,
      userId: "44444444-4444-4444-8444-444444444444",
      devices: {
        "LEGACY-PHONE": "55555555-5555-4555-8555-555555555555",
      },
    }, scan);
    assert.match(mapping.mappingChecksum, /^[a-f0-9]{64}$/);
    assert.equal(
      mappedDeviceId(mapping, "LEGACY-PHONE"),
      "55555555-5555-4555-8555-555555555555",
    );
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

async function fixture(options: {
  readonly tagIds?: readonly string[];
  readonly tagCreatedAt?: string;
  readonly contentType?: string;
} = {}): Promise<string> {
  const root = await mkdtemp(path.join(os.tmpdir(), "exeligmos-legacy-scan-"));
  const tagDirectory = path.join(root, "tags", TAG_ID);
  const entryDirectory = path.join(root, "entries", "sample-entry");
  const mediaDirectory = path.join(entryDirectory, "media");
  await Promise.all([
    mkdir(tagDirectory, { recursive: true }),
    mkdir(mediaDirectory, { recursive: true }),
  ]);

  await writeFile(
    path.join(tagDirectory, "tag.json"),
    JSON.stringify({
      id: TAG_ID,
      octalID: "7",
      name: "Sample",
      emoji: "◇",
      anchorDate: "2026-01-01T00:00:00Z",
      saros: 1,
      createdAt: options.tagCreatedAt ?? "2026-01-01T00:00:00Z",
      updatedAt: "2026-01-01T00:00:00Z",
    }),
  );
  const mediaRelativePath = `entries/sample-entry/media/${MEDIA_ID}.txt`;
  await writeFile(path.join(root, mediaRelativePath), "hello world\n");
  await writeFile(
    path.join(entryDirectory, "entry.json"),
    JSON.stringify({
      id: ENTRY_ID,
      createdAt: "2026-01-02T00:00:00Z",
      updatedAt: "2026-01-02T00:00:00Z",
      eventDate: "2026-01-02T00:00:00Z",
      text: "fixture",
      sourceDeviceID: "LEGACY-PHONE",
      tagIDs: options.tagIds ?? ["007"],
      mediaItems: [{
        id: MEDIA_ID,
        type: "document",
        localPath: `${MEDIA_ID}.txt`,
        createdAt: "2026-01-02T00:00:00Z",
      }],
    }),
  );
  await writeFile(
    path.join(entryDirectory, "media.json"),
    JSON.stringify([{
      id: MEDIA_ID,
      type: "document",
      createdAt: "2026-01-02T00:00:00Z",
      relativePath: mediaRelativePath,
      fileName: `${MEDIA_ID}.txt`,
      contentType: options.contentType ?? "text/plain",
    }]),
  );
  return root;
}
