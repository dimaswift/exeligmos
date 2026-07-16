import { createHash } from "node:crypto";
import { createReadStream } from "node:fs";
import {
  lstat,
  readFile,
  readdir,
  realpath,
} from "node:fs/promises";
import path from "node:path";

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const SHA256_PATTERN = /^[a-f0-9]{64}$/;
const RFC3339_PATTERN = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/;
const MAX_PUBLIC_PAYLOAD_BYTES = 262_144;
const MAX_RESOURCE_METADATA_BYTES = 32_768;
const MEDIA_CONTENT_TYPE_PATTERN =
  /^[A-Za-z0-9][A-Za-z0-9.+_-]{0,126}\/[A-Za-z0-9][A-Za-z0-9.+_-]{0,126}$/;

export type LegacyJsonObject = Record<string, unknown>;

export interface LegacyTagSource {
  readonly id: string;
  readonly compactId: string;
  readonly document: LegacyJsonObject;
  readonly relativePath: string;
  readonly sha256: string;
}

export interface LegacyMediaSource {
  readonly id: string;
  readonly type: string;
  readonly createdAt: string;
  readonly relativePath: string;
  readonly absolutePath: string;
  readonly fileName: string;
  readonly contentType: string;
  readonly byteLength: number;
  readonly sha256: string;
}

export interface LegacyEntrySource {
  readonly id: string;
  readonly eventDate: string;
  readonly endDate?: string;
  readonly createdAt: string;
  readonly updatedAt: string;
  readonly sourceDeviceId?: string;
  readonly tagCompactIds: readonly string[];
  readonly document: LegacyJsonObject;
  readonly relativePath: string;
  readonly sha256: string;
  readonly media: readonly LegacyMediaSource[];
}

export interface LegacyStoreManifest {
  readonly schemaVersion: 1;
  readonly sourceRoot: string;
  readonly sourceChecksum: string;
  readonly tagCount: number;
  readonly recordCount: number;
  readonly mediaCount: number;
  readonly mediaBytes: number;
  readonly deviceIds: readonly string[];
}

export interface LegacyStoreScan {
  readonly manifest: LegacyStoreManifest;
  readonly tags: readonly LegacyTagSource[];
  readonly entries: readonly LegacyEntrySource[];
}

export interface LegacyScanProgress {
  readonly phase: "tags" | "entries" | "media";
  readonly completed: number;
  readonly total: number;
  readonly relativePath?: string;
}

export interface ScanLegacyStoreOptions {
  readonly onProgress?: (progress: LegacyScanProgress) => void;
}

export class LegacyStoreValidationError extends Error {
  constructor(
    readonly issues: readonly string[],
  ) {
    super(`Legacy store validation failed: ${issues.join("; ")}`);
    this.name = "LegacyStoreValidationError";
  }
}

/**
 * Reads and hashes the folder-relay source without modifying it. The returned
 * checksum covers every imported JSON document and media byte in a stable path
 * order, so a dry run and a later apply can prove they saw the same snapshot.
 */
