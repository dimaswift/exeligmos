import { createHash, randomUUID } from "node:crypto";
import {
  createReadStream,
  createWriteStream,
} from "node:fs";
import {
  access,
  mkdir,
  readdir,
  rename,
  rm,
  writeFile,
} from "node:fs/promises";
import path from "node:path";
import { pipeline } from "node:stream/promises";
import { Transform } from "node:stream";

import type { QueryResultRow } from "pg";

import type { Database, Queryable } from "../db/database.js";

type ArchiveRow = Readonly<Record<string, unknown>>;

export interface ArchiveUserSnapshot {
  readonly profile: ArchiveRow;
  readonly encryptionProfile?: ArchiveRow;
  readonly devices: readonly ArchiveRow[];
  readonly records: readonly ArchiveRow[];
  readonly recordTags: readonly ArchiveRow[];
  readonly recordMedia: readonly ArchiveRow[];
  readonly media: readonly ArchiveRow[];
  readonly events: readonly ArchiveRow[];
  readonly tags: readonly ArchiveRow[];
  readonly templates: readonly ArchiveRow[];
  readonly subscriptions: readonly ArchiveRow[];
  readonly references: readonly ArchiveRow[];
}

export interface ArchiveSnapshot {
  readonly createdAt: string;
  readonly users: readonly ArchiveUserSnapshot[];
}

export interface ArchiveWriteResult {
  readonly destination: string;
  readonly counts: {
    readonly users: number;
    readonly records: number;
    readonly events: number;
    readonly media: number;
    readonly mediaBytes: number;
  };
}

interface ExplorerMedia {
  readonly id: string;
  readonly fileName: string;
  readonly contentType: string;
  readonly byteSize: string;
  readonly visibility: string;
  readonly encrypted: boolean;
  readonly missing: boolean;
  readonly path?: string;
}

interface ArchiveSarosPhase {
  readonly relation: "closest" | "spike";
  readonly saros: number;
  readonly octalAddress: string;
  readonly harmonicDepth: number;
  readonly rarity?: string;
  readonly unixTimestamp?: number;
  readonly timestamp?: string;
  readonly sequence?: number;
  readonly eclipseType?: string;
}

interface ArchiveSarosInfo {
  readonly closest?: ArchiveSarosPhase;
  readonly nearby: readonly ArchiveSarosPhase[];
  readonly series: readonly number[];
  readonly octalAddresses: readonly string[];
}

interface ExplorerRecord {
  readonly id: string;
  readonly publicId?: string;
  readonly userId: string;
  readonly userLogin: string;
  readonly userDisplayName: string;
  readonly visibility: string;
  readonly deleted: boolean;
  readonly eventAt?: string;
  readonly createdAt: string;
  readonly updatedAt: string;
  readonly emoji: string;
  readonly title: string;
  readonly excerpt: string;
  readonly tags: readonly string[];
  readonly media: readonly ExplorerMedia[];
  readonly saros?: ArchiveSarosInfo;
  readonly path: string;
}

interface ExplorerUser {
  readonly id: string;
  readonly login: string;
  readonly displayName: string;
  readonly recordCount: number;
  readonly eventCount: number;
  readonly mediaCount: number;
}

interface ExplorerData {
  readonly format: "fractonica-readable-archive";
  readonly createdAt: string;
  readonly users: readonly ExplorerUser[];
  readonly records: readonly ExplorerRecord[];
}

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export async function loadArchiveSnapshot(
  database: Database,
  createdAt = new Date().toISOString(),
): Promise<ArchiveSnapshot> {
  return database.transaction(async (client) => {
    await client.query("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY");
    const users = await rows(
      client,
      `SELECT
         id, login, display_name, role, status, saros_anchor, revision,
         created_at, updated_at, disabled_at
       FROM users
       ORDER BY lower(login), id`,
    );
    const snapshots: ArchiveUserSnapshot[] = [];
    for (const profile of users) {
      const userId = requiredString(profile, "id");
      snapshots.push(await loadUserSnapshot(client, profile, userId));
    }
    return { createdAt, users: snapshots };
  });
}

async function loadUserSnapshot(
  client: Queryable,
  profile: ArchiveRow,
  userId: string,
): Promise<ArchiveUserSnapshot> {
  // node-postgres permits only one active query per transaction client. Keep
  // these reads explicitly sequential so future driver changes do not reject
  // the snapshot and so the repeatable-read ordering remains obvious.
  const encryptionProfiles = await rows(
    client,
    `SELECT *
     FROM user_encryption_profiles WHERE user_id = $1`,
    [userId],
  );
  const devices = await rows(
    client,
    "SELECT * FROM devices WHERE user_id = $1 ORDER BY registered_at, id",
    [userId],
  );
  const records = await rows(
    client,
    `SELECT * FROM records
     WHERE user_id = $1
     ORDER BY COALESCE(event_at, created_at), id`,
    [userId],
  );
  const recordTags = await rows(
    client,
    "SELECT * FROM record_tags WHERE user_id = $1 ORDER BY record_id, tag_id",
    [userId],
  );
  const recordMedia = await rows(
    client,
    "SELECT * FROM record_media WHERE user_id = $1 ORDER BY record_id, position, media_id",
    [userId],
  );
  const media = await rows(
    client,
    "SELECT * FROM media_objects WHERE user_id = $1 ORDER BY created_at, id",
    [userId],
  );
  const events = await rows(
    client,
    "SELECT * FROM events WHERE user_id = $1 ORDER BY starts_at, id",
    [userId],
  );
  const tags = await rows(
    client,
    "SELECT * FROM tags WHERE user_id = $1 ORDER BY sort_order, name, id",
    [userId],
  );
  const templates = await rows(
    client,
    "SELECT * FROM templates WHERE user_id = $1 ORDER BY created_at, id",
    [userId],
  );
  const subscriptions = await rows(
    client,
    "SELECT * FROM subscriptions WHERE user_id = $1 ORDER BY created_at, id",
    [userId],
  );
  const references = await rows(
    client,
    `SELECT * FROM resource_references
     WHERE source_user_id = $1 ORDER BY created_at, id`,
    [userId],
  );
  return {
    profile,
    ...(encryptionProfiles[0] === undefined
      ? {}
      : { encryptionProfile: encryptionProfiles[0] }),
    devices,
    records,
    recordTags,
    recordMedia,
    media,
    events,
    tags,
    templates,
    subscriptions,
    references,
  };
}

async function rows(
  client: Queryable,
  query: string,
  values?: readonly unknown[],
): Promise<readonly ArchiveRow[]> {
  const result = await client.query<QueryResultRow>(query, values);
  return result.rows;
}

