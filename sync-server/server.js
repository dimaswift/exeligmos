import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import fs from 'node:fs/promises';
import { createReadStream } from 'node:fs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const DATA_DIR = process.env.EXELIGMOS_SYNC_DATA || path.join(__dirname, 'data');
const PORT = Number(process.env.PORT || 8787);
const MAX_BODY_BYTES = Number(process.env.MAX_BODY_BYTES || 2 * 1024 * 1024 * 1024);
const OCTAL_GLYPH_BUNDLE =
  process.env.OCTAL_GLYPH_BUNDLE ||
  '/Users/dimas/projects/octal-glyph-gen/octal-glyph.js';
const ANIMACY_RARITIES = ['common', 'rare', 'epic', 'legendary', 'mythic'];
const DEFAULT_HARMONIC_DEPTH = 7;
const MIN_HARMONIC_DEPTH = 3;
const MAX_HARMONIC_DEPTH = 8;
const RARITY_DIGIT_PREFIXES = {
  1: 'Alpha',
  2: 'Beta',
  3: 'Gamma',
  4: 'Delta',
  5: 'Epsilon',
  6: 'Digamma',
  7: 'Omega'
};
const RARITY_BASES = {
  rare: { key: 'rare', title: 'Triplex', order: 3, wildcardPrefixCount: 3, color: '#f3f5f7' },
  epic: { key: 'epic', title: 'Duplex', order: 4, wildcardPrefixCount: 2, color: '#2f9bff' },
  legendary: { key: 'legendary', title: 'Simplex', order: 5, wildcardPrefixCount: 1, color: '#b45cff' },
  mythic: { key: 'mythic', title: 'Nihil', order: 6, wildcardPrefixCount: 0, color: '#f4c542' }
};
const OMEGA_NIHIL_COLOR = '#ef4136';
const RARITY_DEFINITIONS = makeRarityDefinitions();

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url ?? '/', `http://${req.headers.host ?? 'localhost'}`);
    console.log(`${new Date().toISOString()} ${req.method} ${url.pathname}`);

    if (req.method === 'OPTIONS') {
      send(res, 204, 'text/plain', '');
      return;
    }

    if (req.method === 'GET' && (url.pathname === '/' || url.pathname === '/index.html')) {
      send(res, 200, 'text/html; charset=utf-8', pageHTML());
      return;
    }

    if (req.method === 'GET' && (url.pathname === '/dataset' || url.pathname === '/dataset.html')) {
      send(res, 200, 'text/html; charset=utf-8', datasetPageHTML());
      return;
    }

    if (req.method === 'GET' && url.pathname === '/vendor/octal-glyph.js') {
      await serveOctalGlyphBundle(res);
      return;
    }

    if (req.method === 'GET' && url.pathname === '/favicon.ico') {
      send(res, 204, 'image/x-icon', '');
      return;
    }

    if (req.method === 'GET' && (url.pathname === '/api/status' || url.pathname === '/health')) {
      const payload = await readLatestPayload({ includeMediaData: false });
      sendJSON(res, 200, {
        ok: true,
        hasBackup: Boolean(payload),
        exportTimestamp: payload?.exportTimestamp ?? null,
        entityCount: (payload?.archive?.entities?.length ?? 0) + (payload?.archive?.tags?.length ?? 0),
        recordCount: (payload?.archive?.records?.length ?? 0) + (payload?.archive?.entries?.length ?? 0),
        mediaCount: payload?.media?.length ?? 0
      });
      return;
    }

    if (req.method === 'GET' && url.pathname === '/api/manifest') {
      const payload = await readLatestPayload({ includeMediaData: false });
      sendJSON(res, 200, manifestView(payload));
      return;
    }

    if (req.method === 'GET' && url.pathname === '/api/records') {
      const payload = await readLatestPayload({ includeMediaData: false });
      sendJSON(res, 200, payload ? recordsView(payload) : { sarosFamilies: [], tags: [], rarities: [], records: [] });
      return;
    }

    if (req.method === 'GET' && url.pathname === '/api/animacy/status') {
      sendJSON(res, 200, await animacyStatusView());
      return;
    }

    if (req.method === 'GET' && url.pathname === '/api/animacy/dataset') {
      sendJSON(res, 200, await animacyDatasetView());
      return;
    }

    if (req.method === 'POST' && url.pathname === '/api/animacy/captures') {
      const body = await readBody(req);
      const payload = JSON.parse(body);
      const result = await writeAnimacyCapture(payload);
      console.log(`Stored animacy capture ${result.captureID} with ${result.transformationCount} transformations.`);
      sendJSON(res, 200, {
        ok: true,
        captureID: result.captureID,
        transformationCount: result.transformationCount,
        datasetItemCount: result.datasetItemCount
      });
      return;
    }

    if (req.method === 'GET' && url.pathname === '/api/backups/latest') {
      const payload = await readLatestPayload({ includeMediaData: true });
      if (!payload) {
        sendJSON(res, 404, { error: 'No synced records have been uploaded yet.' });
        return;
      }
      sendJSON(res, 200, payload);
      return;
    }

    if (req.method === 'POST' && url.pathname === '/api/sync/state') {
      const body = await readBody(req);
      const payload = JSON.parse(body);
      const result = await writeMirrorState(payload);
      console.log(`Mirrored ${result.tagCount} tags and ${result.entryCount} entries.`);
      sendJSON(res, 200, { ok: true, ...result });
      return;
    }

    if (req.method === 'POST' && url.pathname === '/api/sync/entry') {
      const body = await readBody(req);
      const payload = JSON.parse(body);
      const result = await writeEntryUpload(payload);
      console.log(`Stored entry ${result.entryID} with ${result.mediaCount} media files.`);
      sendJSON(res, 200, { ok: true, ...result });
      return;
    }

    if (req.method === 'GET' && url.pathname.startsWith('/media/')) {
      await serveMedia(url.pathname.slice('/media/'.length), res);
      return;
    }

    if (req.method === 'GET' && url.pathname.startsWith('/animacy/media/')) {
      await serveAnimacyMedia(url.pathname.slice('/animacy/media/'.length), res);
      return;
    }

    sendJSON(res, 404, { error: 'Not found' });
  } catch (error) {
    console.error(error);
    const status = error?.code === 'BODY_TOO_LARGE' ? 413 : 500;
    sendJSON(res, status, { error: error instanceof Error ? error.message : String(error) });
  }
});

server.listen(PORT, '0.0.0.0', () => {
  const addresses = localAddresses();
  console.log(`Exeligmos sync server listening on:`);
  for (const address of addresses) {
    console.log(`  http://${address}:${PORT}`);
  }
  console.log(`Data directory: ${DATA_DIR}`);
});

async function readBody(req) {
  let size = 0;
  const chunks = [];

  for await (const chunk of req) {
    size += chunk.length;
    if (size > MAX_BODY_BYTES) {
      const error = new Error(`Request body is larger than ${formatBytes(MAX_BODY_BYTES)}. Set MAX_BODY_BYTES to raise the limit.`);
      error.code = 'BODY_TOO_LARGE';
      throw error;
    }
    chunks.push(chunk);
  }

  return Buffer.concat(chunks).toString('utf8');
}

async function writeMirrorState(payload) {
  validateMirrorStatePayload(payload);

  const tagItems = payload.tags ?? [];
  const tagIDs = new Set(tagItems
    .map((item) => item?.tag ?? item)
    .filter((tag) => tag?.id)
    .map((tag) => String(tag.id)));
  const entryIDs = new Set((payload.entryIDs ?? []).filter(Boolean).map(String));

  const tagResult = await mirrorTags(tagItems, tagIDs);
  const entryResult = await pruneEntries(entryIDs);

  return {
    tagCount: tagItems.length,
    entryCount: entryIDs.size,
    mediaCount: 0,
    updatedTagCount: tagResult.updatedCount,
    deletedTagCount: tagResult.deletedCount,
    deletedEntryCount: entryResult.deletedCount
  };
}

function validateMirrorStatePayload(payload) {
  if (!payload || payload.schemaVersion !== 1 || !Array.isArray(payload.tags) || !Array.isArray(payload.entryIDs)) {
    throw new Error('Invalid Exeligmos state sync payload.');
  }
}

async function mirrorTags(items, tagIDs) {
  const root = path.join(DATA_DIR, 'tags');
  await fs.mkdir(root, { recursive: true });

  let updatedCount = 0;
  let deletedCount = 0;

  for (const directory of await childDirectories(root)) {
    const tag = await readJSONIfExists(path.join(directory, 'tag.json'));
    if (tag?.id && !tagIDs.has(String(tag.id))) {
      await fs.rm(directory, { recursive: true, force: true });
      deletedCount += 1;
    }
  }

  for (const item of items) {
    const tag = item.tag ?? item;
    if (!tag?.id) continue;
    const tagDir = await tagDirectoryFor(tag);
    await writeJSONAtomic(path.join(tagDir, 'tag.json'), tag);
    updatedCount += 1;
  }

  return { updatedCount, deletedCount };
}

async function pruneEntries(entryIDs) {
  const root = path.join(DATA_DIR, 'entries');
  await fs.mkdir(root, { recursive: true });

  let deletedCount = 0;

  for (const directory of await childDirectories(root)) {
    const entry = await readJSONIfExists(path.join(directory, 'entry.json'))
      ?? await readJSONIfExists(path.join(directory, 'record.json'));
    if (entry?.id && !entryIDs.has(String(entry.id))) {
      await fs.rm(directory, { recursive: true, force: true });
      deletedCount += 1;
    }
  }

  return { deletedCount };
}

async function writeEntryUpload(payload) {
  validateEntryUploadPayload(payload);

  const entryDir = await entryDirectoryFor(payload.entry);
  const media = new Map((payload.media ?? []).map((blob) => [blob.id, blob]));
  const mediaMetadata = await writeEntryFolder(
    entryDir,
    payload.entry,
    (payload.entry.mediaItems ?? []).map((item) => item.id),
    media
  );

  return {
    entryID: payload.entry.id,
    entryFolder: path.basename(entryDir),
    mediaCount: mediaMetadata.length
  };
}