export async function scanLegacyStore(
  sourceRoot: string,
  options: ScanLegacyStoreOptions = {},
): Promise<LegacyStoreScan> {
  const root = await canonicalDirectory(sourceRoot);
  const issues: string[] = [];
  await validateRootLayout(root, issues);
  const fingerprint = createHash("sha256");
  const seenTagIds = new Map<string, string>();
  const seenRecordIds = new Map<string, string>();
  const seenMediaIds = new Map<string, string>();
  const tags: LegacyTagSource[] = [];
  const tagByCompactId = new Map<string, LegacyTagSource>();

  const tagDirectories = await childDirectories(path.join(root, "tags"));
  for (const [index, directory] of tagDirectories.entries()) {
    const absolutePath = path.join(directory, "tag.json");
    const relativePath = portableRelative(root, absolutePath);
    const loaded = await loadJsonObject(absolutePath, relativePath, issues);
    if (loaded !== undefined) {
      addFingerprint(fingerprint, relativePath, loaded.bytes.byteLength, loaded.sha256);
      const id = requiredUuid(loaded.document.id, `${relativePath}#/id`, issues);
      const compactId = normalizedCompactId(loaded.document.octalID);
      if (compactId === undefined) {
        addIssue(issues, `${relativePath}#/octalID must contain an octal value from 000 to 777`);
      }
      if (id !== undefined && compactId !== undefined) {
        validateImportedTag(loaded.document, relativePath, loaded.sha256, issues);
        claimId(seenTagIds, id, relativePath, issues);
        const existing = tagByCompactId.get(compactId);
        if (existing !== undefined) {
          addIssue(
            issues,
            `${relativePath} duplicates compact tag ID ${compactId} from ${existing.relativePath}`,
          );
        } else {
          const tag = { id, compactId, document: loaded.document, relativePath, sha256: loaded.sha256 };
          tags.push(tag);
          tagByCompactId.set(compactId, tag);
        }
      }
    }
    options.onProgress?.({ phase: "tags", completed: index + 1, total: tagDirectories.length, relativePath });
  }

  const entryDirectories = await childDirectories(path.join(root, "entries"));
  const entries: LegacyEntrySource[] = [];
  const deviceIds = new Set<string>();
  let mediaCount = 0;
  let mediaBytes = 0;
  let completedMedia = 0;
  let declaredMediaTotal = 0;

  for (const directory of entryDirectories) {
    const mediaDocument = await loadJsonArray(
      path.join(directory, "media.json"),
      portableRelative(root, path.join(directory, "media.json")),
      issues,
    );
    declaredMediaTotal += mediaDocument?.document.length ?? 0;
  }

  for (const [entryIndex, directory] of entryDirectories.entries()) {
    const entryPath = path.join(directory, "entry.json");
    const entryRelativePath = portableRelative(root, entryPath);
    const loadedEntry = await loadJsonObject(entryPath, entryRelativePath, issues);
    const mediaPath = path.join(directory, "media.json");
    const mediaRelativePath = portableRelative(root, mediaPath);
    const loadedMedia = await loadJsonArray(mediaPath, mediaRelativePath, issues);
    if (loadedEntry === undefined || loadedMedia === undefined) {
      options.onProgress?.({
        phase: "entries",
        completed: entryIndex + 1,
        total: entryDirectories.length,
        relativePath: entryRelativePath,
      });
      continue;
    }

    addFingerprint(fingerprint, entryRelativePath, loadedEntry.bytes.byteLength, loadedEntry.sha256);
    addFingerprint(fingerprint, mediaRelativePath, loadedMedia.bytes.byteLength, loadedMedia.sha256);

    const entryId = requiredUuid(loadedEntry.document.id, `${entryRelativePath}#/id`, issues);
    const eventDate = requiredDate(
      loadedEntry.document.eventDate,
      `${entryRelativePath}#/eventDate`,
      issues,
    );
    const createdAt = requiredDate(
      loadedEntry.document.createdAt,
      `${entryRelativePath}#/createdAt`,
      issues,
    );
    const updatedAt = requiredDate(
      loadedEntry.document.updatedAt,
      `${entryRelativePath}#/updatedAt`,
      issues,
    );
    const endDate = optionalDate(loadedEntry.document.endDate, `${entryRelativePath}#/endDate`, issues);
    if (eventDate !== undefined && endDate !== undefined && Date.parse(endDate) < Date.parse(eventDate)) {
      addIssue(issues, `${entryRelativePath}#/endDate precedes eventDate`);
    }
    const compactPayloadBytes = Buffer.byteLength(JSON.stringify(loadedEntry.document));
    if (compactPayloadBytes > MAX_PUBLIC_PAYLOAD_BYTES) {
      addIssue(
        issues,
        `${entryRelativePath} is ${compactPayloadBytes} compact JSON bytes; public payloads allow ${MAX_PUBLIC_PAYLOAD_BYTES}`,
      );
    }

    const sourceDeviceId = optionalNonEmptyString(
      loadedEntry.document.sourceDeviceID,
      `${entryRelativePath}#/sourceDeviceID`,
      issues,
    );
    if (sourceDeviceId !== undefined) {
      deviceIds.add(sourceDeviceId);
    }
    const tagCompactIds = stringArray(
      loadedEntry.document.tagIDs,
      `${entryRelativePath}#/tagIDs`,
      issues,
    ).map((value, index) => {
      const compact = normalizedCompactId(value);
      if (compact === undefined) {
        addIssue(issues, `${entryRelativePath}#/tagIDs/${index} is not a compact octal tag ID`);
        return value;
      }
      if (!tagByCompactId.has(compact)) {
        addIssue(issues, `${entryRelativePath}#/tagIDs/${index} references missing tag ${compact}`);
      }
      return compact;
    });
    if (new Set(tagCompactIds).size !== tagCompactIds.length) {
      addIssue(issues, `${entryRelativePath}#/tagIDs must not contain duplicates`);
    }

    const media: LegacyMediaSource[] = [];
    for (const [mediaIndex, value] of loadedMedia.document.entries()) {
      const pointer = `${mediaRelativePath}#/${mediaIndex}`;
      if (!isJsonObject(value)) {
        addIssue(issues, `${pointer} must be an object`);
        continue;
      }
      const mediaId = requiredUuid(value.id, `${pointer}/id`, issues);
      const type = requiredNonEmptyString(value.type, `${pointer}/type`, issues);
      const mediaCreatedAt = requiredDate(value.createdAt, `${pointer}/createdAt`, issues);
      const storedPath = requiredNonEmptyString(value.relativePath, `${pointer}/relativePath`, issues);
      const fileName = requiredNonEmptyString(value.fileName, `${pointer}/fileName`, issues);
      const contentType = requiredNonEmptyString(value.contentType, `${pointer}/contentType`, issues);
      if (
        fileName !== undefined &&
        (fileName !== fileName.trim() ||
          fileName.includes("/") ||
          fileName.includes("\\") ||
          fileName.length > 255)
      ) {
        addIssue(issues, `${pointer}/fileName must be trimmed, path-free, and at most 255 characters`);
      }
      if (contentType !== undefined && !MEDIA_CONTENT_TYPE_PATTERN.test(contentType)) {
        addIssue(issues, `${pointer}/contentType must be a concrete type/subtype media type without parameters`);
      }
      if (
        mediaId === undefined ||
        type === undefined ||
        mediaCreatedAt === undefined ||
        storedPath === undefined ||
        fileName === undefined ||
        contentType === undefined
      ) {
        continue;
      }

      claimId(seenMediaIds, mediaId, pointer, issues);
      const mediaAbsolutePath = await safeSourceFile(root, storedPath, pointer, issues);
      if (mediaAbsolutePath === undefined) {
        continue;
      }
      const digest = await hashStableFile(mediaAbsolutePath, pointer, issues);
      if (digest === undefined) {
        continue;
      }
      const normalizedRelativePath = portableRelative(root, mediaAbsolutePath);
      addFingerprint(fingerprint, normalizedRelativePath, digest.byteLength, digest.sha256);
      media.push({
        id: mediaId,
        type,
        createdAt: mediaCreatedAt,
        relativePath: normalizedRelativePath,
        absolutePath: mediaAbsolutePath,
        fileName,
        contentType,
        byteLength: digest.byteLength,
        sha256: digest.sha256,
      });
      mediaCount += 1;
      mediaBytes += digest.byteLength;
      completedMedia += 1;
      options.onProgress?.({
        phase: "media",
        completed: completedMedia,
        total: declaredMediaTotal,
        relativePath: normalizedRelativePath,
      });
    }

    validateEntryMediaReferences(loadedEntry.document, media, entryRelativePath, issues);
    if (
      entryId !== undefined &&
      eventDate !== undefined &&
      createdAt !== undefined &&
      updatedAt !== undefined
    ) {
      claimId(seenRecordIds, entryId, entryRelativePath, issues);
      entries.push({
        id: entryId,
        eventDate,
        ...(endDate === undefined ? {} : { endDate }),
        createdAt,
        updatedAt,
        ...(sourceDeviceId === undefined ? {} : { sourceDeviceId }),
        tagCompactIds,
        document: loadedEntry.document,
        relativePath: entryRelativePath,
        sha256: loadedEntry.sha256,
        media,
      });
    }
    options.onProgress?.({
      phase: "entries",
      completed: entryIndex + 1,
      total: entryDirectories.length,
      relativePath: entryRelativePath,
    });
  }

  if (issues.length > 0) {
    throw new LegacyStoreValidationError(issues);
  }

  return {
    manifest: {
      schemaVersion: 1,
      sourceRoot: root,
      sourceChecksum: fingerprint.digest("hex"),
      tagCount: tags.length,
      recordCount: entries.length,
      mediaCount,
      mediaBytes,
      deviceIds: [...deviceIds].sort(),
    },
    tags,
    entries,
  };
}