export async function writeReadableArchive(
  snapshot: ArchiveSnapshot,
  mediaStorageRoot: string,
  destination: string,
): Promise<ArchiveWriteResult> {
  const absoluteDestination = path.resolve(destination);
  await assertDestinationAvailable(absoluteDestination);
  const parent = path.dirname(absoluteDestination);
  await mkdir(parent, { recursive: true });
  const partial = path.join(
    parent,
    `.${path.basename(absoluteDestination)}.partial-${randomUUID()}`,
  );
  await mkdir(partial, { recursive: false, mode: 0o700 });

  try {
    const result = await writeArchiveContents(
      snapshot,
      path.resolve(mediaStorageRoot),
      partial,
    );
    await rename(partial, absoluteDestination);
    return { ...result, destination: absoluteDestination };
  } catch (error) {
    await rm(partial, { recursive: true, force: true });
    throw error;
  }
}

async function writeArchiveContents(
  snapshot: ArchiveSnapshot,
  mediaStorageRoot: string,
  root: string,
): Promise<Omit<ArchiveWriteResult, "destination">> {
  const explorerUsers: ExplorerUser[] = [];
  const explorerRecords: ExplorerRecord[] = [];
  let eventCount = 0;
  let mediaCount = 0;
  let mediaBytes = 0;

  for (const user of snapshot.users) {
    const written = await writeUser(root, mediaStorageRoot, user);
    explorerUsers.push(written.user);
    explorerRecords.push(...written.records);
    eventCount += written.user.eventCount;
    mediaCount += written.user.mediaCount;
    mediaBytes += written.mediaBytes;
  }

  const explorerData: ExplorerData = {
    format: "fractonica-readable-archive",
    createdAt: snapshot.createdAt,
    users: explorerUsers,
    records: explorerRecords.sort(compareExplorerRecords),
  };
  const counts = {
    users: explorerUsers.length,
    records: explorerRecords.length,
    events: eventCount,
    media: mediaCount,
    mediaBytes,
  };
  await writeJson(path.join(root, "manifest.json"), {
    format: "fractonica-readable-archive",
    createdAt: snapshot.createdAt,
    purpose: "human-readable archive; not a server backup",
    contentEncoding: {
      databaseBytea: "base64 object with $encoding and $value fields",
      timestamps: "ISO 8601 strings",
      largeIntegers: "decimal strings",
    },
    excluded:
      "password hashes, refresh sessions, API key hashes, rate limits, idempotency receipts, sync cursors, audit logs, embeddings, and incomplete uploads",
    privateContent:
      "Private records and private media remain A256GCM ciphertext because the server has no decryption keys.",
    counts,
    users: explorerUsers,
  });
  await writeFile(path.join(root, "ARCHIVE.txt"), archiveReadme(snapshot.createdAt), "utf8");
  await writeFile(path.join(root, "index.html"), EXPLORER_HTML, "utf8");
  await writeFile(path.join(root, "app.css"), EXPLORER_CSS, "utf8");
  await writeFile(path.join(root, "app.js"), EXPLORER_JS, "utf8");
  await writeFile(
    path.join(root, "archive-data.js"),
    `globalThis.FRACTONICA_ARCHIVE=${safeScriptJson(explorerData)};\n`,
    "utf8",
  );
  await writeChecksums(root);
  return { counts };
}

async function writeUser(
  archiveRoot: string,
  mediaStorageRoot: string,
  user: ArchiveUserSnapshot,
): Promise<{
  readonly user: ExplorerUser;
  readonly records: readonly ExplorerRecord[];
  readonly mediaBytes: number;
}> {
  const userId = requiredUuid(user.profile, "id");
  const login = requiredString(user.profile, "login");
  const displayName = requiredString(user.profile, "display_name");
  const userRelative = posixJoin("users", `${safeSegment(login)}--${userId}`);
  const userRoot = diskPath(archiveRoot, userRelative);
  await mkdir(userRoot, { recursive: true });
  await writeJson(path.join(userRoot, "profile.json"), user.profile);
  if (user.encryptionProfile !== undefined) {
    await writeJson(
      path.join(userRoot, "encryption-profile.json"),
      user.encryptionProfile,
    );
  }
  await writeJson(path.join(userRoot, "devices.json"), user.devices);
  await writeJson(path.join(userRoot, "subscriptions.json"), user.subscriptions);
  await writeJson(path.join(userRoot, "references.json"), user.references);

  const mediaById = new Map(
    user.media.map((media) => [requiredUuid(media, "id"), media] as const),
  );
  const attachedMediaIds = new Set(
    user.recordMedia.map((join) => requiredUuid(join, "media_id")),
  );
  let copiedMediaBytes = 0;
  const tagsById = new Map(
    user.tags.map((tag) => [requiredUuid(tag, "id"), tag] as const),
  );
  const recordTags = groupBy(user.recordTags, "record_id");
  const recordMedia = groupBy(user.recordMedia, "record_id");
  const references = groupBy(user.references, "source_record_id");
  const explorerRecords: ExplorerRecord[] = [];

  for (const record of user.records) {
    const recordId = requiredUuid(record, "id");
    const date = archiveDate(record.event_at ?? record.created_at);
    const recordRelative = posixJoin(
      userRelative,
      "records",
      date.year,
      date.month,
      date.day,
      recordId,
    );
    const recordRoot = diskPath(archiveRoot, recordRelative);
    await mkdir(recordRoot, { recursive: true });
    const tagRows = (recordTags.get(recordId) ?? [])
      .map((join) => tagsById.get(requiredUuid(join, "tag_id")))
      .filter((tag): tag is ArchiveRow => tag !== undefined);
    const attachments: ArchiveRow[] = [];
    const attachmentRows = recordMedia.get(recordId) ?? [];
    for (const [attachmentIndex, join] of attachmentRows.entries()) {
      const mediaId = requiredUuid(join, "media_id");
      const media = mediaById.get(mediaId);
      if (media === undefined) {
        attachments.push({
          ...join,
          archive_content_path: null,
          archive_content_state: "missing",
          archive_error: "media metadata missing",
        });
        continue;
      }
      const fileName = recordMediaFileName(join, attachmentIndex, media);
      const contentRelative = posixJoin(recordRelative, "media", fileName);
      const ready = stringValue(media.status) === "ready";
      if (ready) {
        copiedMediaBytes += await copyVerifiedMedia(
          mediaStorageRoot,
          requiredString(media, "storage_key"),
          diskPath(archiveRoot, contentRelative),
          media,
        );
      }
      attachments.push({
        ...join,
        media,
        archive_content_path: ready ? posixJoin("media", fileName) : null,
        archive_content_state: ready ? "copied" : "deleted",
      });
    }
    if (attachments.length > 0) {
      await writeJson(path.join(recordRoot, "media", "media.json"), {
        format: "fractonica-readable-record-media",
        record_id: recordId,
        items: attachments,
      });
    }
    const saros = deriveSarosInfo(record);
    await writeJson(path.join(recordRoot, "record.json"), {
      format: "fractonica-readable-record",
      record,
      saros: saros ?? null,
      tags: tagRows,
      media: attachments,
      references: references.get(recordId) ?? [],
    });
    explorerRecords.push(
      explorerRecord(
        record,
        recordRelative,
        login,
        displayName,
        tagRows,
        attachments,
        saros,
      ),
    );
  }

  for (const media of user.media) {
    const mediaId = requiredUuid(media, "id");
    if (attachedMediaIds.has(mediaId)) {
      continue;
    }
    const mediaRelative = posixJoin(userRelative, "unattached-media", mediaId);
    const mediaRoot = diskPath(archiveRoot, mediaRelative);
    await mkdir(mediaRoot, { recursive: true });
    const fileName = safeSegment(requiredString(media, "file_name"));
    const contentRelative = posixJoin(mediaRelative, fileName);
    const ready = stringValue(media.status) === "ready";
    if (ready) {
      copiedMediaBytes += await copyVerifiedMedia(
        mediaStorageRoot,
        requiredString(media, "storage_key"),
        diskPath(archiveRoot, contentRelative),
        media,
      );
    }
    await writeJson(path.join(mediaRoot, "media.json"), {
      ...media,
      archive_content_path: ready ? fileName : null,
      archive_content_state: ready ? "copied" : "deleted",
      archive_note: "This media object was not attached to any archived record.",
    });
  }

  for (const event of user.events) {
    const eventId = requiredUuid(event, "id");
    const date = archiveDate(event.starts_at ?? event.created_at);
    const eventRelative = posixJoin(
      userRelative,
      "events",
      date.year,
      date.month,
      date.day,
      `${eventId}.json`,
    );
    await writeJson(diskPath(archiveRoot, eventRelative), {
      format: "fractonica-readable-event",
      event,
      references: user.references.filter(
        (reference) => stringValue(reference.source_event_id) === eventId,
      ),
    });
  }

  for (const tag of user.tags) {
    await writeJson(
      path.join(userRoot, "tags", `${requiredUuid(tag, "id")}.json`),
      tag,
    );
  }
  for (const template of user.templates) {
    const templateId = requiredUuid(template, "id");
    await writeJson(
      path.join(userRoot, "templates", templateId, "template.json"),
      template,
    );
  }

  return {
    user: {
      id: userId,
      login,
      displayName,
      recordCount: user.records.length,
      eventCount: user.events.length,
      mediaCount: user.media.length,
    },
    records: explorerRecords,
    mediaBytes: copiedMediaBytes,
  };
}