function validateEntryUploadPayload(payload) {
  if (!payload || payload.schemaVersion !== 1 || !payload.entry?.id || !Array.isArray(payload.media)) {
    throw new Error('Invalid Exeligmos entry sync payload.');
  }
}

async function writeEntryFolder(entryDir, entry, mediaIDs, media) {
  const mediaDir = path.join(entryDir, 'media');
  await fs.mkdir(entryDir, { recursive: true });
  await fs.rm(mediaDir, { recursive: true, force: true });
  await fs.mkdir(mediaDir, { recursive: true });

  const mediaMetadata = [];
  const ids = mediaIDs?.length
    ? mediaIDs
    : (entry.mediaItems ?? []).map((item) => item.id);

  for (const mediaID of ids) {
    const blob = media.get(mediaID);
    if (!blob) continue;
    const fileName = mediaFileName(blob);
    const destination = path.join(mediaDir, fileName);
    await fs.writeFile(destination, Buffer.from(blob.dataBase64 ?? '', 'base64'));
    mediaMetadata.push({
      id: blob.id,
      type: blob.type,
      createdAt: blob.createdAt,
      relativePath: storedRelativePath(destination),
      fileName,
      contentType: blob.contentType || contentTypeForPath(fileName)
    });
  }

  await writeJSONAtomic(path.join(entryDir, 'entry.json'), entry);
  await writeJSONAtomic(path.join(entryDir, 'media.json'), mediaMetadata);
  return mediaMetadata;
}

async function tagDirectoryFor(tag) {
  const root = path.join(DATA_DIR, 'tags');
  await fs.mkdir(root, { recursive: true });

  const existing = await findChildDirectoryByJSON(root, 'tag.json', (value) => value?.id === tag.id);
  if (existing) return existing;

  return path.join(root, safeFolderName(String(tag.id)));
}

async function entryDirectoryFor(entry) {
  const root = path.join(DATA_DIR, 'entries');
  await fs.mkdir(root, { recursive: true });

  const base = entryFolderName(entry);
  const preferred = path.join(root, base);
  const existing = await findChildDirectoryByJSON(root, 'entry.json', (value) => value?.id === entry.id);
  if (existing) {
    if (path.basename(existing) === base) return existing;

    const preferredEntry = await readJSONIfExists(path.join(preferred, 'entry.json'));
    if (!preferredEntry || preferredEntry.id === entry.id) {
      await fs.rm(preferred, { recursive: true, force: true });
      await fs.rename(existing, preferred);
      return preferred;
    }

    return existing;
  }

  const preferredEntry = await readJSONIfExists(path.join(preferred, 'entry.json'));
  if (!preferredEntry || preferredEntry.id === entry.id) {
    return preferred;
  }

  return path.join(root, `${base}-${String(entry.id).slice(0, 8)}`);
}

async function findChildDirectoryByJSON(root, fileName, predicate) {
  let entries = [];
  try {
    entries = await fs.readdir(root, { withFileTypes: true });
  } catch {
    return null;
  }

  for (const entry of entries) {
    if (!entry.isDirectory()) continue;
    const directory = path.join(root, entry.name);
    const value = await readJSONIfExists(path.join(directory, fileName));
    if (value && predicate(value)) {
      return directory;
    }
  }
  return null;
}

async function readLatestPayload(options = {}) {
  const payload = await readFolderPayload(options);
  const hasState = (
    payload.archive.threadGroups.length
    + payload.archive.entities.length
    + payload.archive.records.length
    + payload.archive.tags.length
    + payload.archive.entries.length
  ) > 0;
  return hasState ? payload : null;
}

async function readFolderPayload({ includeMediaData = false } = {}) {
  const threadGroups = await readGroupSnapshots();
  const {
    entities,
    tags,
    records,
    entries,
    media,
    latestModifiedAt
  } = await readJournalSnapshots(includeMediaData);
  const exportTimestamp = latestModifiedAt?.toISOString() ?? new Date().toISOString();

  return {
    schemaVersion: 1,
    appVersion: 'folder-sync',
    exportTimestamp,
    archive: {
      appVersion: 'folder-sync',
      exportTimestamp,
      threadGroups,
      entities,
      records,
      tags,
      entries
    },
    media
  };
}

async function readGroupSnapshots() {
  const root = path.join(DATA_DIR, 'groups');
  const groups = [];
  for (const directory of await childDirectories(root)) {
    const group = await readJSONIfExists(path.join(directory, 'group.json'));
    if (group?.id) groups.push(group);
  }
  return groups.sort((a, b) => new Date(a.createdAt).getTime() - new Date(b.createdAt).getTime());
}

async function readJournalSnapshots(includeMediaData) {
  const rootEntries = await readEntryRootSnapshots(includeMediaData);
  const saros = await readSarosSnapshots(includeMediaData);
  const legacy = await readThreadSnapshots(includeMediaData);
  return mergeSnapshotSets(rootEntries, mergeSnapshotSets(saros, legacy));
}

async function readEntryRootSnapshots(includeMediaData) {
  const entities = [];
  const tags = [];
  const records = [];
  const entries = [];
  const media = [];
  let latestModifiedAt = null;

  for (const tagDir of await childDirectories(path.join(DATA_DIR, 'tags'))) {
    const tagFile = path.join(tagDir, 'tag.json');
    const tag = await readJSONIfExists(tagFile);
    if (!tag?.id) continue;
    if (tag.source === 'thread' || tag.title) {
      entities.push(tag);
    } else {
      tags.push(tag);
    }
    latestModifiedAt = maxDate(latestModifiedAt, await modifiedAt(tagFile));
  }

  for (const entryDir of await childDirectories(path.join(DATA_DIR, 'entries'))) {
    const entryFile = path.join(entryDir, 'entry.json');
    const entry = await readJSONIfExists(entryFile);
    if (!entry?.id) continue;
    entries.push(entry);
    latestModifiedAt = maxDate(latestModifiedAt, await modifiedAt(entryFile));

    const entryMedia = await readRecordMedia(entryDir, entry, includeMediaData);
    media.push(...entryMedia);
    for (const item of entryMedia) {
      latestModifiedAt = maxDate(latestModifiedAt, await modifiedAt(path.join(DATA_DIR, item.relativePath)));
    }
  }

  entities.sort((a, b) => new Date(a.createdAt).getTime() - new Date(b.createdAt).getTime());
  tags.sort((a, b) => new Date(a.createdAt).getTime() - new Date(b.createdAt).getTime());
  entries.sort((a, b) => new Date(a.eventDate).getTime() - new Date(b.eventDate).getTime());
  return { entities, tags, records, entries, media, latestModifiedAt };
}

async function readSarosSnapshots(includeMediaData) {
  const root = path.join(DATA_DIR, 'saros');
  const entities = [];
  const tags = [];
  const records = [];
  const entries = [];
  const media = [];
  let latestModifiedAt = null;

  for (const sarosDir of await childDirectories(root)) {
    const tagsRoot = path.join(sarosDir, 'tags');
    for (const tagDir of await childDirectories(tagsRoot)) {
      const tagFile = path.join(tagDir, 'tag.json');
      const tag = await readJSONIfExists(tagFile);
      if (!tag?.id) continue;
      if (tag.source === 'thread' || tag.title) {
        entities.push(tag);
      } else {
        tags.push(tag);
      }
      latestModifiedAt = maxDate(latestModifiedAt, await modifiedAt(tagFile));
    }

    const recordsRoot = path.join(sarosDir, 'records');
    for (const recordDir of await childDirectories(recordsRoot)) {
      const entryFile = path.join(recordDir, 'entry.json');
      const entry = await readJSONIfExists(entryFile);
      if (entry?.id) {
        entries.push(entry);
        latestModifiedAt = maxDate(latestModifiedAt, await modifiedAt(entryFile));

        const entryMedia = await readRecordMedia(recordDir, entry, includeMediaData);
        media.push(...entryMedia);
        for (const item of entryMedia) {
          latestModifiedAt = maxDate(latestModifiedAt, await modifiedAt(path.join(DATA_DIR, item.relativePath)));
        }
        continue;
      }

      const recordFile = path.join(recordDir, 'record.json');
      const record = await readJSONIfExists(recordFile);
      if (!record?.id) continue;
      records.push(record);
      latestModifiedAt = maxDate(latestModifiedAt, await modifiedAt(recordFile));

      const recordMedia = await readRecordMedia(recordDir, record, includeMediaData);
      media.push(...recordMedia);
      for (const item of recordMedia) {
        latestModifiedAt = maxDate(latestModifiedAt, await modifiedAt(path.join(DATA_DIR, item.relativePath)));
      }
    }
  }

  entities.sort((a, b) => new Date(a.createdAt).getTime() - new Date(b.createdAt).getTime());
  tags.sort((a, b) => new Date(a.createdAt).getTime() - new Date(b.createdAt).getTime());
  records.sort((a, b) => new Date(a.eventDate).getTime() - new Date(b.eventDate).getTime());
  entries.sort((a, b) => new Date(a.eventDate).getTime() - new Date(b.eventDate).getTime());
  return { entities, tags, records, entries, media, latestModifiedAt };
}