function validateImportedTag(
  document: LegacyJsonObject,
  relativePath: string,
  sourceSha256: string,
  issues: string[],
): void {
  const name = document.name;
  if (
    typeof name === "string" &&
    name.trim().length > 0 &&
    (name !== name.trim() || [...name].length > 120)
  ) {
    addIssue(issues, `${relativePath}#/name must be trimmed and at most 120 characters`);
  }
  const emoji = document.emoji;
  if (typeof emoji === "string" && emoji.trim().length > 0 && [...emoji].length > 32) {
    addIssue(issues, `${relativePath}#/emoji must contain at most 32 characters`);
  }
  requiredDate(document.createdAt, `${relativePath}#/createdAt`, issues);
  requiredDate(document.updatedAt, `${relativePath}#/updatedAt`, issues);

  const metadata = {
    legacyImport: {
      schemaVersion: 1,
      sourcePath: relativePath,
      sourceSha256,
      document,
    },
  };
  if (Buffer.byteLength(JSON.stringify(metadata), "utf8") > MAX_RESOURCE_METADATA_BYTES) {
    addIssue(
      issues,
      `${relativePath} cannot fit in the ${MAX_RESOURCE_METADATA_BYTES}-byte tag metadata limit`,
    );
  }
}

async function canonicalDirectory(value: string): Promise<string> {
  const resolved = path.resolve(value);
  const stats = await lstat(resolved);
  if (!stats.isDirectory() || stats.isSymbolicLink()) {
    throw new LegacyStoreValidationError([`${resolved} must be a real directory, not a symlink`]);
  }
  return realpath(resolved);
}

