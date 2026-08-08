import { createHash } from "node:crypto";
import { createReadStream } from "node:fs";
import { access, readdir, realpath, stat } from "node:fs/promises";
import path from "node:path";
import { promisify } from "node:util";
import { execFile } from "node:child_process";

const runFile = promisify(execFile);

export const SAROS_GROUP_SECONDS = 568_971_743.04 / 8 ** 7;

const supportedExtensions = Object.freeze({
  audio: new Set([
    ".aac",
    ".aif",
    ".aiff",
    ".flac",
    ".m4a",
    ".mp3",
    ".ogg",
    ".opus",
    ".wav",
  ]),
  photo: new Set([
    ".avif",
    ".heic",
    ".heif",
    ".jpeg",
    ".jpg",
    ".png",
    ".tif",
    ".tiff",
    ".webp",
  ]),
  video: new Set([
    ".avi",
    ".m4v",
    ".mkv",
    ".mov",
    ".mp4",
    ".mpeg",
    ".mpg",
    ".webm",
  ]),
});

export async function isMounted(
  mountPath,
  { platform = process.platform, run = runFile } = {},
) {
  try {
    await access(mountPath);
    if (!(await stat(mountPath)).isDirectory()) return false;
    if (platform !== "darwin") return true;
    const { stdout } = await run("diskutil", ["info", "-plist", mountPath], {
      encoding: "utf8",
      maxBuffer: 2 * 1024 * 1024,
    });
    const mountedAt = plistString(stdout, "MountPoint");
    const deviceNode = plistString(stdout, "DeviceNode");
    if (mountedAt === undefined || deviceNode === undefined) return false;
    return (await realpath(mountedAt)) === (await realpath(mountPath));
  } catch {
    return false;
  }
}

export async function settledScan(
  config,
  sleep = delay,
  descriptionCache = new Map(),
  now = Date.now,
) {
  return (await settledScanState(config, sleep, descriptionCache, now)).items;
}

export async function settledScanState(
  config,
  sleep = delay,
  descriptionCache = new Map(),
  now = Date.now,
) {
  const first = await scanFileStats(config.mountPath);
  await sleep(config.settleDelayMs);
  const second = await scanFileStats(config.mountPath);
  const stable = [];
  const unstable = [];
  const nowMs = now();
  const minimumFileAgeMs = config.minimumFileAgeMs ?? 0;
  for (const item of second.values()) {
    const previous = first.get(item.relativePath);
    if (
      previous !== undefined &&
      sameFileIdentity(previous, item) &&
      nowMs - item.mtimeMs >= minimumFileAgeMs
    ) {
      stable.push(item);
    } else {
      unstable.push(item);
    }
  }
  const volumeId = await volumeIdentity(config.mountPath);
  const liveCacheKeys = new Set(
    [...second.values()].map((item) =>
      descriptionCacheKey(volumeId, item.relativePath),
    ),
  );
  for (const key of descriptionCache.keys()) {
    if (!liveCacheKeys.has(key)) descriptionCache.delete(key);
  }
  const described = await mapConcurrent(
    stable,
    config.scanConcurrency ?? 2,
    (item) => describeFile(config, volumeId, item, descriptionCache),
  );
  const items = [];
  for (let index = 0; index < described.length; index += 1) {
    const item = described[index];
    if (item === undefined) unstable.push(stable[index]);
    else items.push(item);
  }
  return { items: deduplicateMedia(items), unstable };
}

export async function scanFileStats(mountPath) {
  const roots = await mediaRoots(mountPath);
  const result = new Map();
  for (const root of roots) {
    await walk(root.absolutePath, async (absolutePath) => {
      const extension = path.extname(absolutePath).toLowerCase();
      if (!supportedExtensions[root.kind].has(extension)) return;
      const fileStat = await stat(absolutePath);
      if (!fileStat.isFile() || fileStat.size < 1) return;
      const relativePath = path
        .relative(mountPath, absolutePath)
        .split(path.sep)
        .join("/");
      result.set(relativePath, {
        absolutePath,
        relativePath,
        kind: root.kind,
        byteLength: fileStat.size,
        mtimeMs: fileStat.mtimeMs,
        ctimeMs: fileStat.ctimeMs,
        birthtimeMs: fileStat.birthtimeMs,
        device: fileStat.dev,
        inode: fileStat.ino,
      });
    });
  }
  return result;
}