function explorerRecord(
  record: ArchiveRow,
  recordRelative: string,
  userLogin: string,
  userDisplayName: string,
  tags: readonly ArchiveRow[],
  attachments: readonly ArchiveRow[],
  saros: ArchiveSarosInfo | undefined,
): ExplorerRecord {
  const visibility = stringValue(record.visibility) ?? "unknown";
  const encrypted = visibility === "private";
  const publicPayload = objectValue(record.public_payload);
  const title = encrypted
    ? "Encrypted private record"
    : firstText(publicPayload, ["title", "name", "label", "subject"]) ??
      `Record ${stringValue(record.public_id) ?? requiredUuid(record, "id").slice(0, 8)}`;
  const excerpt = encrypted
    ? "Ciphertext preserved. Decrypt with a client that holds the user’s key."
    : firstText(publicPayload, [
        "text",
        "body",
        "note",
        "description",
        "summary",
        "content",
      ]) ?? compactJson(publicPayload);
  const emoji = encrypted
    ? "🔒"
    : firstText(publicPayload, ["emoji", "icon"]) ?? "◇";
  const publicId = stringValue(record.public_id);
  const eventAt = stringValue(record.event_at);
  const media = attachments.map((attachment): ExplorerMedia => {
    const mediaRow = objectValue(attachment.media) ?? {};
    const contentPath = stringValue(attachment.archive_content_path);
    return {
      id: stringValue(mediaRow.id) ?? "unknown",
      fileName: stringValue(mediaRow.file_name) ?? "media",
      contentType: stringValue(mediaRow.content_type) ?? "application/octet-stream",
      byteSize: String(mediaRow.byte_size ?? "0"),
      visibility: stringValue(mediaRow.visibility) ?? "unknown",
      encrypted: stringValue(mediaRow.visibility) === "private",
      missing: contentPath === undefined,
      ...(contentPath === undefined
        ? {}
        : {
            path: path.posix.relative(
              ".",
              path.posix.normalize(posixJoin(recordRelative, contentPath)),
            ),
          }),
    };
  });
  return {
    id: requiredUuid(record, "id"),
    ...(publicId === undefined ? {} : { publicId }),
    userId: requiredUuid(record, "user_id"),
    userLogin,
    userDisplayName,
    visibility,
    deleted: record.deleted_at !== null && record.deleted_at !== undefined,
    ...(eventAt === undefined ? {} : { eventAt }),
    createdAt: requiredString(record, "created_at"),
    updatedAt: requiredString(record, "updated_at"),
    emoji: emoji.slice(0, 16),
    title: title.slice(0, 240),
    excerpt: excerpt.slice(0, 1_000),
    tags: tags.map((tag) => requiredString(tag, "name")),
    media,
    ...(saros === undefined ? {} : { saros }),
    path: posixJoin(recordRelative, "record.json"),
  };
}

async function copyVerifiedMedia(
  mediaStorageRoot: string,
  storageKey: string,
  destination: string,
  media: ArchiveRow,
): Promise<number> {
  const source = safeStoragePath(mediaStorageRoot, storageKey);
  await mkdir(path.dirname(destination), { recursive: true });
  const digest = createHash("sha256");
  let actualBytes = 0;
  const verifier = new Transform({
    transform(chunk: Buffer, _encoding, callback) {
      actualBytes += chunk.byteLength;
      digest.update(chunk);
      callback(null, chunk);
    },
  });
  try {
    await pipeline(createReadStream(source), verifier, createWriteStream(destination, {
      flags: "wx",
      mode: 0o600,
    }));
  } catch (error) {
    await rm(destination, { force: true });
    throw new Error(`Unable to copy archive media ${storageKey}`, { cause: error });
  }
  const expectedBytes = integerValue(media.byte_size, "byte_size");
  const expectedSha = bufferHex(media.sha256, "sha256");
  const actualSha = digest.digest("hex");
  if (actualBytes !== expectedBytes || actualSha !== expectedSha) {
    await rm(destination, { force: true });
    throw new Error(
      `Archive media integrity mismatch for ${storageKey}: ` +
        `expected ${expectedBytes}/${expectedSha}, got ${actualBytes}/${actualSha}`,
    );
  }
  return actualBytes;
}

function safeStoragePath(root: string, storageKey: string): string {
  if (
    storageKey.includes("\\") ||
    path.posix.isAbsolute(storageKey) ||
    storageKey.split("/").some((segment) => segment.length === 0 || segment === "..")
  ) {
    throw new Error(`Unsafe media storage key: ${storageKey}`);
  }
  const resolved = path.resolve(root, ...storageKey.split("/"));
  const relative = path.relative(root, resolved);
  if (relative.startsWith("..") || path.isAbsolute(relative)) {
    throw new Error(`Media storage key escapes storage root: ${storageKey}`);
  }
  return resolved;
}