function mergeSnapshotSets(primary, secondary) {
  const entities = new Map();
  const tags = new Map();
  const records = new Map();
  const entries = new Map();
  const media = new Map();

  for (const entity of [...(secondary.entities ?? []), ...(primary.entities ?? [])]) {
    if (entity?.id) entities.set(entity.id, entity);
  }
  for (const tag of [...(secondary.tags ?? []), ...(primary.tags ?? [])]) {
    if (tag?.id) tags.set(tag.id, tag);
  }
  for (const record of [...(secondary.records ?? []), ...(primary.records ?? [])]) {
    if (record?.id) records.set(record.id, record);
  }
  for (const entry of [...(secondary.entries ?? []), ...(primary.entries ?? [])]) {
    if (entry?.id) entries.set(entry.id, entry);
  }
  for (const item of [...(secondary.media ?? []), ...(primary.media ?? [])]) {
    if (item?.id) media.set(item.id, item);
  }

  const latestModifiedAt = maxDate(primary.latestModifiedAt, secondary.latestModifiedAt);
  return {
    entities: [...entities.values()].sort((a, b) => new Date(a.createdAt).getTime() - new Date(b.createdAt).getTime()),
    tags: [...tags.values()].sort((a, b) => new Date(a.createdAt).getTime() - new Date(b.createdAt).getTime()),
    records: [...records.values()].sort((a, b) => new Date(a.eventDate).getTime() - new Date(b.eventDate).getTime()),
    entries: [...entries.values()].sort((a, b) => new Date(a.eventDate).getTime() - new Date(b.eventDate).getTime()),
    media: [...media.values()],
    latestModifiedAt
  };
}

async function readThreadSnapshots(includeMediaData) {
  const root = path.join(DATA_DIR, 'threads');
  const entities = [];
  const records = [];
  const media = [];
  let latestModifiedAt = null;

  for (const threadDir of await childDirectories(root)) {
    const threadFile = path.join(threadDir, 'thread.json');
    const thread = await readJSONIfExists(threadFile);
    if (!thread?.id) continue;
    entities.push(thread);
    latestModifiedAt = maxDate(latestModifiedAt, await modifiedAt(threadFile));

    const recordsRoot = path.join(threadDir, 'records');
    for (const recordDir of await childDirectories(recordsRoot)) {
      const recordFile = path.join(recordDir, 'record.json');
      const record = await readJSONIfExists(recordFile);
      if (!record?.id) continue;
      records.push(record);
      latestModifiedAt = maxDate(latestModifiedAt, await modifiedAt(recordFile));

      const recordMedia = await readRecordMedia(recordDir, record, includeMediaData);
      media.push(...recordMedia);
      for (const item of recordMedia) {
        latestModifiedAt = maxDate(latestModifiedAt, await modifiedAt(path.join(DATA_DIR, item.relativePath)));
      }
    }
  }

  entities.sort((a, b) => new Date(a.createdAt).getTime() - new Date(b.createdAt).getTime());
  records.sort((a, b) => new Date(a.eventDate).getTime() - new Date(b.eventDate).getTime());
  return { entities, tags: [], records, entries: [], media, latestModifiedAt };
}

async function readRecordMedia(recordDir, record, includeMediaData) {
  const mediaJSON = await readJSONIfExists(path.join(recordDir, 'media.json'));
  const metadata = Array.isArray(mediaJSON) ? mediaJSON : await inferRecordMedia(recordDir, record);
  const blobs = [];

  for (const item of metadata) {
    if (!item?.id || !item.relativePath) continue;
    const filePath = path.join(DATA_DIR, safeRelativePath(item.relativePath));
    const blob = {
      id: item.id,
      type: item.type,
      createdAt: item.createdAt,
      relativePath: storedRelativePath(filePath),
      fileName: item.fileName || path.basename(filePath),
      contentType: item.contentType || contentTypeForPath(filePath),
      dataBase64: ''
    };
    if (includeMediaData) {
      try {
        blob.dataBase64 = (await fs.readFile(filePath)).toString('base64');
      } catch {
        continue;
      }
    }
    blobs.push(blob);
  }

  return blobs;
}

async function inferRecordMedia(recordDir, record) {
  const mediaDir = path.join(recordDir, 'media');
  const files = [];
  try {
    for (const entry of await fs.readdir(mediaDir, { withFileTypes: true })) {
      if (entry.isFile()) files.push(entry.name);
    }
  } catch {
    return [];
  }

  return (record.mediaItems ?? []).map((item) => {
    const fileName = files.find((name) => name.startsWith(item.id)) ?? files.shift();
    if (!fileName) return null;
    const filePath = path.join(mediaDir, fileName);
    return {
      id: item.id,
      type: item.type,
      createdAt: item.createdAt,
      relativePath: storedRelativePath(filePath),
      fileName,
      contentType: contentTypeForPath(fileName)
    };
  }).filter(Boolean);
}

async function childDirectories(root) {
  try {
    return (await fs.readdir(root, { withFileTypes: true }))
      .filter((entry) => entry.isDirectory())
      .map((entry) => path.join(root, entry.name));
  } catch {
    return [];
  }
}

async function readJSONIfExists(filePath) {
  try {
    return JSON.parse(await fs.readFile(filePath, 'utf8'));
  } catch {
    return null;
  }
}

async function writeJSONAtomic(filePath, value) {
  await fs.mkdir(path.dirname(filePath), { recursive: true });
  const tempPath = `${filePath}.${process.pid}.${Date.now()}.tmp`;
  await fs.writeFile(tempPath, JSON.stringify(value, null, 2));
  await fs.rename(tempPath, filePath);
}

async function modifiedAt(filePath) {
  try {
    return (await fs.stat(filePath)).mtime;
  } catch {
    return null;
  }
}

function maxDate(a, b) {
  if (!a) return b;
  if (!b) return a;
  return a > b ? a : b;
}

function entryFolderName(entry) {
  const timestamp = entryUnixTimestamp(entry);
  const closest = closestSpikeForRecord(entry);
  const saros = Number(closest?.saros ?? sarosFromRecord(entry));
  const octalPhase = String(closest?.octalAddress || entry.octalAddress || 'phase')
    .replace(/[^0-7]/g, '')
    .slice(0, MAX_HARMONIC_DEPTH) || 'phase';
  return safeFolderName(`${timestamp}_${Number.isFinite(saros) ? saros : 0}_${octalPhase}`);
}

function entryUnixTimestamp(entry) {
  const explicit = Number(entry?.unixTimestamp);
  if (Number.isFinite(explicit) && explicit > 0) return Math.trunc(explicit);

  const parsed = Date.parse(entry?.eventDate);
  if (Number.isFinite(parsed)) return Math.trunc(parsed / 1000);

  const created = Date.parse(entry?.createdAt);
  if (Number.isFinite(created)) return Math.trunc(created / 1000);

  return Math.trunc(Date.now() / 1000);
}

function closestSpikeForRecord(record) {
  const rawSpikes = record?.context?.spikes ?? record?.spikes ?? [];
  if (!Array.isArray(rawSpikes) || !rawSpikes.length) return null;

  const eventTime = recordTimeMs(record);
  return [...rawSpikes].sort((a, b) => {
    const aTime = spikeTimeMs(a);
    const bTime = spikeTimeMs(b);
    return Math.abs(aTime - eventTime) - Math.abs(bTime - eventTime);
  })[0] ?? null;
}

function recordTimeMs(record) {
  const parsed = Date.parse(record?.eventDate);
  if (Number.isFinite(parsed)) return parsed;
  const unix = Number(record?.unixTimestamp);
  if (Number.isFinite(unix)) return unix * 1000;
  return 0;
}

function spikeTimeMs(spike) {
  const unix = Number(spike?.unixTimestamp);
  if (Number.isFinite(unix)) return unix * 1000;
  const parsed = Date.parse(spike?.eventDate);
  return Number.isFinite(parsed) ? parsed : 0;
}

function sarosFromRecord(record, thread = null) {
  const spikeSaros = Number(closestSpikeForRecord(record)?.saros);
  if (Number.isFinite(spikeSaros)) return spikeSaros;

  const candidates = recordSarosNumbers(record, thread);
  return candidates[0] ?? 0;
}

function recordSarosNumbers(record, thread = null) {
  const values = [];
  const add = (value) => {
    const number = Number(value);
    if (Number.isFinite(number) && !values.includes(number)) {
      values.push(number);
    }
  };

  const sourceSpikes = record?.context?.spikes ?? record?.spikes ?? [];
  const eventTime = recordTimeMs(record);
  for (const spike of [...sourceSpikes].sort((a, b) => {
    const aTime = spikeTimeMs(a);
    const bTime = spikeTimeMs(b);
    return Math.abs(aTime - eventTime) - Math.abs(bTime - eventTime);
  })) {
    add(spike?.saros);
  }

  add(record?.saros);
  add(thread?.saros);
  return values;
}

function mediaFileName(blob) {
  const fallback = `${blob.id || 'media'}${extensionForContentType(blob.contentType)}`;
  const fileName = safeFileName(blob.fileName || fallback);
  if (path.extname(fileName)) return fileName;
  return `${fileName}${extensionForContentType(blob.contentType)}`;
}

function storedRelativePath(filePath) {
  return path.relative(DATA_DIR, filePath).replaceAll(path.sep, '/');
}

function manifestView(payload) {
  const tags = payload?.archive?.tags ?? [];
  const entries = payload?.archive?.entries ?? [];
  return {
    ok: true,
    hasBackup: Boolean(payload),
    exportTimestamp: payload?.exportTimestamp ?? null,
    entityIDs: (payload?.archive?.entities ?? []).map((entity) => entity.id),
    recordIDs: (payload?.archive?.records ?? []).map((record) => record.id),
    tagIDs: tags.map((tag) => tag.id),
    entryIDs: entries.map((entry) => entry.id),
    mediaIDs: (payload?.media ?? []).map((blob) => blob.id)
  };
}