export function groupMedia(items, spanSeconds = SAROS_GROUP_SECONDS) {
  const sorted = [...items].sort(
    (left, right) =>
      Date.parse(left.capturedAt) - Date.parse(right.capturedAt) ||
      left.sourceKey.localeCompare(right.sourceKey),
  );
  const groups = [];
  for (const item of sorted) {
    const current = groups.at(-1);
    if (
      current === undefined ||
      (Date.parse(item.capturedAt) - Date.parse(current[0].capturedAt)) /
        1_000 >
        spanSeconds
    ) {
      groups.push([item]);
    } else {
      current.push(item);
    }
  }
  return groups.map((group) => {
    const groupKey = sha256Text(
      group
        .map((item) => item.sourceKey)
        .sort()
        .join("\n"),
    );
    return group.map((item) => ({ ...item, groupKey }));
  });
}

export function deduplicateMedia(items) {
  const seen = new Set();
  return [...items]
    .sort(
      (left, right) =>
        Date.parse(left.capturedAt) - Date.parse(right.capturedAt) ||
        left.relativePath.localeCompare(right.relativePath),
    )
    .filter((item) => {
      if (seen.has(item.contentSha256)) return false;
      seen.add(item.contentSha256);
      return true;
    });
}

export function sourceKeyFor({ contentSha256 }) {
  if (!/^[a-f0-9]{64}$/.test(contentSha256)) {
    throw new Error(
      "Media SHA-256 must be 64 lowercase hexadecimal characters.",
    );
  }
  return contentSha256;
}

async function describeFile(config, volumeId, item, descriptionCache) {
  const before = await currentFileIdentity(item.absolutePath);
  if (before === undefined || !sameFileIdentity(item, before)) return undefined;

  const cacheKey = descriptionCacheKey(volumeId, item.relativePath);
  const cached = descriptionCache.get(cacheKey);
  if (cached !== undefined && sameFileIdentity(cached.identity, before)) {
    return { ...cached.description, ...item };
  }

  let contentSha256;
  let probedTimestamp;
  try {
    [contentSha256, probedTimestamp] = await Promise.all([
      sha256File(item.absolutePath),
      probeCaptureTime(config.ffprobeExecutable, item.absolutePath),
    ]);
  } catch (error) {
    const afterFailure = await currentFileIdentity(item.absolutePath);
    if (afterFailure === undefined || !sameFileIdentity(before, afterFailure)) {
      return undefined;
    }
    throw error;
  }
  const after = await currentFileIdentity(item.absolutePath);
  if (after === undefined || !sameFileIdentity(before, after)) return undefined;

  const capturedAt =
    probedTimestamp ??
    new Date(
      Number.isFinite(item.birthtimeMs) && item.birthtimeMs > 0
        ? Math.min(item.birthtimeMs, item.mtimeMs)
        : item.mtimeMs,
    ).toISOString();
  const description = {
    ...item,
    capturedAt,
    contentSha256,
    sourceKey: sourceKeyFor({
      contentSha256,
    }),
  };
  descriptionCache.set(cacheKey, {
    identity: after,
    description,
  });
  return description;
}

async function currentFileIdentity(absolutePath) {
  try {
    const fileStat = await stat(absolutePath);
    if (!fileStat.isFile() || fileStat.size < 1) return undefined;
    return {
      byteLength: fileStat.size,
      mtimeMs: fileStat.mtimeMs,
      ctimeMs: fileStat.ctimeMs,
      birthtimeMs: fileStat.birthtimeMs,
      device: fileStat.dev,
      inode: fileStat.ino,
    };
  } catch {
    return undefined;
  }
}

function sameFileIdentity(left, right) {
  return (
    left.byteLength === right.byteLength &&
    left.mtimeMs === right.mtimeMs &&
    left.ctimeMs === right.ctimeMs &&
    left.birthtimeMs === right.birthtimeMs &&
    left.device === right.device &&
    left.inode === right.inode
  );
}

function descriptionCacheKey(volumeId, relativePath) {
  return `${volumeId}\0${relativePath.normalize("NFC")}`;
}

export async function mapConcurrent(items, concurrency, visit) {
  if (!Number.isSafeInteger(concurrency) || concurrency < 1) {
    throw new Error("concurrency must be a positive integer.");
  }
  const results = new Array(items.length);
  let nextIndex = 0;
  async function consume() {
    while (nextIndex < items.length) {
      const index = nextIndex;
      nextIndex += 1;
      results[index] = await visit(items[index], index);
    }
  }
  const workers = await Promise.allSettled(
    Array.from({ length: Math.min(concurrency, items.length) }, () =>
      consume(),
    ),
  );
  const failure = workers.find((worker) => worker.status === "rejected");
  if (failure !== undefined) throw failure.reason;
  return results;
}