async function assertDestinationAvailable(destination: string): Promise<void> {
  try {
    await access(destination);
  } catch {
    return;
  }
  throw new Error(`Archive destination already exists: ${destination}`);
}

function recordMediaFileName(
  join: ArchiveRow,
  attachmentIndex: number,
  media: ArchiveRow,
): string {
  const rawPosition = numericValue(join.position);
  const position =
    rawPosition !== undefined && Number.isSafeInteger(rawPosition) && rawPosition >= 0
      ? rawPosition + 1
      : attachmentIndex + 1;
  return `${String(position).padStart(2, "0")}--${safeSegment(
    requiredString(media, "file_name"),
  )}`;
}

function archiveDate(value: unknown): {
  readonly year: string;
  readonly month: string;
  readonly day: string;
} {
  const date = new Date(String(value));
  if (!Number.isFinite(date.getTime())) {
    return { year: "undated", month: "00", day: "00" };
  }
  const [year = "undated", month = "00", day = "00"] = date
    .toISOString()
    .slice(0, 10)
    .split("-");
  return { year, month, day };
}

function groupBy(
  values: readonly ArchiveRow[],
  key: string,
): ReadonlyMap<string, readonly ArchiveRow[]> {
  const groups = new Map<string, ArchiveRow[]>();
  for (const value of values) {
    const groupKey = stringValue(value[key]);
    if (groupKey === undefined) {
      continue;
    }
    const existing = groups.get(groupKey);
    if (existing === undefined) {
      groups.set(groupKey, [value]);
    } else {
      existing.push(value);
    }
  }
  return groups;
}

function compareExplorerRecords(left: ExplorerRecord, right: ExplorerRecord): number {
  const leftDate = left.eventAt ?? left.createdAt;
  const rightDate = right.eventAt ?? right.createdAt;
  return rightDate.localeCompare(leftDate) || left.id.localeCompare(right.id);
}

async function writeJson(filePath: string, value: unknown): Promise<void> {
  await mkdir(path.dirname(filePath), { recursive: true });
  await writeFile(filePath, `${JSON.stringify(toPlainValue(value), null, 2)}\n`, "utf8");
}

function toPlainValue(value: unknown): unknown {
  if (Buffer.isBuffer(value)) {
    return { $encoding: "base64", $value: value.toString("base64") };
  }
  if (value instanceof Date) {
    return value.toISOString();
  }
  if (Array.isArray(value)) {
    return value.map(toPlainValue);
  }
  if (value !== null && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value).map(([key, nested]) => [key, toPlainValue(nested)]),
    );
  }
  return value;
}

async function writeChecksums(root: string): Promise<void> {
  const files = (await listFiles(root))
    .filter((file) => file !== "SHA256SUMS")
    .sort((left, right) => left.localeCompare(right));
  const lines: string[] = [];
  for (const file of files) {
    lines.push(`${await fileSha256(diskPath(root, file))}  ${file}`);
  }
  await writeFile(path.join(root, "SHA256SUMS"), `${lines.join("\n")}\n`, "utf8");
}

async function listFiles(root: string, relative = ""): Promise<string[]> {
  const entries = await readdir(diskPath(root, relative), { withFileTypes: true });
  const files: string[] = [];
  for (const entry of entries) {
    const child = posixJoin(relative, entry.name);
    if (entry.isDirectory()) {
      files.push(...(await listFiles(root, child)));
    } else if (entry.isFile()) {
      files.push(child);
    }
  }
  return files;
}

async function fileSha256(filePath: string): Promise<string> {
  const digest = createHash("sha256");
  for await (const chunk of createReadStream(filePath)) {
    digest.update(chunk);
  }
  return digest.digest("hex");
}

function safeSegment(value: string): string {
  const normalized = value
    .normalize("NFKC")
    .replace(/[^A-Za-z0-9._-]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 120);
  return normalized.length === 0 ? "item" : normalized;
}

function diskPath(root: string, relative: string): string {
  return path.join(root, ...relative.split("/").filter(Boolean));
}

function posixJoin(...parts: string[]): string {
  return path.posix.join(...parts.filter((part) => part.length > 0));
}

function requiredString(row: ArchiveRow, key: string): string {
  const value = stringValue(row[key]);
  if (value === undefined || value.length === 0) {
    throw new Error(`Archive row is missing ${key}`);
  }
  return value;
}

function requiredUuid(row: ArchiveRow, key: string): string {
  const value = requiredString(row, key);
  if (!UUID_PATTERN.test(value)) {
    throw new Error(`Archive row has invalid ${key}: ${value}`);
  }
  return value.toLowerCase();
}

function stringValue(value: unknown): string | undefined {
  if (typeof value === "string") {
    return value;
  }
  if (value instanceof Date) {
    return value.toISOString();
  }
  return undefined;
}

function objectValue(value: unknown): ArchiveRow | undefined {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? (value as ArchiveRow)
    : undefined;
}

function numericValue(value: unknown): number | undefined {
  if (typeof value === "number" && Number.isFinite(value)) {
    return value;
  }
  if (typeof value === "string" && value.trim().length > 0) {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : undefined;
  }
  return undefined;
}

function deriveSarosInfo(record: ArchiveRow): ArchiveSarosInfo | undefined {
  const payload = objectValue(record.public_payload);
  const context = objectValue(payload?.context);
  if (context === undefined) {
    return undefined;
  }
  const closest = sarosPhase(objectValue(context.closestSarosPhase), "closest");
  const spikes = Array.isArray(context.spikes)
    ? context.spikes
        .map((spike) => sarosPhase(objectValue(spike), "spike"))
        .filter((phase): phase is ArchiveSarosPhase => phase !== undefined)
    : [];
  if (closest === undefined && spikes.length === 0) {
    return undefined;
  }
  const phases = closest === undefined ? spikes : [closest, ...spikes];
  return {
    ...(closest === undefined ? {} : { closest }),
    nearby: spikes,
    series: [...new Set(phases.map((phase) => phase.saros))].sort(
      (left, right) => left - right,
    ),
    octalAddresses: [...new Set(phases.map((phase) => phase.octalAddress))],
  };
}