function recordsView(payload) {
  const entities = new Map((payload.archive.entities ?? []).map((entity) => [entity.id, entity]));
  const tagsByID = new Map((payload.archive.tags ?? []).map((tag) => [tag.id, tag]));
  const tagLookup = new Map([...entities, ...tagsByID]);
  const media = new Map((payload.media ?? []).map((blob) => [blob.id, blob]));
  const legacyRecords = [...(payload.archive.records ?? [])]
    .map((record) => webRecord(record, entities.get(record.entityID), tagLookup, media));
  const entryRecords = [...(payload.archive.entries ?? [])]
    .map((entry) => webRecord(entry, null, tagLookup, media));
  const records = [...legacyRecords, ...entryRecords]
    .sort((a, b) => new Date(b.eventDate).getTime() - new Date(a.eventDate).getTime())
    .filter(Boolean);
  const sarosFamilies = sarosFilterOptions(records);
  const tagFilters = tagFilterOptions(records);
  const rarityFilters = groupedFilterOptions(records, 'rarityKey', (record) => ({
    id: record.rarity.key,
    name: record.rarity.title,
    rank: record.rarity.rank,
    color: record.rarity.color,
    baseKey: record.rarity.baseKey,
    repeatedDigit: record.rarity.repeatedDigit,
    hasBadge: record.rarity.hasBadge,
    isCommon: record.rarity.isCommon,
    glyphAddress: record.rarity.glyphAddress,
    patternLabel: record.rarity.patternLabel
  })).sort((a, b) => a.rank - b.rank);

  return {
    exportTimestamp: payload.exportTimestamp,
    entityCount: (payload.archive.tags?.length ?? 0) + (payload.archive.entities?.length ?? 0),
    recordCount: records.length,
    mediaCount: payload.media?.length ?? 0,
    sarosFamilies,
    tags: tagFilters,
    rarities: rarityFilters,
    records
  };
}

function webRecord(record, entity, tagLookup, media) {
  if (!record?.id) return null;
  const spikes = recordSpikes(record, entity);
  const rarity = rarityForRecord(record);
  const sarosNumbers = recordSarosNumbers(record, entity);
  const tags = recordTags(record, tagLookup);
  const primarySpike = spikes[0];

  return {
    id: record.id,
    entityID: record.entityID ?? null,
    title: recordTitle(record, rarity),
    entityTitle: entity?.title || entity?.name || 'Untitled tag',
    entityEmoji: entity?.emoji ?? null,
    tags,
    eventDate: record.eventDate,
    emoji: record.emoji,
    text: record.text,
    saros: sarosNumbers[0] ?? record.saros,
    sarosNumbers,
    octalAddress: primarySpike?.octalAddress ?? record.octalAddress,
    harmonicDepth: primarySpike?.harmonicDepth ?? record.harmonicDepth ?? 7,
    rarity,
    spikes,
    media: (record.mediaItems ?? []).map((item) => {
      const blob = media.get(item.id);
      const relativePath = blob?.relativePath || item.localPath;
      return {
        id: item.id,
        type: item.type,
        createdAt: item.createdAt,
        contentType: blob?.contentType || contentTypeForPath(relativePath),
        url: `/media/${encodePath(relativePath)}`
      };
    })
  };
}

function sarosFilterOptions(records) {
  const values = new Map();
  for (const record of records) {
    for (const saros of record.sarosNumbers ?? []) {
      const key = String(saros);
      const existing = values.get(key) ?? { id: key, saros, name: `Saros ${saros}`, count: 0 };
      existing.count += 1;
      values.set(key, existing);
    }
  }
  return [...values.values()].sort((a, b) => Number(a.saros) - Number(b.saros));
}

function tagFilterOptions(records) {
  const values = new Map();
  for (const record of records) {
    for (const tag of record.tags ?? []) {
      const key = tag.filterID || tag.displayKey || tag.id;
      const existing = values.get(key) ?? { ...tag, id: key, count: 0 };
      existing.count += 1;
      values.set(key, existing);
    }
  }
  return [...values.values()].sort((a, b) => String(a.name).localeCompare(String(b.name)));
}

function groupedFilterOptions(records, key, mapper) {
  const values = new Map();
  for (const record of records) {
    const id = key === 'rarityKey' ? record.rarity.key : record[key];
    if (!id) continue;
    const existing = values.get(id);
    if (existing) {
      existing.count += 1;
    } else {
      values.set(id, { ...mapper(record), count: 1 });
    }
  }
  return [...values.values()].sort((a, b) => String(a.name).localeCompare(String(b.name)));
}

function recordTitle(record, rarity) {
  if (record?.context?.displayTitle) return record.context.displayTitle;
  if (rarity?.isCommon) return 'Common';
  return rarity?.title || 'Record';
}

function recordTags(record, entities) {
  const tags = [];
  const displayKeys = new Set();
  const add = (entity) => {
    if (!entity?.id) return;
    const displayKey = tagDisplayKey(entity);
    if (displayKeys.has(displayKey)) return;
    displayKeys.add(displayKey);
    tags.push({
      id: entity.id,
      filterID: displayKey,
      displayKey,
      name: entity.title || entity.name || `Saros ${entity.saros ?? ''}`.trim(),
      emoji: entity.emoji || '◇',
      saros: entity.saros ?? null
    });
  };

  add(entities.get(record.entityID));

  const saroses = new Set(recordSarosNumbers(record, entities.get(record.entityID)));
  for (const entity of entities.values()) {
    if (saroses.has(Number(entity.saros))) {
      add(entity);
    }
  }

  return tags;
}

function tagDisplayKey(entity) {
  const source = entity.sourceEntityID || entity.sourceID;
  if (source) return `source:${source}`;
  const name = String(entity.title || entity.name || '').trim().toLowerCase();
  const emoji = String(entity.emoji || '').trim();
  return `${emoji}|${name}`;
}

function recordSpikes(record, entity = null) {
  const sourceSpikes = record?.context?.spikes ?? record?.spikes;
  if (Array.isArray(sourceSpikes) && sourceSpikes.length) {
    const eventTime = recordTimeMs(record);
    return sourceSpikes.map((spike) => {
      const depth = clampedHarmonicDepth(spike.harmonicDepth ?? record.harmonicDepth);
      const rarity = rarityForRawValue(spike.rarityRawValue)
        ?? rarityForAddress(spike.octalAddress, depth);
      const spikeTime = spikeTimeMs(spike);
      return {
        id: spike.id || `${spike.saros}-${spike.unixTimestamp ?? spike.eventDate ?? spike.octalAddress}`,
        saros: Number(spike.saros),
        unixTimestamp: spike.unixTimestamp ?? null,
        octalAddress: spike.octalAddress || rarity.glyphAddress,
        harmonicDepth: depth,
        rarity,
        distanceFromRecord: Math.abs(spikeTime - eventTime)
      };
    }).sort((a, b) => {
      if (a.distanceFromRecord !== b.distanceFromRecord) {
        return a.distanceFromRecord - b.distanceFromRecord;
      }
      return (b.rarity?.rank ?? 0) - (a.rarity?.rank ?? 0);
    });
  }

  const depth = clampedHarmonicDepth(record.harmonicDepth ?? entity?.harmonicDepth);
  const rarity = rarityForAddress(record.octalAddress, depth);
  return [{
    id: record.id,
    saros: sarosFromRecord(record, entity),
    octalAddress: record.octalAddress || rarity.glyphAddress,
    harmonicDepth: depth,
    rarity
  }];
}

function rarityForRecord(record) {
  const spikes = recordSpikes(record);
  if (spikes.length > 1) {
    return spikes.reduce((best, spike) => (
      (spike.rarity?.rank ?? 0) > (best.rank ?? 0) ? spike.rarity : best
    ), rarityDefinition('common'));
  }

  const depth = clampedHarmonicDepth(record.harmonicDepth);
  return rarityForAddress(record.octalAddress, depth);
}

function rarityForAddress(octalAddress, depth) {
  const pattern = repeatedSuffixPattern(octalAddress, depth);
  if (pattern.digit <= 0) return rarityDefinition('common');
  return rarityDefinitionForPattern(pattern.order, pattern.digit, depth);
}

function rarityForRawValue(rawValue) {
  const key = canonicalRarityKey(rawValue);
  if (RARITY_DEFINITIONS[key]) return RARITY_DEFINITIONS[key];
  return null;
}

function rarityDefinition(key) {
  return RARITY_DEFINITIONS[canonicalRarityKey(key)] ?? RARITY_DEFINITIONS.common;
}

function rarityDefinitionForPattern(order, digit, depth = DEFAULT_HARMONIC_DEPTH) {
  const baseKey = rarityBaseKeyForOrder(order);
  const definition = rarityDefinition(`${baseKey}-${clampedRarityDigit(digit)}`);
  return {
    ...definition,
    glyphAddress: rarityGlyphAddress(definition, depth),
    patternLabel: rarityPatternLabel(definition, depth)
  };
}

function makeRarityDefinitions() {
  const definitions = {
    common: {
      key: 'common',
      title: 'Common',
      rank: 0,
      color: '#f3f5f7',
      baseKey: 'common',
      order: 0,
      wildcardPrefixCount: DEFAULT_HARMONIC_DEPTH,
      repeatedDigit: 0,
      hasBadge: false,
      isCommon: true,
      glyphAddress: '0'.repeat(DEFAULT_HARMONIC_DEPTH),
      patternLabel: 'Common'
    }
  };

  for (const base of Object.values(RARITY_BASES)) {
    definitions[base.key] = {
      ...base,
      rank: base.order * 8,
      repeatedDigit: 0,
      baseKey: base.key,
      hasBadge: true,
      isCommon: false,
      isHeader: true,
      glyphAddress: rarityGlyphAddress({ ...base, repeatedDigit: 7 }, DEFAULT_HARMONIC_DEPTH),
      patternLabel: base.title
    };

    for (let digit = 1; digit <= 7; digit += 1) {
      const title = `${RARITY_DIGIT_PREFIXES[digit]} ${base.title}`;
      const color = base.key === 'mythic' && digit === 7
        ? OMEGA_NIHIL_COLOR
        : base.color;
      const definition = {
        ...base,
        key: `${base.key}-${digit}`,
        title,
        color,
        rank: base.order * 8 + digit,
        repeatedDigit: digit,
        baseKey: base.key,
        hasBadge: true,
        isCommon: false,
        isHeader: false
      };
      definitions[definition.key] = {
        ...definition,
        glyphAddress: rarityGlyphAddress(definition, DEFAULT_HARMONIC_DEPTH),
        patternLabel: rarityPatternLabel(definition, DEFAULT_HARMONIC_DEPTH)
      };
    }
  }

  return definitions;
}