async function childDirectories(root: string): Promise<string[]> {
  let entries;
  try {
    entries = await readdir(root, { withFileTypes: true });
  } catch (error) {
    if (isErrorCode(error, "ENOENT")) {
      return [];
    }
    throw error;
  }
  return entries
    .filter((entry) => entry.isDirectory() && !entry.isSymbolicLink())
    .map((entry) => path.join(root, entry.name))
    .sort((left, right) => left.localeCompare(right, "en"));
}

async function validateRootLayout(root: string, issues: string[]): Promise<void> {
  const allowedDirectories = new Set(["entries", "tags", "animacy"]);
  const knownOlderLayouts = new Set(["groups", "saros", "threads"]);
  for (const entry of await readdir(root, { withFileTypes: true })) {
    if (entry.isSymbolicLink() && (entry.name === "entries" || entry.name === "tags")) {
      addIssue(issues, `${entry.name} must not be a symbolic link`);
      continue;
    }
    if (!entry.isDirectory() || allowedDirectories.has(entry.name) || entry.name.startsWith(".")) {
      continue;
    }
    if (knownOlderLayouts.has(entry.name)) {
      addIssue(
        issues,
        `${entry.name}/ uses an older journal layout; consolidate it with a backed-up pre-v2 tool before importing`,
      );
    } else {
      addIssue(issues, `${entry.name}/ is an unrecognized source directory and would not be imported`);
    }
  }
}

interface LoadedJson<T> {
  readonly document: T;
  readonly bytes: Buffer;
  readonly sha256: string;
}