function sarosPhase(
  value: ArchiveRow | undefined,
  relation: ArchiveSarosPhase["relation"],
): ArchiveSarosPhase | undefined {
  if (value === undefined) {
    return undefined;
  }
  const saros = numericValue(value.saros);
  const harmonicDepth = numericValue(value.harmonicDepth);
  const octalAddress = canonicalOctalAddress(value.octalAddress, harmonicDepth);
  if (
    saros === undefined ||
    !Number.isSafeInteger(saros) ||
    saros <= 0 ||
    harmonicDepth === undefined ||
    !Number.isSafeInteger(harmonicDepth) ||
    octalAddress === undefined
  ) {
    return undefined;
  }
  const rarity = stringValue(value.rarityRawValue);
  const unixTimestamp = numericValue(value.unixTimestamp);
  const sequence = numericValue(value.sarosSequence);
  const eclipseType = stringValue(value.eclipseTypeRawValue);
  const timestamp =
    unixTimestamp === undefined || !Number.isSafeInteger(unixTimestamp)
      ? undefined
      : new Date(unixTimestamp * 1_000).toISOString();
  return {
    relation,
    saros,
    octalAddress,
    harmonicDepth,
    ...(rarity === undefined ? {} : { rarity }),
    ...(unixTimestamp === undefined || !Number.isSafeInteger(unixTimestamp)
      ? {}
      : { unixTimestamp }),
    ...(timestamp === undefined ? {} : { timestamp }),
    ...(sequence === undefined || !Number.isSafeInteger(sequence)
      ? {}
      : { sequence }),
    ...(eclipseType === undefined ? {} : { eclipseType }),
  };
}

function canonicalOctalAddress(
  value: unknown,
  harmonicDepth: number | undefined,
): string | undefined {
  const digits =
    typeof value === "string"
      ? [...value].filter((digit) => "01234567".includes(digit)).join("")
      : "";
  if (digits.length === 0) {
    return undefined;
  }
  const depth =
    harmonicDepth !== undefined && Number.isSafeInteger(harmonicDepth)
      ? Math.min(Math.max(harmonicDepth, 1), 8)
      : Math.min(digits.length, 8);
  return digits
    .slice(0, Math.min(depth, 8))
    .padEnd(8, "0")
    .slice(0, 8);
}

function integerValue(value: unknown, field: string): number {
  const parsed =
    typeof value === "number" ? value : typeof value === "string" ? Number(value) : NaN;
  if (!Number.isSafeInteger(parsed) || parsed < 0) {
    throw new Error(`Archive media has invalid ${field}`);
  }
  return parsed;
}

function bufferHex(value: unknown, field: string): string {
  if (Buffer.isBuffer(value)) {
    return value.toString("hex");
  }
  if (typeof value === "string") {
    const normalized = value.startsWith("\\x") ? value.slice(2) : value;
    if (/^[0-9a-f]{64}$/i.test(normalized)) {
      return normalized.toLowerCase();
    }
  }
  throw new Error(`Archive media has invalid ${field}`);
}

function firstText(
  value: ArchiveRow | undefined,
  keys: readonly string[],
): string | undefined {
  for (const key of keys) {
    const candidate = value?.[key];
    if (typeof candidate === "string" && candidate.trim().length > 0) {
      return candidate.trim().replace(/\s+/g, " ");
    }
  }
  return undefined;
}

function compactJson(value: unknown): string {
  if (value === null || value === undefined) {
    return "No public payload.";
  }
  const compact = JSON.stringify(value);
  return compact.length === 0 ? "No public payload." : compact;
}

function safeScriptJson(value: unknown): string {
  return JSON.stringify(toPlainValue(value))
    .replaceAll("<", "\\u003c")
    .replaceAll("\u2028", "\\u2028")
    .replaceAll("\u2029", "\\u2029");
}

function archiveReadme(createdAt: string): string {
  return `FRACTONICA READABLE ARCHIVE
Created: ${createdAt}

This is a human-readable archive, not a server backup. It deliberately omits
password hashes, sessions, API-key hashes, rate-limit state, audit rows, sync
receipts, embeddings, and incomplete uploads.

Browse without an application:
  1. Open index.html directly, or
  2. Run any static file server in this directory and open its root URL.

For example:
  python3 -m http.server 8000
  open http://localhost:8000/

Folder layout:
  users/<login>--<user-id>/records/YYYY/MM/DD/<record-id>/record.json
  users/<login>--<user-id>/records/YYYY/MM/DD/<record-id>/media/
  users/<login>--<user-id>/events/YYYY/MM/DD/<event-id>.json
  users/<login>--<user-id>/unattached-media/<media-id>/<original-file-name>
  users/<login>--<user-id>/tags/
  users/<login>--<user-id>/templates/

Each record's media is copied into that record's own media folder. Media that
is not attached to any record is retained separately under unattached-media.
Stored Saros context is included in record.json and indexed by the explorer as
series numbers plus canonical 8-digit octal phases.

Private records and private media remain encrypted ciphertext. The server never
has the user's decryption key. Use SHA256SUMS to verify every archived file.
`;
}

const EXPLORER_HTML = `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="color-scheme" content="light dark">
  <title>Fractonica archive</title>
  <link rel="stylesheet" href="app.css">
</head>
<body>
  <header class="masthead">
    <div class="brand">
      <span class="brand-mark" aria-hidden="true">⌁</span>
      <div>
        <p class="eyebrow">FRACTONICA</p>
        <h1>Readable archive</h1>
      </div>
    </div>
    <div class="archive-summary">
      <p id="archive-meta" class="muted"></p>
      <a class="manifest-link" href="manifest.json">Manifest</a>
    </div>
  </header>
  <main class="layout">
    <aside class="sidebar" aria-label="Archive filters">
      <p class="pane-kicker">FILTERS</p>
      <label class="search-label" for="search">Search records</label>
      <input id="search" type="search" placeholder="Text, Saros 141, 01234567…" autocomplete="off">
      <fieldset>
        <legend>People</legend>
        <div id="user-filters"></div>
      </fieldset>
      <fieldset>
        <label class="search-label" for="saros-filter">Saros series</label>
        <select id="saros-filter">
          <option value="all">All Saros series</option>
        </select>
        <p class="filter-note">Matches the closest or any nearby Saros phase stored with a record.</p>
      </fieldset>
      <fieldset>
        <legend>Content</legend>
        <label><input id="include-private" type="checkbox" checked> Private ciphertext</label>
        <label><input id="include-deleted" type="checkbox"> Deleted records</label>
      </fieldset>
    </aside>
    <section class="records-pane" aria-label="Records">
      <div class="pane-heading">
        <div>
          <p class="pane-kicker">BROWSE</p>
          <h2>Records</h2>
        </div>
        <p id="result-count" class="result-count" aria-live="polite"></p>
      </div>
      <div id="record-list" class="record-list"></div>
      <p id="empty-state" class="empty-state" hidden>No records match these filters.</p>
    </section>
    <section id="detail" class="detail-pane" aria-label="Selected record">
      <div class="detail-placeholder">Select a record to inspect its plain data and media.</div>
    </section>
  </main>
  <script src="archive-data.js"></script>
  <script src="app.js"></script>
</body>
</html>
`;