function canonicalRarityKey(key) {
  const value = String(key || '').toLowerCase();
  if (value === 'saros' || value === 'saros0') return 'mythic-7';
  if (/^saros[1-7]$/.test(value)) return `mythic-${value.at(-1)}`;
  return value;
}

function rarityBaseKeyForOrder(order) {
  const clampedOrder = Math.min(Math.max(Number(order) || 3, 3), 6);
  return Object.values(RARITY_BASES).find((base) => base.order === clampedOrder)?.key ?? 'rare';
}

function repeatedSuffixPattern(octalAddress, rawDepth) {
  const depth = clampedHarmonicDepth(rawDepth);
  const digits = String(octalAddress || '').replace(/[^0-7]/g, '');
  const trimmed = digits.slice(0, depth);
  let padded = (trimmed || '0').padStart(depth, '0');
  const numericValue = Number.parseInt(padded, 8) || 0;

  if (numericValue === 0) {
    return { order: 6, digit: 7 };
  }

  if (padded.endsWith('0')) {
    padded = (numericValue - 1).toString(8).padStart(depth, '0');
  }

  const characters = [...padded];
  const last = characters.at(-1);
  const digit = Number(last);
  if (!last || last === '0' || !Number.isInteger(digit)) {
    return { order: 3, digit: 0 };
  }

  const suffixLength = [...characters].reverse().findIndex((character) => character !== last);
  const repeatedLength = suffixLength === -1 ? characters.length : suffixLength;
  const wildcardPrefixCount = depth - repeatedLength;
  const order =
    wildcardPrefixCount <= 0 ? 6 :
    wildcardPrefixCount === 1 ? 5 :
    wildcardPrefixCount === 2 ? 4 :
    wildcardPrefixCount === 3 ? 3 :
    3;

  return {
    order,
    digit: wildcardPrefixCount <= 3 ? digit : 0
  };
}

function rarityGlyphAddress(rarity, rawDepth = DEFAULT_HARMONIC_DEPTH) {
  const depth = clampedHarmonicDepth(rawDepth);
  if (!rarity || rarity.key === 'common') return '0'.repeat(depth);

  const prefixCount = Math.min(Number(rarity.wildcardPrefixCount) || 0, depth);
  const digit = Number(rarity.repeatedDigit) > 0 ? clampedRarityDigit(rarity.repeatedDigit) : 7;
  const suffixLength = Math.max(depth - prefixCount, 0);
  return '0'.repeat(prefixCount) + String(digit).repeat(suffixLength);
}

function rarityPatternLabel(rarity, rawDepth = DEFAULT_HARMONIC_DEPTH) {
  const depth = clampedHarmonicDepth(rawDepth);
  if (!rarity || rarity.key === 'common') return 'Common';
  if (!(Number(rarity.repeatedDigit) > 0)) return rarity.title;

  const prefixCount = Math.min(Number(rarity.wildcardPrefixCount) || 0, depth);
  const suffixLength = Math.max(depth - prefixCount, 0);
  return 'X'.repeat(prefixCount) + String(clampedRarityDigit(rarity.repeatedDigit)).repeat(suffixLength);
}

function clampedRarityDigit(digit) {
  return Math.min(Math.max(Number(digit) || 0, 0), 7);
}

function clampedHarmonicDepth(value) {
  return Math.min(Math.max(Number(value) || DEFAULT_HARMONIC_DEPTH, MIN_HARMONIC_DEPTH), MAX_HARMONIC_DEPTH);
}

async function writeAnimacyCapture(payload) {
  validateAnimacyPayload(payload);

  const captureID = String(payload.capture.id);
  const captureDir = path.join(DATA_DIR, 'animacy', 'captures', captureID);
  const datasetDir = path.join(DATA_DIR, 'animacy', 'dataset');
  await fs.mkdir(captureDir, { recursive: true });
  await fs.mkdir(datasetDir, { recursive: true });

  const originalFileName = safeFileName(payload.originalImage?.fileName || `${captureID}-original.jpg`);
  await fs.writeFile(
    path.join(captureDir, originalFileName),
    Buffer.from(payload.originalImage?.dataBase64 ?? '', 'base64')
  );

  const transformations = [];
  for (const transformation of payload.capture.transformations ?? []) {
    const transformationID = String(transformation.id);
    const imageFileName = safeFileName(transformation.datasetImage?.fileName || `${transformationID}.jpg`);
    const datasetFileName = `${captureID}-${imageFileName}`;
    const datasetRelativePath = `dataset/${datasetFileName}`;

    if (transformation.datasetImage?.dataBase64) {
      await fs.writeFile(
        path.join(DATA_DIR, 'animacy', datasetRelativePath),
        Buffer.from(transformation.datasetImage.dataBase64, 'base64')
      );
    }

    const { datasetImage, animacyScore, labels, note, analysis, ...metadata } = transformation;
    const rarity = normalizeRarity(transformation.rarity ?? rarityFromLegacyScore(transformation.animacyScore));
    transformations.push({
      ...metadata,
      rarity,
      datasetImagePath: datasetRelativePath,
      datasetImageURL: `/animacy/media/${encodeAnimacyPath(datasetRelativePath)}`
    });
  }

  const document = {
    schemaVersion: payload.schemaVersion,
    appVersion: payload.appVersion,
    createdAt: payload.createdAt || new Date().toISOString(),
    storedAt: new Date().toISOString(),
    capture: {
      ...payload.capture,
      originalImagePath: `captures/${captureID}/${originalFileName}`,
      originalImageURL: `/animacy/media/${encodeAnimacyPath(`captures/${captureID}/${originalFileName}`)}`,
      transformations
    },
    processing: {
      status: 'stored',
      note: 'Manual rarity labels are stored as dataset training targets.',
      processedAt: new Date().toISOString()
    }
  };

  await fs.writeFile(path.join(captureDir, 'capture.json'), JSON.stringify(document, null, 2));
  await rebuildAnimacyManifest();

  return {
    captureID,
    transformationCount: transformations.length,
    datasetItemCount: transformations.filter((item) => item.datasetImagePath).length
  };
}

async function animacyStatusView() {
  const dataset = await animacyDatasetView();
  return {
    ok: true,
    captureCount: dataset.captureCount,
    datasetItemCount: dataset.datasetItemCount,
    rarityCounts: dataset.rarityCounts,
    updatedAt: dataset.updatedAt
  };
}

async function animacyDatasetView() {
  const captures = await readAnimacyCaptures();
  const items = captures.flatMap((capture) => {
    const captureID = capture.capture.id;
    return (capture.capture.transformations ?? []).map((transformation) => ({
      captureID,
      transformationID: transformation.id,
      createdAt: transformation.createdAt,
      rarity: normalizeRarity(transformation.rarity ?? rarityFromLegacyScore(transformation.animacyScore)),
      rarityRank: rarityRank(normalizeRarity(transformation.rarity ?? rarityFromLegacyScore(transformation.animacyScore))),
      mirrorMode: transformation.mirrorMode,
      reflectedSide: transformation.reflectedSide ?? null,
      imageTransform: transformation.imageTransform,
      mirrorEdges: transformation.mirrorEdges ?? [],
      datasetImageURL: transformation.datasetImageURL,
      originalImageURL: capture.capture.originalImageURL
    }));
  });
  const rarityCounts = Object.fromEntries(ANIMACY_RARITIES.map((rarity) => [
    rarity,
    items.filter((item) => item.rarity === rarity).length
  ]));

  return {
    ok: true,
    updatedAt: new Date().toISOString(),
    captureCount: captures.length,
    datasetItemCount: items.length,
    rarities: ANIMACY_RARITIES,
    rarityCounts,
    captures,
    items
  };
}

async function readAnimacyCaptures() {
  const root = path.join(DATA_DIR, 'animacy', 'captures');
  try {
    const entries = await fs.readdir(root, { withFileTypes: true });
    const captures = [];
    for (const entry of entries) {
      if (!entry.isDirectory()) continue;
      const url = path.join(root, entry.name, 'capture.json');
      try {
        captures.push(JSON.parse(await fs.readFile(url, 'utf8')));
      } catch {
        // Ignore incomplete captures so the dashboard still opens.
      }
    }
    return captures.sort((a, b) => new Date(b.storedAt).getTime() - new Date(a.storedAt).getTime());
  } catch {
    return [];
  }
}

async function rebuildAnimacyManifest() {
  const dataset = await animacyDatasetView();
  const manifest = {
    ok: true,
    generatedAt: new Date().toISOString(),
    modelFamily: 'MobileNetV3-small',
    inputSize: [224, 224],
    task: 'animacy-rarity-classification',
    classes: ANIMACY_RARITIES,
    itemCount: dataset.items.length,
    items: dataset.items.map((item) => ({
      imagePath: item.datasetImageURL?.replace('/animacy/media/', '') ?? null,
      captureID: item.captureID,
      transformationID: item.transformationID,
      rarity: item.rarity,
      rarityIndex: item.rarityRank
    }))
  };
  const root = path.join(DATA_DIR, 'animacy');
  await fs.mkdir(root, { recursive: true });
  await fs.writeFile(path.join(root, 'dataset-manifest.json'), JSON.stringify(manifest, null, 2));
}

function validateAnimacyPayload(payload) {
  if (!payload || payload.schemaVersion !== 1 || !payload.capture?.id || !payload.originalImage?.dataBase64) {
    throw new Error('Invalid Exeligmos animacy dataset payload.');
  }
  if (!Array.isArray(payload.capture.transformations)) {
    throw new Error('Animacy dataset payload must include transformations.');
  }
}