async function probeCaptureTime(executable, absolutePath) {
  try {
    const { stdout } = await runFile(
      executable,
      [
        "-v",
        "error",
        "-show_entries",
        "format_tags:stream_tags",
        "-of",
        "json",
        absolutePath,
      ],
      { encoding: "utf8", maxBuffer: 4 * 1024 * 1024 },
    );
    const values = timestampCandidates(JSON.parse(stdout));
    for (const value of values) {
      const parsed = parseCameraTimestamp(value);
      if (parsed !== undefined) return parsed;
    }
  } catch {
    // Filesystem timestamps remain a deterministic fallback.
  }
  return undefined;
}

function timestampCandidates(value, parentKey = "") {
  if (typeof value === "string") {
    return /(date|time|creation)/i.test(parentKey) ? [value] : [];
  }
  if (Array.isArray(value)) {
    return value.flatMap((entry) => timestampCandidates(entry, parentKey));
  }
  if (value === null || typeof value !== "object") return [];
  const prioritized = Object.entries(value).sort(([left], [right]) => {
    const rank = (key) =>
      /DateTimeOriginal/i.test(key) ? 0 : /creation_time/i.test(key) ? 1 : 2;
    return rank(left) - rank(right);
  });
  return prioritized.flatMap(([key, entry]) => timestampCandidates(entry, key));
}

export function parseCameraTimestamp(value) {
  const trimmed = value.trim();
  const exif =
    /^(\d{4}):(\d{2}):(\d{2})[ T](\d{2}):(\d{2}):(\d{2})(?:([+-]\d{2}:\d{2}|Z))?$/.exec(
      trimmed,
    );
  if (exif !== null) {
    const [, year, month, day, hour, minute, second, zone] = exif;
    const normalized = `${year}-${month}-${day}T${hour}:${minute}:${second}${zone ?? ""}`;
    const date =
      zone === undefined
        ? new Date(
            Number(year),
            Number(month) - 1,
            Number(day),
            Number(hour),
            Number(minute),
            Number(second),
          )
        : new Date(normalized);
    return Number.isNaN(date.valueOf()) ? undefined : date.toISOString();
  }
  const date = new Date(trimmed);
  return Number.isNaN(date.valueOf()) ? undefined : date.toISOString();
}

async function mediaRoots(mountPath) {
  const entries = await readdir(mountPath, { withFileTypes: true });
  const result = [];
  for (const [folder, kind] of [
    ["AUDIO", "audio"],
    ["VIDEO", "video"],
    ["PHOTO", "photo"],
  ]) {
    const match = entries.find(
      (entry) =>
        entry.isDirectory() && entry.name.toLocaleUpperCase("en-US") === folder,
    );
    if (match !== undefined) {
      result.push({ absolutePath: path.join(mountPath, match.name), kind });
    }
  }
  return result;
}

async function walk(directory, visit) {
  const entries = await readdir(directory, { withFileTypes: true });
  for (const entry of entries) {
    if (ignoredName(entry.name)) continue;
    const absolutePath = path.join(directory, entry.name);
    if (entry.isDirectory()) await walk(absolutePath, visit);
    else if (entry.isFile()) await visit(absolutePath);
  }
}

function ignoredName(name) {
  return (
    name.startsWith(".") ||
    name.startsWith("._") ||
    ["SPOTLIGHT-V100", "TRASHES", "FSEVENTSD"].includes(
      name.toLocaleUpperCase("en-US"),
    )
  );
}

async function volumeIdentity(mountPath) {
  try {
    const { stdout } = await runFile(
      "diskutil",
      ["info", "-plist", mountPath],
      { encoding: "utf8", maxBuffer: 2 * 1024 * 1024 },
    );
    const match = /<key>VolumeUUID<\/key>\s*<string>([^<]+)<\/string>/.exec(
      stdout,
    );
    if (match?.[1] !== undefined && match[1].trim() !== "")
      return match[1].trim();
  } catch {
    // realpath keeps non-macOS test and development mounts usable.
  }
  return realpath(mountPath);
}

function plistString(document, key) {
  const escapedKey = key.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const match = new RegExp(
    `<key>${escapedKey}<\\/key>\\s*<string>([^<]*)<\\/string>`,
  ).exec(document);
  if (match?.[1] === undefined || match[1] === "") return undefined;
  return match[1]
    .replaceAll("&amp;", "&")
    .replaceAll("&lt;", "<")
    .replaceAll("&gt;", ">")
    .replaceAll("&quot;", '"')
    .replaceAll("&apos;", "'");
}

async function sha256File(absolutePath) {
  const hash = createHash("sha256");
  for await (const chunk of createReadStream(absolutePath)) hash.update(chunk);
  return hash.digest("hex");
}

function sha256Text(value) {
  return createHash("sha256").update(value, "utf8").digest("hex");
}

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}