const EXPLORER_CSS = `:root {
  color-scheme: dark;
  --paper: #080d11;
  --panel: #0d1318;
  --raised: #141b21;
  --raised-hover: #192229;
  --ink: #f4f6f8;
  --muted: #9ba7b7;
  --line: #2d3741;
  --line-soft: #202a32;
  --mint: #9effdf;
  --mint-soft: rgba(158, 255, 223, .09);
  --gold: #f4c86a;
  --gold-soft: rgba(244, 200, 106, .1);
  --purple: #c879ff;
  --shadow: 0 16px 40px rgba(0, 0, 0, .3);
  font-family: Inter, ui-sans-serif, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
}
* { box-sizing: border-box; }
html, body { height: 100%; }
body { margin: 0; overflow: hidden; background: var(--paper); color: var(--ink); }
button, input, select { font: inherit; }
button, a, input, select { outline-color: var(--gold); }
.masthead {
  height: 94px; padding: 16px 24px;
  display: flex; align-items: center; justify-content: space-between; gap: 24px;
  border-bottom: 1px solid var(--line);
  background: #090f14;
}
.brand { display: flex; align-items: center; gap: 14px; }
.brand-mark {
  display: grid; place-items: center; width: 44px; height: 44px;
  border: 1px solid var(--line); border-radius: 12px;
  color: var(--mint); font: 700 29px/1 ui-monospace, monospace;
}
.eyebrow, .pane-kicker, .muted, .result-count { color: var(--muted); }
.eyebrow, .pane-kicker {
  margin: 0; font: 700 11px/1.2 ui-monospace, SFMono-Regular, Menlo, monospace;
  letter-spacing: .16em;
}
h1 { margin: 4px 0 0; font-size: 25px; line-height: 1; letter-spacing: -.02em; }
.archive-summary { display: flex; align-items: center; gap: 18px; min-width: 0; }
.archive-summary p { margin: 0; font-size: 12px; }
.manifest-link {
  padding: 8px 11px; border: 1px solid var(--line); border-radius: 8px;
  color: var(--ink); text-decoration: none; font-size: 12px;
}
.manifest-link:hover { border-color: var(--mint); color: var(--mint); }
.layout {
  height: calc(100dvh - 94px); overflow: hidden;
  display: grid; grid-template-columns: minmax(190px, 230px) minmax(300px, 390px) minmax(400px, 1fr);
}
.sidebar, .records-pane, .detail-pane {
  min-width: 0; min-height: 0; overflow-y: auto; overscroll-behavior: contain;
  scrollbar-color: var(--line) transparent;
}
.sidebar, .records-pane { border-right: 1px solid var(--line); }
.sidebar { padding: 18px; background: #0a1015; }
.sidebar > .pane-kicker { margin-bottom: 20px; }
.search-label, legend {
  display: block; margin-bottom: 7px; color: var(--muted);
  font: 700 10px/1.2 ui-monospace, SFMono-Regular, Menlo, monospace;
  letter-spacing: .12em; text-transform: uppercase;
}
#search, #saros-filter {
  width: 100%; padding: 10px 11px; border: 1px solid var(--line); border-radius: 8px;
  background: var(--panel); color: var(--ink); font-size: 12px;
}
#search:focus, #saros-filter:focus { border-color: var(--gold); }
.filter-note { margin: 7px 0 0; color: var(--muted); font-size: 10px; line-height: 1.4; }
fieldset { margin: 18px 0; padding: 0; border: 0; }
fieldset label {
  display: flex; gap: 8px; margin: 8px 0; align-items: center;
  color: var(--muted); font-size: 12px; line-height: 1.3;
}
input[type="checkbox"] { accent-color: var(--mint); }
.user-button {
  width: 100%; margin: 2px 0; padding: 8px 9px; border: 1px solid transparent;
  border-radius: 7px; background: transparent; color: var(--muted);
  text-align: left; cursor: pointer; font-size: 12px;
}
.user-button:hover { color: var(--ink); background: var(--raised); }
.user-button[aria-pressed="true"] {
  border-color: var(--gold); background: var(--mint-soft); color: var(--mint);
  box-shadow: inset 3px 0 0 var(--gold);
}
.records-pane { padding: 0; background: var(--panel); }
.pane-heading {
  position: sticky; top: 0; z-index: 2; min-height: 67px; padding: 13px 14px;
  display: flex; align-items: flex-end; justify-content: space-between; gap: 14px;
  border-bottom: 1px solid var(--line); background: rgba(13, 19, 24, .96);
  backdrop-filter: blur(12px);
}
.pane-heading h2 { margin: 3px 0 0; font-size: 20px; line-height: 1; }
.result-count { margin: 0; font: 11px/1.2 ui-monospace, monospace; white-space: nowrap; }
.record-list { display: grid; gap: 6px; padding: 8px; }
.record-card {
  width: 100%; padding: 10px; border: 1px solid var(--line-soft); border-radius: 9px;
  display: grid; grid-template-columns: 42px minmax(0, 1fr); gap: 10px;
  background: var(--raised); color: var(--ink); text-align: left; cursor: pointer;
}
.record-card:hover { border-color: var(--mint); background: var(--raised-hover); }
.record-card[aria-current="true"] {
  border-color: var(--gold); background: var(--gold-soft); box-shadow: inset 3px 0 0 var(--gold);
}
.record-emoji {
  display: grid; place-items: center; width: 42px; height: 42px;
  border: 1px solid var(--line); border-radius: 10px; background: var(--paper);
  font-size: 25px; line-height: 1;
}
.record-copy { min-width: 0; }
.record-card h2 {
  margin: 7px 0 4px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
  font-size: 14px; line-height: 1.2;
}
.record-card p {
  margin: 0; color: var(--muted); font-size: 12px; line-height: 1.35;
  overflow: hidden; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical;
}
.record-card .record-date { margin-top: 6px; font: 10px/1.2 ui-monospace, monospace; }
.record-meta, .chips { display: flex; flex-wrap: wrap; gap: 4px; }
.chip {
  padding: 2px 5px; border: 1px solid var(--line); border-radius: 4px;
  background: var(--paper); color: var(--muted);
  font: 9px/1.25 ui-monospace, SFMono-Regular, Menlo, monospace;
}
.chip.saros { border-color: rgba(158,255,223,.32); color: var(--mint); }
.chip.private { border-color: rgba(200,121,255,.35); color: var(--purple); }
.detail-pane {
  padding: 22px clamp(18px, 3vw, 40px) 60px; background: var(--paper);
  overflow-wrap: anywhere;
}
.detail-heading {
  display: grid; grid-template-columns: 58px minmax(0, 1fr); gap: 15px;
  align-items: start; padding-bottom: 18px; border-bottom: 1px solid var(--line);
}
.detail-emoji {
  display: grid; place-items: center; width: 58px; height: 58px;
  border: 1px solid var(--line); border-radius: 14px; background: var(--raised);
  font-size: 35px; line-height: 1;
}
.detail-pane h2 { margin: 7px 0 6px; font-size: clamp(24px, 2.5vw, 36px); line-height: 1.05; letter-spacing: -.03em; }
.detail-heading .muted { margin: 0; font-size: 14px; line-height: 1.45; }
.detail-placeholder, .empty-state { color: var(--muted); padding: 40px 12px; text-align: center; }
.detail-grid {
  display: grid; grid-template-columns: repeat(4, minmax(0, 1fr));
  gap: 7px; margin: 16px 0;
}
.datum { min-width: 0; padding: 9px; border: 1px solid var(--line); border-radius: 7px; background: var(--panel); }
.datum dt { color: var(--muted); font: 9px/1.2 ui-monospace, monospace; text-transform: uppercase; }
.datum dd { margin: 4px 0 0; overflow: hidden; text-overflow: ellipsis; font-size: 11px; white-space: nowrap; }
.detail-actions { display: flex; flex-wrap: wrap; gap: 8px; margin: 12px 0 16px; }
.action {
  display: inline-block; padding: 7px 9px; border: 1px solid var(--line);
  border-radius: 6px; color: var(--ink); text-decoration: none; font-size: 11px;
}
.action:hover { border-color: var(--mint); color: var(--mint); }
.saros-panel {
  margin: 16px 0; padding: 14px; border: 1px solid var(--line); border-radius: 10px;
  background: linear-gradient(135deg, var(--mint-soft), transparent 70%);
}
.saros-panel h3 { margin: 0 0 10px; font-size: 13px; }
.saros-primary { display: flex; flex-wrap: wrap; gap: 12px; align-items: baseline; }
.saros-series { color: var(--mint); font-size: 14px; font-weight: 800; }
.octal-phase { font: 700 clamp(21px, 3vw, 32px)/1 ui-monospace, monospace; letter-spacing: .1em; font-variant-numeric: tabular-nums; }
.saros-panel > .muted { margin: 7px 0 0; font-size: 11px; }
.saros-nearby {
  display: grid; grid-template-columns: repeat(auto-fit, minmax(145px, 1fr));
  gap: 6px; margin: 10px 0 0; padding: 0; list-style: none;
}
.saros-nearby li {
  display: grid; grid-template-columns: auto 1fr; gap: 3px 8px;
  padding: 7px; border: 1px solid var(--line); border-radius: 6px; font-size: 11px;
}
.saros-nearby li .muted { grid-column: 1 / -1; font-size: 9px; }
.media-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 8px; }
.media-card { padding: 8px; border: 1px solid var(--line); border-radius: 8px; background: var(--panel); }
.media-card img, .media-card video { width: 100%; max-height: 210px; object-fit: contain; border-radius: 5px; background: #030609; }
.media-card audio { width: 100%; }
.media-name { margin: 7px 0 3px; font-size: 11px; font-weight: 700; }
.media-card .muted { margin: 0 0 7px; font-size: 9px; }
@media (max-width: 1080px) {
  .layout { grid-template-columns: 200px 320px minmax(360px, 1fr); }
  .detail-grid { grid-template-columns: repeat(2, minmax(0, 1fr)); }
}
@media (max-width: 820px) {
  body { overflow: auto; }
  .masthead { height: auto; min-height: 84px; padding: 14px 16px; }
  .archive-summary p { display: none; }
  .layout { height: auto; min-height: calc(100dvh - 84px); grid-template-columns: 180px minmax(0, 1fr); overflow: visible; }
  .sidebar { position: sticky; top: 0; height: 100dvh; }
  .records-pane { max-height: 58dvh; }
  .detail-pane { grid-column: 2; overflow: visible; border-top: 1px solid var(--line); }
}
@media (max-width: 580px) {
  .masthead { align-items: flex-start; }
  .brand-mark { width: 38px; height: 38px; }
  h1 { font-size: 20px; }
  .layout { display: block; }
  .sidebar { position: static; width: auto; height: auto; }
  .records-pane { max-height: 62dvh; border: 0; }
  .detail-pane { padding: 18px 14px 50px; }
  .detail-heading { grid-template-columns: 48px minmax(0, 1fr); }
  .detail-emoji { width: 48px; height: 48px; font-size: 28px; }
  .detail-grid { grid-template-columns: 1fr 1fr; }
}
`;