async function loadJsonObject(
  absolutePath: string,
  displayPath: string,
  issues: string[],
): Promise<LoadedJson<LegacyJsonObject> | undefined> {
  const loaded = await loadJson(absolutePath, displayPath, issues);
  if (loaded === undefined) return undefined;
  if (!isJsonObject(loaded.document)) {
    addIssue(issues, `${displayPath} must contain a JSON object`);
    return undefined;
  }
  return { ...loaded, document: loaded.document };
}

async function loadJsonArray(
  absolutePath: string,
  displayPath: string,
  issues: string[],
): Promise<LoadedJson<unknown[]> | undefined> {
  const loaded = await loadJson(absolutePath, displayPath, issues);
  if (loaded === undefined) return undefined;
  if (!Array.isArray(loaded.document)) {
    addIssue(issues, `${displayPath} must contain a JSON array`);
    return undefined;
  }
  return { ...loaded, document: loaded.document };
}

async function loadJson(
  absolutePath: string,
  displayPath: string,
  issues: string[],
): Promise<LoadedJson<unknown> | undefined> {
  try {
    const stats = await lstat(absolutePath);
    if (!stats.isFile() || stats.isSymbolicLink()) {
      addIssue(issues, `${displayPath} must be a regular non-symlink file`);
      return undefined;
    }
    const bytes = await readFile(absolutePath);
    const document: unknown = JSON.parse(bytes.toString("utf8"));
    return { document, bytes, sha256: createHash("sha256").update(bytes).digest("hex") };
  } catch (error) {
    addIssue(issues, `${displayPath} could not be read as JSON: ${errorMessage(error)}`);
    return undefined;
  }
}

async function safeSourceFile(
  root: string,
  storedPath: string,
  pointer: string,
  issues: string[],
): Promise<string | undefined> {
  if (path.isAbsolute(storedPath) || storedPath.includes("\\") || storedPath.includes("\0")) {
    addIssue(issues, `${pointer}/relativePath is unsafe`);
    return undefined;
  }
  const segments = storedPath.split("/");
  if (segments.some((segment) => segment.length === 0 || segment === "." || segment === "..")) {
    addIssue(issues, `${pointer}/relativePath is unsafe`);
    return undefined;
  }
  const candidate = path.resolve(root, ...segments);
  if (!isInside(root, candidate)) {
    addIssue(issues, `${pointer}/relativePath escapes the source root`);
    return undefined;
  }
  try {
    const stats = await lstat(candidate);
    if (!stats.isFile() || stats.isSymbolicLink()) {
      addIssue(issues, `${pointer}/relativePath must point to a regular non-symlink file`);
      return undefined;
    }
    const canonical = await realpath(candidate);
    if (!isInside(root, canonical)) {
      addIssue(issues, `${pointer}/relativePath resolves outside the source root`);
      return undefined;
    }
    return canonical;
  } catch (error) {
    addIssue(issues, `${pointer}/relativePath cannot be read: ${errorMessage(error)}`);
    return undefined;
  }
}

async function hashStableFile(
  filePath: string,
  displayPath: string,
  issues: string[],
): Promise<{ readonly byteLength: number; readonly sha256: string } | undefined> {
  const before = await lstat(filePath);
  const hash = createHash("sha256");
  let byteLength = 0;
  try {
    for await (const chunk of createReadStream(filePath)) {
      const bytes = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
      byteLength += bytes.byteLength;
      hash.update(bytes);
    }
  } catch (error) {
    addIssue(issues, `${displayPath} could not be hashed: ${errorMessage(error)}`);
    return undefined;
  }
  const after = await lstat(filePath);
  if (before.size !== after.size || before.mtimeMs !== after.mtimeMs || byteLength !== after.size) {
    addIssue(issues, `${displayPath} changed while it was being hashed`);
    return undefined;
  }
  return { byteLength, sha256: hash.digest("hex") };
}

