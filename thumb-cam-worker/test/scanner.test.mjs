import assert from "node:assert/strict";
import {
  chmod,
  mkdir,
  mkdtemp,
  readFile,
  rm,
  utimes,
  writeFile,
} from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import {
  groupMedia,
  isMounted,
  mapConcurrent,
  parseCameraTimestamp,
  SAROS_GROUP_SECONDS,
  settledScan,
  settledScanState,
  sourceKeyFor,
} from "../src/scanner.mjs";

function item(sourceKey, seconds) {
  return {
    sourceKey,
    capturedAt: new Date(seconds * 1_000).toISOString(),
  };
}

test("groups by total span from the first capture, not adjacent chaining", () => {
  const groups = groupMedia([
    item("a".repeat(64), 0),
    item("b".repeat(64), SAROS_GROUP_SECONDS - 0.01),
    item("c".repeat(64), SAROS_GROUP_SECONDS * 2 - 0.02),
  ]);
  assert.deepEqual(
    groups.map((group) => group.map((entry) => entry.sourceKey[0])),
    [["a", "b"], ["c"]],
  );
  assert.match(groups[0][0].groupKey, /^[a-f0-9]{64}$/);
  assert.equal(groups[0][0].groupKey, groups[0][1].groupKey);
});

test("uses the exact catalog-derived Saros duration", () => {
  assert.equal(SAROS_GROUP_SECONDS, 271.30686904907225);
});

test("source key changes when content or camera path changes", () => {
  const base = {
    volumeId: "volume",
    relativePath: "PHOTO/ONE.JPG",
    capturedAt: "2026-07-29T10:00:00.000Z",
    byteLength: 123,
    contentSha256: "a".repeat(64),
  };
  assert.equal(sourceKeyFor(base), sourceKeyFor({ ...base }));
  assert.notEqual(
    sourceKeyFor(base),
    sourceKeyFor({ ...base, contentSha256: "b".repeat(64) }),
  );
  assert.notEqual(
    sourceKeyFor(base),
    sourceKeyFor({ ...base, relativePath: "PHOTO/TWO.JPG" }),
  );
});

test("parses EXIF timestamps and explicit zones", () => {
  assert.equal(
    parseCameraTimestamp("2026:07:29 10:11:12Z"),
    "2026-07-29T10:11:12.000Z",
  );
  assert.equal(
    parseCameraTimestamp("2026:07:29 10:11:12+03:00"),
    "2026-07-29T07:11:12.000Z",
  );
  assert.equal(parseCameraTimestamp("not a timestamp"), undefined);
});

test("reuses descriptions for unchanged stat identities", async (context) => {
  const fixture = await scannerFixture(context);
  const cache = new Map();
  const config = {
    ...fixture.config,
    minimumFileAgeMs: 0,
    scanConcurrency: 2,
  };

  const first = await settledScan(config, async () => undefined, cache);
  const second = await settledScan(config, async () => undefined, cache);

  assert.equal(first.length, 1);
  assert.equal(second[0].sourceKey, first[0].sourceKey);
  assert.equal(await readFile(fixture.probeMarker, "utf8"), "x");

  await writeFile(fixture.mediaPath, "bravo");
  const changedTime = new Date(Date.now() - 5_000);
  await utimes(fixture.mediaPath, changedTime, changedTime);
  const changed = await settledScan(config, async () => undefined, cache);
  assert.equal(changed.length, 1);
  assert.notEqual(changed[0].sourceKey, first[0].sourceKey);
  assert.equal(await readFile(fixture.probeMarker, "utf8"), "xx");
});

test("skips young files and files that change while being described", async (context) => {
  const fixture = await scannerFixture(context);
  const now = Date.now();
  const young = await settledScanState(
    {
      ...fixture.config,
      minimumFileAgeMs: 10_000,
      scanConcurrency: 1,
    },
    async () => undefined,
    new Map(),
    () => now,
  );
  assert.deepEqual(young.items, []);
  assert.equal(young.unstable.length, 1);

  await utimes(
    fixture.mediaPath,
    new Date(now - 20_000),
    new Date(now - 20_000),
  );
  const mutatingProbe = path.join(fixture.root, "mutating-ffprobe.mjs");
  await writeFile(
    mutatingProbe,
    [
      "#!/usr/bin/env node",
      'const fs = await import("node:fs");',
      "const target = process.argv.at(-1);",
      'fs.appendFileSync(target, "x");',
      'process.stdout.write("{}");',
    ].join("\n"),
  );
  await chmod(mutatingProbe, 0o755);

  const changing = await settledScanState(
    {
      ...fixture.config,
      ffprobeExecutable: mutatingProbe,
      minimumFileAgeMs: 0,
      scanConcurrency: 1,
    },
    async () => undefined,
    new Map(),
  );
  assert.deepEqual(changing.items, []);
  assert.equal(changing.unstable.length, 1);
});

test("bounds concurrent file descriptions", async () => {
  let active = 0;
  let maximumActive = 0;
  const result = await mapConcurrent([1, 2, 3, 4, 5], 2, async (value) => {
    active += 1;
    maximumActive = Math.max(maximumActive, active);
    await new Promise((resolve) => setTimeout(resolve, 5));
    active -= 1;
    return value * 2;
  });

  assert.equal(maximumActive, 2);
  assert.deepEqual(result, [2, 4, 6, 8, 10]);
});

test("requires a real disk mount on macOS and stays portable elsewhere", async (context) => {
  const root = await mkdtemp(path.join(os.tmpdir(), "thumb-mounted-"));
  context.after(() => rm(root, { force: true, recursive: true }));
  const xml = [
    "<plist><dict>",
    "<key>DeviceNode</key><string>/dev/disk9s1</string>",
    `<key>MountPoint</key><string>${root}</string>`,
    "</dict></plist>",
  ].join("");

  assert.equal(
    await isMounted(root, {
      platform: "darwin",
      run: async () => ({ stdout: xml }),
    }),
    true,
  );
  assert.equal(
    await isMounted(root, {
      platform: "darwin",
      run: async () => {
        throw new Error("not a disk");
      },
    }),
    false,
  );
  assert.equal(await isMounted(root, { platform: "linux" }), true);
});

async function scannerFixture(context) {
  const root = await mkdtemp(path.join(os.tmpdir(), "thumb-scan-"));
  context.after(() => rm(root, { force: true, recursive: true }));
  const photoDirectory = path.join(root, "PHOTO");
  await mkdir(photoDirectory);
  const mediaPath = path.join(photoDirectory, "capture.jpg");
  await writeFile(mediaPath, "alpha");
  const probeMarker = `${mediaPath}.probes`;
  const fakeProbe = path.join(root, "fake-ffprobe.mjs");
  await writeFile(
    fakeProbe,
    [
      "#!/usr/bin/env node",
      'const fs = await import("node:fs");',
      "const target = process.argv.at(-1);",
      'fs.appendFileSync(`${target}.probes`, "x");',
      'process.stdout.write("{}");',
    ].join("\n"),
  );
  await chmod(fakeProbe, 0o755);
  return {
    root,
    mediaPath,
    probeMarker,
    config: {
      mountPath: root,
      settleDelayMs: 100,
      ffprobeExecutable: fakeProbe,
    },
  };
}