const EXPLORER_JS = `(() => {
  "use strict";
  const data = globalThis.FRACTONICA_ARCHIVE;
  if (!data) return;
  const state = { userId: "all", saros: "all", selectedId: null };
  const search = document.querySelector("#search");
  const sarosFilter = document.querySelector("#saros-filter");
  const includePrivate = document.querySelector("#include-private");
  const includeDeleted = document.querySelector("#include-deleted");
  const list = document.querySelector("#record-list");
  const detail = document.querySelector("#detail");
  const empty = document.querySelector("#empty-state");
  const count = document.querySelector("#result-count");
  const filters = document.querySelector("#user-filters");
  document.querySelector("#archive-meta").textContent =
    new Date(data.createdAt).toLocaleString() + " · " +
    data.users.length + " people · " + data.records.length + " records";

  function node(tag, className, text) {
    const value = document.createElement(tag);
    if (className) value.className = className;
    if (text !== undefined) value.textContent = text;
    return value;
  }
  function userButton(id, label, total) {
    const button = node("button", "user-button", label + " · " + total);
    button.type = "button";
    button.dataset.userId = id;
    button.setAttribute("aria-pressed", String(state.userId === id));
    button.addEventListener("click", () => {
      state.userId = id;
      filters.querySelectorAll("button").forEach((item) =>
        item.setAttribute("aria-pressed", String(item.dataset.userId === id)));
      render();
    });
    return button;
  }
  filters.append(userButton("all", "Everyone", data.records.length));
  data.users.forEach((user) =>
    filters.append(userButton(user.id, user.displayName, user.recordCount)));
  const sarosCounts = new Map();
  data.records.forEach((record) => {
    (record.saros?.series || []).forEach((series) =>
      sarosCounts.set(series, (sarosCounts.get(series) || 0) + 1));
  });
  [...sarosCounts.keys()].sort((a, b) => a - b).forEach((series) => {
    const option = node("option", "", "Saros " + series + " · " + sarosCounts.get(series));
    option.value = String(series);
    sarosFilter.append(option);
  });

  function filteredRecords() {
    const term = search.value.trim().toLocaleLowerCase();
    return data.records.filter((record) => {
      if (state.userId !== "all" && record.userId !== state.userId) return false;
      if (state.saros !== "all" &&
          !(record.saros?.series || []).includes(Number(state.saros))) return false;
      if (!includePrivate.checked && record.visibility === "private") return false;
      if (!includeDeleted.checked && record.deleted) return false;
      if (!term) return true;
      const sarosTerms = record.saros ? [
        ...record.saros.series.map((series) => "saros " + series + " " + series),
        ...record.saros.octalAddresses,
        ...(record.saros.nearby || []).flatMap((phase) =>
          [phase.rarity || "", phase.eclipseType || ""])
      ] : [];
      return [
        record.title, record.excerpt, record.userLogin, record.userDisplayName,
        record.emoji, record.publicId || "", record.id, ...record.tags, ...sarosTerms
      ].join(" ").toLocaleLowerCase().includes(term);
    });
  }
  function chip(text, variant) {
    return node("span", "chip" + (variant ? " " + variant : ""), text);
  }
  function render() {
    const records = filteredRecords();
    let selected = records.find((record) => record.id === state.selectedId);
    if (!selected && records.length) {
      selected = records[0];
      state.selectedId = selected.id;
      history.replaceState(null, "", "#record=" + encodeURIComponent(selected.id));
    }
    list.replaceChildren();
    count.textContent = records.length + (records.length === 1 ? " record" : " records");
    empty.hidden = records.length !== 0;
    records.forEach((record) => {
      const button = node("button", "record-card");
      button.type = "button";
      button.setAttribute("aria-current", String(state.selectedId === record.id));
      const emoji = node("span", "record-emoji", record.emoji);
      emoji.setAttribute("aria-hidden", "true");
      const copy = node("div", "record-copy");
      const meta = node("div", "record-meta");
      meta.append(chip(record.userLogin));
      meta.append(chip(record.visibility, record.visibility === "private" ? "private" : ""));
      if (record.saros?.closest) {
        meta.append(chip(
          "Saros " + record.saros.closest.saros + " · " + record.saros.closest.octalAddress,
          "saros"
        ));
      } else if (record.saros?.series?.length) {
        meta.append(chip("Saros " + record.saros.series.join(", "), "saros"));
      }
      if (record.deleted) meta.append(chip("deleted"));
      copy.append(meta, node("h2", "", record.title), node("p", "", record.excerpt));
      const date = node("p", "muted record-date",
        new Date(record.eventAt || record.createdAt).toLocaleString());
      copy.append(date);
      button.append(emoji, copy);
      button.addEventListener("click", () => selectRecord(record));
      list.append(button);
    });
    if (selected) {
      renderDetail(selected);
    } else {
      detail.replaceChildren(
        node("p", "eyebrow", "NO MATCH SELECTED"),
        node("h2", "", "Adjust the filters to view a record.")
      );
    }
  }
  function datum(label, value) {
    const wrapper = node("div", "datum");
    const term = node("dt", "", label);
    const description = node("dd", "", value);
    wrapper.append(term, description);
    return wrapper;
  }
  function selectRecord(record) {
    state.selectedId = record.id;
    history.replaceState(null, "", "#record=" + encodeURIComponent(record.id));
    render();
    renderDetail(record);
    if (window.matchMedia("(max-width: 1000px)").matches) {
      detail.scrollIntoView({ behavior: "smooth", block: "start" });
    }
  }
  function renderDetail(record) {
    detail.replaceChildren();
    const chips = node("div", "chips");
    chips.append(chip(record.userDisplayName));
    chips.append(chip(record.visibility, record.visibility === "private" ? "private" : ""));
    record.tags.forEach((tag) => chips.append(chip(tag)));
    const heading = node("div", "detail-heading");
    const emoji = node("span", "detail-emoji", record.emoji);
    emoji.setAttribute("aria-hidden", "true");
    const headingCopy = node("div");
    headingCopy.append(chips, node("h2", "", record.title), node("p", "muted", record.excerpt));
    heading.append(emoji, headingCopy);
    detail.append(heading);
    const grid = node("dl", "detail-grid");
    grid.append(
      datum("Event", new Date(record.eventAt || record.createdAt).toLocaleString()),
      datum("Updated", new Date(record.updatedAt).toLocaleString()),
      datum("Record ID", record.id),
      datum("Public ID", record.publicId || "—")
    );
    detail.append(grid);
    const actions = node("div", "detail-actions");
    const json = node("a", "action", "Open record.json");
    json.href = record.path;
    actions.append(json);
    detail.append(actions);
    if (record.saros) {
      const sarosPanel = node("section", "saros-panel");
      sarosPanel.append(node("h3", "", "Saros context"));
      if (record.saros.closest) {
        const primary = node("div", "saros-primary");
        primary.append(
          node("span", "saros-series", "Saros " + record.saros.closest.saros),
          node("span", "octal-phase", record.saros.closest.octalAddress)
        );
        sarosPanel.append(primary);
        sarosPanel.append(node("p", "muted",
          "Closest stored phase · depth " + record.saros.closest.harmonicDepth +
          (record.saros.closest.rarity ? " · " + record.saros.closest.rarity : "")));
      } else {
        sarosPanel.append(node("p", "muted",
          "This record has nearby Saros phases but no stored closest-phase reading."));
      }
      if (record.saros.nearby.length) {
        const heading = node("p", "eyebrow", "NEARBY PHASES");
        const nearby = node("ul", "saros-nearby");
        record.saros.nearby.forEach((phase) => {
          const item = node("li");
          item.append(
            node("span", "", "Saros " + phase.saros),
            node("span", "", phase.octalAddress),
            node("span", "muted", phase.rarity || phase.eclipseType || "Spike")
          );
          nearby.append(item);
        });
        sarosPanel.append(heading, nearby);
      }
      detail.append(sarosPanel);
    }
    if (record.media.length) {
      detail.append(node("h3", "", "Media"));
      const mediaGrid = node("div", "media-grid");
      record.media.forEach((media) => {
        const card = node("article", "media-card");
        if (media.path && !media.encrypted && media.contentType.startsWith("image/")) {
          const image = node("img");
          image.src = media.path; image.alt = media.fileName; image.loading = "lazy";
          card.append(image);
        } else if (media.path && !media.encrypted && media.contentType.startsWith("video/")) {
          const video = node("video"); video.src = media.path; video.controls = true;
          card.append(video);
        } else if (media.path && !media.encrypted && media.contentType.startsWith("audio/")) {
          const audio = node("audio"); audio.src = media.path; audio.controls = true;
          card.append(audio);
        }
        card.append(node("p", "media-name", media.fileName));
        card.append(node("p", "muted",
          media.contentType + " · " + Number(media.byteSize).toLocaleString() + " bytes"));
        if (media.path) {
          const link = node("a", "action", media.encrypted ? "Download ciphertext" : "Open media");
          link.href = media.path; card.append(link);
        } else {
          card.append(node("p", "muted", "No archived bytes (deleted or missing)."));
        }
        mediaGrid.append(card);
      });
      detail.append(mediaGrid);
    }
  }
  sarosFilter.addEventListener("change", () => {
    state.saros = sarosFilter.value;
    render();
  });
  [search, includePrivate, includeDeleted].forEach((input) =>
    input.addEventListener("input", render));
  const hashId = new URLSearchParams(location.hash.replace(/^#/, "")).get("record");
  const initial = data.records.find((record) => record.id === hashId) || data.records[0];
  if (initial) { state.selectedId = initial.id; render(); renderDetail(initial); }
  else render();
})();
`;