function validateEntryMediaReferences(
  document: LegacyJsonObject,
  media: readonly LegacyMediaSource[],
  relativePath: string,
  issues: string[],
): void {
  const rawItems = document.mediaItems;
  if (!Array.isArray(rawItems)) {
    addIssue(issues, `${relativePath}#/mediaItems must be an array`);
    return;
  }
  const declared = rawItems.map((item, index) => {
    if (!isJsonObject(item)) {
      addIssue(issues, `${relativePath}#/mediaItems/${index} must be an object`);
      return undefined;
    }
    return requiredUuid(item.id, `${relativePath}#/mediaItems/${index}/id`, issues);
  }).filter((value): value is string => value !== undefined).sort();
  const stored = media.map((item) => item.id).sort();
  if (declared.join("\0") !== stored.join("\0")) {
    addIssue(issues, `${relativePath} mediaItems and media.json IDs do not match exactly`);
  }
}

function addFingerprint(hash: ReturnType<typeof createHash>, relativePath: string, size: number, sha256: string): void {
  if (!SHA256_PATTERN.test(sha256)) throw new Error("Invalid internal SHA-256 value");
  hash.update(relativePath);
  hash.update("\0");
  hash.update(String(size));
  hash.update("\0");
  hash.update(sha256);
  hash.update("\n");
}

function requiredUuid(value: unknown, pointer: string, issues: string[]): string | undefined {
  const string = requiredNonEmptyString(value, pointer, issues);
  if (string === undefined) return undefined;
  if (!UUID_PATTERN.test(string)) {
    addIssue(issues, `${pointer} must be a UUID`);
    return undefined;
  }
  return string.toLowerCase();
}

function requiredDate(value: unknown, pointer: string, issues: string[]): string | undefined {
  const string = requiredNonEmptyString(value, pointer, issues);
  if (string === undefined) return undefined;
  if (!RFC3339_PATTERN.test(string) || !Number.isFinite(Date.parse(string))) {
    addIssue(issues, `${pointer} must be an RFC 3339 timestamp`);
    return undefined;
  }
  return new Date(string).toISOString();
}

function optionalDate(value: unknown, pointer: string, issues: string[]): string | undefined {
  if (value === undefined || value === null) return undefined;
  return requiredDate(value, pointer, issues);
}

function requiredNonEmptyString(value: unknown, pointer: string, issues: string[]): string | undefined {
  if (typeof value !== "string" || value.trim().length === 0) {
    addIssue(issues, `${pointer} must be a non-empty string`);
    return undefined;
  }
  return value;
}

function optionalNonEmptyString(value: unknown, pointer: string, issues: string[]): string | undefined {
  if (value === undefined || value === null) return undefined;
  return requiredNonEmptyString(value, pointer, issues);
}

function stringArray(value: unknown, pointer: string, issues: string[]): string[] {
  if (!Array.isArray(value)) {
    addIssue(issues, `${pointer} must be an array`);
    return [];
  }
  return value.map((item, index) => {
    if (typeof item !== "string") {
      addIssue(issues, `${pointer}/${index} must be a string`);
      return "";
    }
    return item;
  });
}

function normalizedCompactId(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined;
  const digits = [...value].filter((character) => "01234567".includes(character)).join("");
  if (digits.length === 0) return undefined;
  const numeric = Number.parseInt(digits, 8);
  if (!Number.isSafeInteger(numeric) || numeric < 0 || numeric >= 512) return undefined;
  return numeric.toString(8).padStart(3, "0");
}

function claimId(
  seen: Map<string, string>,
  id: string,
  source: string,
  issues: string[],
): void {
  const previous = seen.get(id);
  if (previous !== undefined) {
    addIssue(issues, `${source} reuses UUID ${id} from ${previous}`);
  } else {
    seen.set(id, source);
  }
}

function portableRelative(root: string, filePath: string): string {
  return path.relative(root, filePath).split(path.sep).join("/");
}

function isInside(root: string, candidate: string): boolean {
  const relative = path.relative(root, candidate);
  return relative.length > 0 && !relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative);
}

function isJsonObject(value: unknown): value is LegacyJsonObject {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function addIssue(issues: string[], issue: string): void {
  if (issues.length < 100) {
    issues.push(issue);
  }
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function isErrorCode(error: unknown, code: string): boolean {
  return error instanceof Error && "code" in error && String(error.code) === code;
}