function normalizeRarity(value) {
  const normalized = String(value || '').trim().toLowerCase();
  return ANIMACY_RARITIES.includes(normalized) ? normalized : 'common';
}

function rarityRank(value) {
  return Math.max(ANIMACY_RARITIES.indexOf(normalizeRarity(value)), 0);
}

function rarityFromLegacyScore(value) {
  const score = Number(value);
  if (!Number.isFinite(score)) return 'common';
  if (score < 35) return 'common';
  if (score < 55) return 'rare';
  if (score < 75) return 'epic';
  if (score < 90) return 'legendary';
  return 'mythic';
}

async function serveMedia(encodedRelativePath, res) {
  const relativePath = safeRelativePath(decodeURIComponent(encodedRelativePath));
  const filePath = path.join(DATA_DIR, relativePath);
  try {
    await fs.access(filePath);
  } catch {
    sendJSON(res, 404, { error: 'Media not found' });
    return;
  }

  res.writeHead(200, {
    'Content-Type': contentTypeForPath(filePath),
    'Cache-Control': 'no-store'
  });
  createReadStream(filePath).pipe(res);
}

async function serveAnimacyMedia(encodedRelativePath, res) {
  const relativePath = safeAnimacyRelativePath(decodeURIComponent(encodedRelativePath));
  const filePath = path.join(DATA_DIR, 'animacy', relativePath);
  try {
    await fs.access(filePath);
  } catch {
    sendJSON(res, 404, { error: 'Animacy media not found' });
    return;
  }

  res.writeHead(200, {
    'Content-Type': contentTypeForPath(filePath),
    'Cache-Control': 'no-store'
  });
  createReadStream(filePath).pipe(res);
}

async function serveOctalGlyphBundle(res) {
  try {
    await fs.access(OCTAL_GLYPH_BUNDLE);
  } catch {
    send(res, 404, 'text/javascript; charset=utf-8', 'globalThis.OctalGlyph = null;');
    return;
  }

  res.writeHead(200, {
    'Content-Type': 'text/javascript; charset=utf-8',
    'Cache-Control': 'no-store'
  });
  createReadStream(OCTAL_GLYPH_BUNDLE).pipe(res);
}

function pageHTML() {
  return `<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Exeligmos Sync</title>
  <style>
    :root { color-scheme: dark; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
    body { margin: 0; background: #0b0d10; color: #f3f5f7; }
    header { position: sticky; top: 0; z-index: 2; background: rgba(11,13,16,.94); backdrop-filter: blur(14px); padding: 10px 20px; border-bottom: 1px solid #222832; }
    .header-inner { max-width: 980px; margin: 0 auto; display: flex; gap: 14px; align-items: center; justify-content: space-between; }
    h1 { margin: 0; font-size: 15px; letter-spacing: .04em; text-transform: uppercase; }
    .meta { color: #95a0ad; font-size: 13px; }
    main { max-width: 980px; margin: 0 auto; padding: 18px 20px 40px; }
    nav { display: flex; gap: 8px; flex-wrap: wrap; }
    nav a { color: #f3f5f7; text-decoration: none; background: #1b222c; border: 1px solid #2d3946; border-radius: 8px; padding: 7px 10px; font-size: 13px; }
    .filters { display: grid; gap: 10px; grid-template-columns: minmax(0, 1fr); margin-bottom: 18px; padding: 12px; border: 1px solid #222a34; border-radius: 12px; background: #0f141a; }
    .filter-selects { display: grid; gap: 10px; grid-template-columns: repeat(2, minmax(0, 1fr)); }
    .rarity-filter { display: flex; gap: 8px; overflow-x: auto; padding-bottom: 1px; scrollbar-width: none; }
    .rarity-filter::-webkit-scrollbar { display: none; }
    .rarity-filter button { display: inline-flex; align-items: center; gap: 7px; }
    .rarity-filter .rarity-glyph { width: 22px; height: 22px; flex: 0 0 22px; }
    .rarity-filter button.active .rarity-glyph { color: #071018; }
    button, select { color: #f3f5f7; background: #121820; border: 1px solid #2b3541; border-radius: 8px; font: inherit; font-size: 13px; }
    button { padding: 8px 10px; cursor: pointer; white-space: nowrap; }
    button.active { background: var(--rarity-color, #e8edf3); border-color: var(--rarity-color, #e8edf3); color: #071018; }
    select { min-width: 0; padding: 8px 10px; }
    .day { margin: 22px 0 10px; color: #8f98a3; font-size: 12px; font-weight: 800; letter-spacing: .08em; text-transform: uppercase; }
    .record { display: grid; grid-template-columns: 54px minmax(0, 1fr) 72px; gap: 14px; padding: 16px; margin-top: 10px; border: 1px solid #232a34; border-radius: 10px; background: #11151b; }
    .record-head { display: flex; gap: 10px; align-items: baseline; flex-wrap: wrap; }
    .title { font-weight: 800; font-size: 17px; }
    .sub { color: #9ca6b3; font-size: 13px; margin-top: 6px; }
    .spikes { display: flex; gap: 12px; align-items: end; margin-top: 10px; flex-wrap: wrap; }
    .spike { display: grid; gap: 3px; justify-items: center; color: #9ca6b3; font-size: 12px; }
    .spike .glyph { width: 34px; height: 34px; }
    .badge { display: inline-flex; align-items: center; gap: 6px; border: 1px solid #2d3946; border-radius: 999px; padding: 4px 8px; color: #c8d0d9; font-size: 12px; }
    .rarity { border-color: color-mix(in srgb, var(--rarity-color), transparent 45%); color: var(--rarity-color); background: color-mix(in srgb, var(--rarity-color), transparent 88%); }
    .record-side { display: grid; gap: 8px; justify-items: center; align-content: start; }
    .glyph { width: 76px; height: 76px; display: grid; place-items: center; color: var(--rarity-color, #f3f5f7); }
    .glyph svg { width: 100%; height: 100%; display: block; overflow: visible; }
    .glyph path, .glyph polygon, .glyph circle { fill: currentColor; }
    .glyph-fallback { width: 72px; height: 72px; }
    .emoji { font-size: 34px; line-height: 1; }
    .tags { display: flex; gap: 6px; flex-wrap: wrap; margin-top: 10px; }
    .tag { display: inline-flex; align-items: center; justify-content: center; min-width: 28px; height: 24px; border-radius: 999px; background: #1b222c; font-size: 16px; }
    .text { margin-top: 10px; white-space: pre-wrap; color: #d8dde4; }
    .media { display: flex; gap: 10px; flex-wrap: wrap; margin-top: 12px; }
    .media img, .media video { width: 160px; height: 160px; object-fit: cover; border-radius: 8px; background: #050607; }
    .media-preview { padding: 0; border: 0; background: transparent; line-height: 0; cursor: zoom-in; }
    .media-preview:focus-visible { outline: 2px solid #2f9bff; outline-offset: 3px; }
    audio { width: 260px; }
    .empty { color: #95a0ad; padding: 40px 0; text-align: center; }
    .lightbox[hidden] { display: none; }
    .lightbox { position: fixed; inset: 0; z-index: 10; display: grid; place-items: center; padding: 24px; background: rgba(0,0,0,.86); backdrop-filter: blur(12px); }
    .lightbox img, .lightbox video { max-width: min(96vw, 1280px); max-height: 92vh; object-fit: contain; border-radius: 10px; box-shadow: 0 24px 80px rgba(0,0,0,.7); }
    .lightbox-close { position: absolute; top: 18px; right: 18px; width: 44px; height: 44px; border-radius: 999px; font-size: 20px; background: rgba(15,18,22,.78); }
    @media (max-width: 720px) {
      header { padding: 10px 14px; }
      .header-inner { align-items: flex-start; flex-direction: column; gap: 8px; }
      .filters { grid-template-columns: 1fr; }
      .filter-selects { grid-template-columns: 1fr; }
      .record { grid-template-columns: 48px minmax(0, 1fr) 56px; }
      .glyph { width: 64px; height: 64px; }
      .spike .glyph { width: 30px; height: 30px; }
      .emoji { font-size: 26px; }
      audio { width: 100%; }
      .media img, .media video { width: calc(50vw - 34px); height: calc(50vw - 34px); }
    }
  </style>
</head>
<body>
  <header>
    <div class="header-inner">
      <h1>Exeligmos Sync</h1>
      <div class="meta" id="status">Loading synced folders...</div>
      <nav><a href="/dataset">Dataset</a></nav>
    </div>
  </header>
  <main id="records"></main>
  <div class="lightbox" id="lightbox" hidden>
    <button type="button" class="lightbox-close" id="lightbox-close" aria-label="Close media preview">X</button>
    <img id="lightbox-image" alt="">
    <video id="lightbox-video" controls playsinline hidden></video>
  </div>
  <script src="/vendor/octal-glyph.js"></script>
  <script>
    const status = document.getElementById('status');
    const recordsEl = document.getElementById('records');
    const lightbox = document.getElementById('lightbox');
    const lightboxImage = document.getElementById('lightbox-image');
    const lightboxVideo = document.getElementById('lightbox-video');
    const lightboxClose = document.getElementById('lightbox-close');
    const state = { rarity: 'all', saros: 'all', tag: 'all', data: null };
    const glyphFontCache = new Map();

    lightboxClose.addEventListener('click', closeMediaPreview);
    lightbox.addEventListener('click', (event) => {
      if (event.target === lightbox) closeMediaPreview();
    });
    document.addEventListener('keydown', (event) => {
      if (event.key === 'Escape' && !lightbox.hidden) closeMediaPreview();
    });

    fetch('/api/records')
      .then((response) => response.json())
      .then((data) => {
        status.textContent = data.exportTimestamp
          ? \`Folder state: \${new Date(data.exportTimestamp).toLocaleString()} · \${data.entityCount} tags · \${data.recordCount} records · \${data.mediaCount} media\`
          : 'No synced records yet. Upload from the iOS app Settings screen.';
        state.data = data;
        renderPage();
      })
      .catch((error) => {
        status.textContent = error.message;
      });

    function renderPage() {
      const data = state.data || { records: [], sarosFamilies: [], tags: [], rarities: [] };
      recordsEl.innerHTML = '';

      const filters = document.createElement('section');
      filters.className = 'filters';
      filters.append(renderRarityFilter(data.rarities || []));
      const filterSelects = document.createElement('div');
      filterSelects.className = 'filter-selects';
      filterSelects.append(renderSelect('saros', 'Saros', data.sarosFamilies || [], (family) => \`\${family.name} (\${family.count})\`));
      filterSelects.append(renderSelect('tag', 'Tag', data.tags || [], (tag) => \`\${tag.emoji || ''} \${tag.name || 'Tag'} (\${tag.count})\`));
      filters.append(filterSelects);
      recordsEl.appendChild(filters);

      const records = filteredRecords(data.records || []);
      if (!records.length) {
        recordsEl.insertAdjacentHTML('beforeend', '<div class="empty">No records match these filters.</div>');
        return;
      }

      let lastDay = '';
      for (const record of records) {
        const day = dayKey(record.eventDate);
        if (day !== lastDay) {
          const divider = document.createElement('div');
          divider.className = 'day';
          divider.textContent = new Date(record.eventDate).toLocaleDateString(undefined, { dateStyle: 'full' });
          recordsEl.appendChild(divider);
          lastDay = day;
        }
        recordsEl.appendChild(renderRecord(record));
      }
    }

    function renderRarityFilter(rarities) {
      const wrap = document.createElement('div');
      wrap.className = 'rarity-filter';
      const all = document.createElement('button');
      all.type = 'button';
      all.textContent = 'All';
      all.className = state.rarity === 'all' ? 'active' : '';
      all.addEventListener('click', () => { state.rarity = 'all'; renderPage(); });
      wrap.appendChild(all);

      for (const rarity of rarities) {
        const button = document.createElement('button');
        button.type = 'button';
        if (rarity.hasBadge) {
          button.appendChild(renderRarityGlyph(rarity));
        }
        button.appendChild(document.createTextNode(\`\${rarity.name} \${rarity.count}\`));
        if (rarity.isCommon) button.dataset.common = 'true';
        button.title = rarity.patternLabel || rarity.name;
        button.style.setProperty('--rarity-color', rarity.color || '#e8edf3');
        button.className = state.rarity === rarity.id ? 'active' : '';
        button.addEventListener('click', () => { state.rarity = rarity.id; renderPage(); });
        wrap.appendChild(button);
      }
      return wrap;
    }

    function renderSelect(kind, label, options, titleForOption) {
      const select = document.createElement('select');
      select.setAttribute('aria-label', label);

      const all = document.createElement('option');
      all.value = 'all';
      all.textContent = label === 'Saros' ? 'All Saros families' : \`All \${label.toLowerCase()}s\`;
      select.appendChild(all);

      for (const option of options) {
        const node = document.createElement('option');
        node.value = option.id;
        node.textContent = titleForOption(option).trim();
        select.appendChild(node);
      }

      select.value = state[kind];
      select.addEventListener('change', () => {
        state[kind] = select.value;
        renderPage();
      });
      return select;
    }

    function filteredRecords(records) {
      return records.filter((record) => {
        if (state.rarity !== 'all' && record.rarity?.key !== state.rarity) return false;
        if (state.saros !== 'all' && !(record.sarosNumbers || []).map(String).includes(state.saros)) return false;
        if (state.tag !== 'all' && !(record.tags || []).some((tag) => (tag.filterID || tag.displayKey || tag.id) === state.tag)) return false;
        return true;
      });
    }

    function renderRecord(record) {
      const node = document.createElement('article');
      node.className = 'record';
      const emoji = document.createElement('div');
      emoji.className = 'emoji';
      emoji.textContent = record.emoji || '✦';
      const body = document.createElement('div');
      const side = document.createElement('div');
      side.className = 'record-side';
      const primarySpike = (record.spikes || [])[0] || record;
      side.appendChild(renderOctalGlyph(
        primarySpike.octalAddress || record.octalAddress,
        primarySpike.harmonicDepth || record.harmonicDepth || 7,
        primarySpike.rarity?.color || record.rarity?.color || '#f3f5f7'
      ));

      const rarityBadge = record.rarity?.hasBadge
        ? \`<span class="badge rarity" title="\${escapeHTML(record.rarity.patternLabel || '')}" style="--rarity-color: \${escapeHTML(record.rarity.color || '#f3f5f7')}">\${escapeHTML(record.rarity.title)}</span>\`
        : '';
      body.innerHTML = \`
        <div class="record-head">
          <div class="title" style="color: \${escapeHTML(record.rarity?.color || '#f3f5f7')}">\${escapeHTML(record.title || 'Record')}</div>
          \${rarityBadge}
        </div>
        <div class="sub">\${new Date(record.eventDate).toLocaleString()} · \${(record.sarosNumbers || []).map((saros) => \`Saros \${saros}\`).join(' · ')}</div>
      \`;
      body.appendChild(renderSpikeStrip(record.spikes || []));
      if (record.text) {
        const text = document.createElement('div');
        text.className = 'text';
        text.textContent = record.text;
        body.appendChild(text);
      }
      if (record.media?.length) {
        body.appendChild(renderMedia(record.media));
      }
      if (record.tags?.length) {
        const tags = document.createElement('div');
        tags.className = 'tags';
        for (const tag of record.tags) {
          const tagNode = document.createElement('span');
          tagNode.className = 'tag';
          tagNode.title = tag.name || '';
          tagNode.textContent = tag.emoji || '◇';
          tags.appendChild(tagNode);
        }
        body.appendChild(tags);
      }
      node.append(emoji, body, side);
      return node;
    }

    function renderSpikeStrip(spikes) {
      const wrap = document.createElement('div');
      wrap.className = 'spikes';
      for (const spike of spikes.slice(0, 4)) {
        const node = document.createElement('div');
        node.className = 'spike';
        node.appendChild(renderOctalGlyph(
          spike.octalAddress,
          spike.harmonicDepth || 7,
          spike.rarity?.color || '#f3f5f7'
        ));
        const label = document.createElement('div');
        label.textContent = spike.saros || '';
        node.appendChild(label);
        wrap.appendChild(node);
      }
      return wrap;
    }

    function renderMedia(media) {
      const wrap = document.createElement('div');
      wrap.className = 'media';
      for (const item of media) {
        if (item.type === 'photo' || item.type === 'symbolicPhoto') {
          const button = document.createElement('button');
          button.type = 'button';
          button.className = 'media-preview';
          button.setAttribute('aria-label', 'Open image preview');
          const image = document.createElement('img');
          image.src = item.url;
          image.loading = 'lazy';
          button.appendChild(image);
          button.addEventListener('click', () => openMediaPreview(item.url, 'image'));
          wrap.appendChild(button);
        } else if (item.type === 'video') {
          const button = document.createElement('button');
          button.type = 'button';
          button.className = 'media-preview';
          button.setAttribute('aria-label', 'Open video preview');
          const video = document.createElement('video');
          video.src = item.url;
          video.muted = true;
          video.playsInline = true;
          video.preload = 'metadata';
          button.appendChild(video);
          button.addEventListener('click', () => openMediaPreview(item.url, 'video'));
          wrap.appendChild(button);
        } else if (item.type === 'audio') {
          const audio = document.createElement('audio');
          audio.src = item.url;
          audio.controls = true;
          wrap.appendChild(audio);
        }
      }
      return wrap;
    }

    function renderRarityGlyph(rarity) {
      const address = rarity.glyphAddress || '0';
      const glyph = renderOctalGlyph(address, address.length || 7, rarity.color || '#f3f5f7');
      glyph.classList.add('rarity-glyph');
      glyph.title = rarity.patternLabel || rarity.name || address;
      return glyph;
    }

    function renderOctalGlyph(value, depth, color) {
      const glyph = document.createElement('div');
      glyph.className = 'glyph';
      glyph.style.setProperty('--rarity-color', color || '#f3f5f7');
      glyph.title = normalizeOctalGlyphValue(value, depth);
      const size = Math.max(3, Math.min(Number(depth) || 7, 8));
      glyph.dataset.digitOrder = counterclockwiseDigitOrder(size).join(',');

      if (globalThis.OctalGlyph?.renderSvg) {
        glyph.innerHTML = globalThis.OctalGlyph.renderSvg(glyph.title, {
          digitsPerGlyph: size,
          inputBase: 'octal',
          font: counterclockwiseGlyphFont(size),
          fill: 'currentColor',
          paddingCells: 3,
          precision: 2
        });
      } else {
        glyph.innerHTML = fallbackGlyphSvg(glyph.title);
      }

      return glyph;
    }

    function counterclockwiseGlyphFont(size) {
      if (!globalThis.OctalGlyph?.DEFAULT_FONT) return undefined;
      if (glyphFontCache.has(size)) return glyphFontCache.get(size);

      const font = JSON.parse(JSON.stringify(globalThis.OctalGlyph.DEFAULT_FONT));
      const key = String(size);
      const species = font.species?.[key] || {};
      font.species = font.species || {};
      font.species[key] = {
        ...species,
        digitOrder: counterclockwiseDigitOrder(size)
      };
      glyphFontCache.set(size, font);
      return font;
    }

    function counterclockwiseDigitOrder(size) {
      return [0, ...Array.from({ length: Math.max(0, size - 1) }, (_, index) => size - index - 1)];
    }

    function normalizeOctalGlyphValue(value, depth) {
      const size = Math.max(3, Math.min(Number(depth) || 7, 8));
      const clean = String(value || '0').replace(/[^0-7]/g, '');
      return (clean || '0').padStart(size, '0').slice(-size);
    }

    function fallbackGlyphSvg(value) {
      const digits = normalizeOctalGlyphValue(value, 7).split('');
      const center = 50;
      const coreRadius = 13;
      const socketRadius = 35;
      const arms = digits.map((digit, index) => {
        const angle = -Math.PI / 2 - (index * 2 * Math.PI / digits.length);
        const reach = socketRadius + Number(digit) * 4;
        const x = center + Math.cos(angle) * reach;
        const y = center + Math.sin(angle) * reach;
        return \`<line x1="\${center}" y1="\${center}" x2="\${x.toFixed(2)}" y2="\${y.toFixed(2)}" stroke="currentColor" stroke-width="7" stroke-linecap="round"/>\`;
      }).join('');
      return \`<svg class="glyph-fallback" viewBox="0 0 100 100" aria-hidden="true">\${arms}<circle cx="50" cy="50" r="\${coreRadius}" fill="currentColor"/></svg>\`;
    }

    function openMediaPreview(url, type) {
      if (type === 'video') {
        lightboxImage.hidden = true;
        lightboxImage.removeAttribute('src');
        lightboxVideo.hidden = false;
        lightboxVideo.src = url;
      } else {
        lightboxVideo.pause();
        lightboxVideo.hidden = true;
        lightboxVideo.removeAttribute('src');
        lightboxImage.hidden = false;
        lightboxImage.src = url;
      }
      lightbox.hidden = false;
      lightboxClose.focus();
    }

    function closeMediaPreview() {
      lightbox.hidden = true;
      lightboxVideo.pause();
      lightboxVideo.hidden = true;
      lightboxVideo.removeAttribute('src');
      lightboxImage.hidden = false;
      lightboxImage.removeAttribute('src');
    }

    function dayKey(value) {
      const date = new Date(value);
      return [date.getFullYear(), date.getMonth(), date.getDate()].join('-');
    }

    function escapeHTML(value) {
      return String(value).replace(/[&<>"']/g, (char) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[char]));
    }
  </script>
</body>
</html>`;
}

function datasetPageHTML() {
  return `<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Exeligmos Dataset</title>
  <style>
    :root { color-scheme: dark; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
    body { margin: 0; background: #0b0d10; color: #f3f5f7; }
    header { position: sticky; top: 0; z-index: 2; background: rgba(11,13,16,.92); backdrop-filter: blur(14px); padding: 18px 20px; border-bottom: 1px solid #222832; }
    h1 { margin: 0 0 6px; font-size: 22px; }
    .meta { color: #95a0ad; font-size: 13px; }
    nav { margin-top: 10px; display: flex; gap: 8px; flex-wrap: wrap; }
    nav a, .filters button { color: #f3f5f7; text-decoration: none; background: #1b222c; border: 1px solid #2d3946; border-radius: 8px; padding: 7px 10px; font: inherit; font-size: 13px; cursor: pointer; }
    .filters button.active { background: #e8edf3; color: #0b0d10; border-color: #e8edf3; }
    main { max-width: 1100px; margin: 0 auto; padding: 20px; }
    .filters { display: flex; gap: 8px; flex-wrap: wrap; margin-bottom: 16px; }
    .dataset-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(176px, 1fr)); gap: 12px; }
    .dataset-item { overflow: hidden; border: 1px solid #232a34; border-radius: 10px; background: #11151b; }
    .dataset-item img { width: 100%; aspect-ratio: 1; object-fit: cover; display: block; background: #050607; }
    .dataset-body { padding: 10px; }
    .rarity { font-weight: 850; text-transform: capitalize; }
    .rarity.common { color: #aeb5bf; }
    .rarity.rare { color: #67d7ff; }
    .rarity.epic { color: #c084fc; }
    .rarity.legendary { color: #f5c84b; }
    .rarity.mythic { color: #ff6161; }
    .sub { color: #9ca6b3; font-size: 12px; margin-top: 4px; }
    .empty { color: #95a0ad; padding: 40px 0; text-align: center; }
  </style>
</head>
<body>
  <header>
    <h1>Animacy Dataset</h1>
    <div class="meta" id="status">Loading dataset...</div>
    <nav><a href="/">Records</a></nav>
  </header>
  <main>
    <div class="filters" id="filters"></div>
    <section class="dataset-grid" id="dataset"></section>
  </main>
  <script>
    const status = document.getElementById('status');
    const filtersEl = document.getElementById('filters');
    const datasetEl = document.getElementById('dataset');
    let activeFilter = 'all';
    let dataset = { items: [], rarities: [] };

    fetch('/api/animacy/dataset')
      .then((response) => response.json())
      .then((data) => {
        dataset = data;
        status.textContent = \`\${data.captureCount || 0} captures · \${data.datasetItemCount || 0} samples\`;
        renderFilters();
        renderDataset();
      })
      .catch((error) => {
        status.textContent = error.message;
      });

    function renderFilters() {
      const rarities = ['all', ...(dataset.rarities || [])];
      filtersEl.innerHTML = '';
      for (const rarity of rarities) {
        const button = document.createElement('button');
        button.type = 'button';
        button.className = rarity === activeFilter ? 'active' : '';
        const count = rarity === 'all'
          ? dataset.items.length
          : (dataset.rarityCounts?.[rarity] || 0);
        button.textContent = \`\${title(rarity)} \${count}\`;
        button.addEventListener('click', () => {
          activeFilter = rarity;
          renderFilters();
          renderDataset();
        });
        filtersEl.appendChild(button);
      }
    }

    function renderDataset() {
      const items = activeFilter === 'all'
        ? dataset.items
        : dataset.items.filter((item) => item.rarity === activeFilter);
      datasetEl.innerHTML = '';
      if (!items.length) {
        datasetEl.innerHTML = '<div class="empty">No samples for this rarity.</div>';
        return;
      }
      for (const item of items) {
        datasetEl.appendChild(renderDatasetItem(item));
      }
    }

    function renderDatasetItem(item) {
      const node = document.createElement('article');
      node.className = 'dataset-item';

      const image = document.createElement('img');
      image.src = item.datasetImageURL;
      image.loading = 'lazy';

      const body = document.createElement('div');
      body.className = 'dataset-body';
      body.innerHTML = \`
        <div class="rarity \${escapeHTML(item.rarity || 'common')}">\${escapeHTML(title(item.rarity || 'common'))}</div>
        <div class="sub">\${escapeHTML(item.mirrorMode || '')}\${item.reflectedSide ? \` · \${escapeHTML(item.reflectedSide)}\` : ''}</div>
      \`;

      node.append(image, body);
      return node;
    }

    function title(value) {
      return String(value || '').replace(/(^|-)([a-z])/g, (_, sep, char) => (sep ? ' ' : '') + char.toUpperCase());
    }

    function escapeHTML(value) {
      return String(value).replace(/[&<>"']/g, (char) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[char]));
    }
  </script>
</body>
</html>`;
}

function sendJSON(res, status, value) {
  send(res, status, 'application/json; charset=utf-8', JSON.stringify(value));
}

function send(res, status, contentType, body) {
  const bytes = Buffer.isBuffer(body) ? body : Buffer.from(String(body), 'utf8');
  res.writeHead(status, {
    'Content-Type': contentType,
    'Content-Length': bytes.length,
    'Content-Disposition': 'inline',
    'X-Content-Type-Options': 'nosniff',
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type',
    'Cache-Control': 'no-store'
  });
  res.end(bytes);
}

function safeRelativePath(value) {
  return String(value || '')
    .replaceAll('\\\\', '/')
    .split('/')
    .filter((part) => part && part !== '.' && part !== '..')
    .join('/');
}

function safeAnimacyRelativePath(value) {
  return String(value || '')
    .replaceAll('\\\\', '/')
    .split('/')
    .filter((part) => part && part !== '.' && part !== '..')
    .join('/');
}

function safeFileName(value) {
  return path.basename(String(value || 'file.bin').replaceAll('\\\\', '/')) || 'file.bin';
}

function safeFolderName(value) {
  const cleaned = String(value || 'item')
    .normalize('NFKD')
    .replace(/[^\w.-]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 96);
  return cleaned || 'item';
}

function encodePath(value) {
  return safeRelativePath(value).split('/').map(encodeURIComponent).join('/');
}

function encodeAnimacyPath(value) {
  return safeAnimacyRelativePath(value).split('/').map(encodeURIComponent).join('/');
}

function contentTypeForPath(filePath) {
  const ext = path.extname(filePath).toLowerCase();
  if (ext === '.json') return 'application/json';
  if (ext === '.jpg' || ext === '.jpeg') return 'image/jpeg';
  if (ext === '.png') return 'image/png';
  if (ext === '.m4a') return 'audio/mp4';
  if (ext === '.mov') return 'video/quicktime';
  if (ext === '.mp4') return 'video/mp4';
  return 'application/octet-stream';
}

function extensionForContentType(contentType) {
  const value = String(contentType || '').toLowerCase();
  if (value.includes('jpeg') || value.includes('jpg')) return '.jpg';
  if (value.includes('png')) return '.png';
  if (value.includes('quicktime')) return '.mov';
  if (value.includes('mp4') && value.includes('video')) return '.mp4';
  if (value.includes('mp4') && value.includes('audio')) return '.m4a';
  if (value.includes('caf')) return '.caf';
  return '';
}

function localAddresses() {
  const addresses = [];
  for (const entries of Object.values(os.networkInterfaces())) {
    for (const entry of entries || []) {
      if (entry.family === 'IPv4' && !entry.internal) {
        addresses.push(entry.address);
      }
    }
  }
  return addresses.length ? addresses : ['127.0.0.1'];
}

function formatBytes(bytes) {
  const units = ['B', 'KB', 'MB', 'GB'];
  let value = bytes;
  let unitIndex = 0;
  while (value >= 1024 && unitIndex < units.length - 1) {
    value /= 1024;
    unitIndex += 1;
  }
  return `${value.toFixed(unitIndex === 0 ? 0 : 1)} ${units[unitIndex]}`;
}
