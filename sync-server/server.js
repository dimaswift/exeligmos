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
const RARITY_DEFINITIONS = {
  common: { key: 'common', title: 'Common', rank: 2, color: '#8f98a3' },
  rare: { key: 'rare', title: 'Rare', rank: 3, color: '#2f9bff' },
  epic: { key: 'epic', title: 'Epic', rank: 4, color: '#b45cff' },
  legendary: { key: 'legendary', title: 'Legendary', rank: 5, color: '#f4c542' },
  mythic: { key: 'mythic', title: 'Mythic', rank: 6, color: '#ef4136' },
  saros1: { key: 'saros1', title: 'Saros 1', rank: 7, color: '#ff3b30' },
  saros2: { key: 'saros2', title: 'Saros 2', rank: 8, color: '#ff9500' },
  saros3: { key: 'saros3', title: 'Saros 3', rank: 9, color: '#ffd60a' },
  saros4: { key: 'saros4', title: 'Saros 4', rank: 10, color: '#30d158' },
  saros5: { key: 'saros5', title: 'Saros 5', rank: 11, color: '#40c8e0' },
  saros6: { key: 'saros6', title: 'Saros 6', rank: 12, color: '#0a84ff' },
  saros7: { key: 'saros7', title: 'Saros 7', rank: 13, color: '#bf5af2' }
};

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
        entityCount: payload?.archive?.entities?.length ?? 0,
        recordCount: payload?.archive?.records?.length ?? 0,
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
      sendJSON(res, 200, payload ? recordsView(payload) : { threads: [], records: [] });
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

    if (req.method === 'POST' && url.pathname === '/api/sync/thread') {
      const body = await readBody(req);
      const payload = JSON.parse(body);
      const result = await writeThreadPayload(payload);
      console.log(`Stored thread ${result.threadID} in ${result.threadFolder}.`);
      sendJSON(res, 200, { ok: true, ...result });
      return;
    }

    if (req.method === 'POST' && url.pathname === '/api/sync/record') {
      const body = await readBody(req);
      const payload = JSON.parse(body);
      const result = await writeRecordPayload(payload);
      console.log(`Stored record ${result.recordID} in ${result.recordFolder} with ${result.mediaCount} media files.`);
      sendJSON(res, 200, { ok: true, ...result });
      return;
    }

    if (req.method === 'POST' && url.pathname === '/api/backups') {
      const body = await readBody(req);
      const payload = JSON.parse(body);
      await writeBackup(payload);
      console.log(`Stored backup with ${payload.archive?.records?.length ?? 0} records and ${payload.media?.length ?? 0} media blobs.`);
      sendJSON(res, 200, {
        ok: true,
        exportTimestamp: payload.exportTimestamp,
        entityCount: payload.archive?.entities?.length ?? 0,
        recordCount: payload.archive?.records?.length ?? 0,
        mediaCount: payload.media?.length ?? 0
      });
      return;
    }

    if (req.method === 'POST' && url.pathname === '/api/backups/delta') {
      const body = await readBody(req);
      const deltaPayload = JSON.parse(body);
      await writeBackup(deltaPayload);
      console.log(`Merged delta with ${deltaPayload.archive?.records?.length ?? 0} records and ${deltaPayload.media?.length ?? 0} media blobs.`);
      sendJSON(res, 200, {
        ok: true,
        exportTimestamp: new Date().toISOString(),
        addedRecordCount: deltaPayload.archive?.records?.length ?? 0,
        addedMediaCount: deltaPayload.media?.length ?? 0,
        entityCount: deltaPayload.archive?.entities?.length ?? 0,
        recordCount: deltaPayload.archive?.records?.length ?? 0,
        mediaCount: deltaPayload.media?.length ?? 0
      });
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

async function writeBackup(payload) {
  validatePayload(payload);

  const groups = new Map((payload.archive?.threadGroups ?? []).map((group) => [group.id, group]));
  const threads = new Map((payload.archive?.entities ?? []).map((thread) => [thread.id, thread]));
  const media = new Map((payload.media ?? []).map((blob) => [blob.id, blob]));

  for (const group of groups.values()) {
    await writeGroupSnapshot(group);
  }

  for (const thread of threads.values()) {
    await writeThreadPayload({
      schemaVersion: 1,
      appVersion: payload.appVersion,
      uploadedAt: payload.exportTimestamp,
      group: groups.get(thread.groupID) ?? null,
      thread
    });
  }

  for (const record of payload.archive?.records ?? []) {
    const thread = threads.get(record.entityID);
    if (!thread) continue;
    const recordMedia = (record.mediaItems ?? [])
      .map((item) => media.get(item.id))
      .filter(Boolean);
    await writeRecordPayload({
      schemaVersion: 1,
      appVersion: payload.appVersion,
      uploadedAt: payload.exportTimestamp,
      group: groups.get(thread.groupID) ?? null,
      thread,
      record,
      media: recordMedia
    });
  }
}

function validatePayload(payload) {
  if (!payload || payload.schemaVersion !== 1 || !payload.archive) {
    throw new Error('Invalid Exeligmos sync payload.');
  }
}

async function writeThreadPayload(payload) {
  validateThreadPayload(payload);

  if (payload.group) {
    await writeGroupSnapshot(payload.group);
  }

  const threadDir = await threadDirectoryFor(payload.thread);
  await fs.mkdir(path.join(threadDir, 'records'), { recursive: true });
  await writeJSONAtomic(path.join(threadDir, 'thread.json'), payload.thread);

  return {
    threadID: payload.thread.id,
    threadFolder: path.basename(threadDir)
  };
}

async function writeRecordPayload(payload) {
  validateRecordPayload(payload);

  const threadResult = await writeThreadPayload({
    schemaVersion: 1,
    appVersion: payload.appVersion,
    uploadedAt: payload.uploadedAt,
    group: payload.group,
    thread: payload.thread
  });

  const threadDir = path.join(DATA_DIR, 'threads', threadResult.threadFolder);
  const recordDir = await recordDirectoryFor(threadDir, payload.record);
  const mediaDir = path.join(recordDir, 'media');
  await fs.mkdir(recordDir, { recursive: true });
  await fs.rm(mediaDir, { recursive: true, force: true });
  await fs.mkdir(mediaDir, { recursive: true });

  const mediaMetadata = [];
  for (const blob of payload.media ?? []) {
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

  await writeJSONAtomic(path.join(recordDir, 'record.json'), payload.record);
  await writeJSONAtomic(path.join(recordDir, 'media.json'), mediaMetadata);

  return {
    threadID: payload.thread.id,
    threadFolder: threadResult.threadFolder,
    recordID: payload.record.id,
    recordFolder: path.basename(recordDir),
    mediaCount: mediaMetadata.length
  };
}

async function writeGroupSnapshot(group) {
  if (!group?.id) return;
  const groupDir = path.join(DATA_DIR, 'groups', safeFileName(group.id));
  await fs.mkdir(groupDir, { recursive: true });
  await writeJSONAtomic(path.join(groupDir, 'group.json'), group);
}

function validateThreadPayload(payload) {
  if (!payload || payload.schemaVersion !== 1 || !payload.thread?.id) {
    throw new Error('Invalid Exeligmos thread sync payload.');
  }
}

function validateRecordPayload(payload) {
  if (!payload || payload.schemaVersion !== 1 || !payload.thread?.id || !payload.record?.id) {
    throw new Error('Invalid Exeligmos record sync payload.');
  }
}

async function threadDirectoryFor(thread) {
  const root = path.join(DATA_DIR, 'threads');
  await fs.mkdir(root, { recursive: true });

  const existing = await findChildDirectoryByJSON(root, 'thread.json', (value) => value?.id === thread.id);
  if (existing) return existing;

  return path.join(root, threadFolderName(thread));
}

async function recordDirectoryFor(threadDir, record) {
  const root = path.join(threadDir, 'records');
  await fs.mkdir(root, { recursive: true });

  const existing = await findChildDirectoryByJSON(root, 'record.json', (value) => value?.id === record.id);
  if (existing) return existing;

  const base = recordFolderName(record);
  const preferred = path.join(root, base);
  const preferredRecord = await readJSONIfExists(path.join(preferred, 'record.json'));
  if (!preferredRecord || preferredRecord.id === record.id) {
    return preferred;
  }

  return path.join(root, `${base}-${String(record.id).slice(0, 8)}`);
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
  const hasState = (payload.archive.threadGroups.length + payload.archive.entities.length + payload.archive.records.length) > 0;
  return hasState ? payload : null;
}

async function readFolderPayload({ includeMediaData = false } = {}) {
  const threadGroups = await readGroupSnapshots();
  const { entities, records, media, latestModifiedAt } = await readThreadSnapshots(includeMediaData);
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
      records
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
  return { entities, records, media, latestModifiedAt };
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

function threadFolderName(thread) {
  const title = slug(thread.title || 'untitled');
  const saros = Number.isFinite(Number(thread.saros)) ? `saros-${thread.saros}` : 'saros';
  return safeFolderName(`${saros}-${title}-${String(thread.id).slice(0, 8)}`);
}

function recordFolderName(record) {
  return safeFolderName(record.octalAddress || unixOctal(record.eventDate) || String(record.id).slice(0, 8));
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
  return {
    ok: true,
    hasBackup: Boolean(payload),
    exportTimestamp: payload?.exportTimestamp ?? null,
    entityIDs: (payload?.archive?.entities ?? []).map((entity) => entity.id),
    recordIDs: (payload?.archive?.records ?? []).map((record) => record.id),
    mediaIDs: (payload?.media ?? []).map((blob) => blob.id)
  };
}

function recordsView(payload) {
  const entities = new Map((payload.archive.entities ?? []).map((entity) => [entity.id, entity]));
  const groups = new Map((payload.archive.threadGroups ?? []).map((group) => [group.id, group]));
  const media = new Map((payload.media ?? []).map((blob) => [blob.id, blob]));
  const records = [...(payload.archive.records ?? [])]
    .sort((a, b) => new Date(b.eventDate).getTime() - new Date(a.eventDate).getTime())
    .map((record) => {
      const entity = entities.get(record.entityID);
      const group = entity?.groupID ? groups.get(entity.groupID) : null;
      const rarity = rarityForRecord(record);
      return {
        id: record.id,
        entityID: record.entityID,
        entityTitle: entity?.title || 'Untitled thread',
        entityEmoji: entity?.emoji ?? null,
        groupID: group?.id ?? 'common',
        groupName: group?.name || 'Common',
        groupEmoji: group?.emoji || '○',
        eventDate: record.eventDate,
        emoji: record.emoji,
        text: record.text,
        saros: record.saros,
        octalAddress: record.octalAddress,
        harmonicDepth: record.harmonicDepth ?? 7,
        rarity,
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
    });
  const threads = [...entities.values()]
    .map((entity) => {
      const threadRecords = records.filter((record) => record.entityID === entity.id);
      const group = entity.groupID ? groups.get(entity.groupID) : null;
      return {
        id: entity.id,
        title: entity.title || 'Untitled thread',
        emoji: entity.emoji,
        groupID: group?.id ?? 'common',
        groupName: group?.name || 'Common',
        saros: entity.saros,
        recordCount: threadRecords.length,
        latestRecordDate: threadRecords[0]?.eventDate ?? null,
        records: threadRecords
      };
    })
    .filter((thread) => thread.recordCount > 0)
    .sort((a, b) => new Date(b.latestRecordDate).getTime() - new Date(a.latestRecordDate).getTime());
  const groupFilters = groupedFilterOptions(records, 'groupID', (record) => ({
    id: record.groupID,
    name: record.groupName,
    emoji: record.groupEmoji
  }));
  const rarityFilters = groupedFilterOptions(records, 'rarityKey', (record) => ({
    id: record.rarity.key,
    name: record.rarity.title,
    rank: record.rarity.rank,
    color: record.rarity.color
  })).sort((a, b) => a.rank - b.rank);

  return {
    exportTimestamp: payload.exportTimestamp,
    entityCount: payload.archive.entities?.length ?? 0,
    recordCount: records.length,
    mediaCount: payload.media?.length ?? 0,
    threads,
    groups: groupFilters,
    rarities: rarityFilters,
    records
  };
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

function rarityForRecord(record) {
  const depth = Math.max(1, Math.min(Number(record.harmonicDepth) || 7, 8));
  const address = String(record.octalAddress || '').padStart(depth, '0').slice(-depth);
  const repeated = repeatedSarosDigit(address);
  if (repeated) {
    return rarityDefinition(`saros${repeated}`);
  }

  const trailingZeroes = [...address].reverse().findIndex((digit) => digit !== '0');
  const order = trailingZeroes === -1 ? depth : trailingZeroes;

  if (order >= 7) return rarityDefinition('saros7');
  if (order >= 6) return rarityDefinition('mythic');
  if (order >= 5) return rarityDefinition('legendary');
  if (order >= 4) return rarityDefinition('epic');
  if (order >= 3) return rarityDefinition('rare');
  return rarityDefinition('common');
}

function repeatedSarosDigit(address) {
  if (!address || address.length < 7) return null;
  const first = address[0];
  if (first === '0' || first === '8' || first === '9') return null;
  return address.split('').every((digit) => digit === first) ? first : null;
}

function rarityDefinition(key) {
  return RARITY_DEFINITIONS[key] ?? RARITY_DEFINITIONS.common;
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
    header { position: sticky; top: 0; z-index: 2; background: rgba(11,13,16,.94); backdrop-filter: blur(14px); padding: 18px 20px; border-bottom: 1px solid #222832; }
    h1 { margin: 0 0 6px; font-size: 22px; }
    .meta { color: #95a0ad; font-size: 13px; }
    main { max-width: 980px; margin: 0 auto; padding: 18px 20px 40px; }
    nav { margin-top: 10px; display: flex; gap: 8px; flex-wrap: wrap; }
    nav a { color: #f3f5f7; text-decoration: none; background: #1b222c; border: 1px solid #2d3946; border-radius: 8px; padding: 7px 10px; font-size: 13px; }
    .filters { display: grid; gap: 10px; grid-template-columns: minmax(0, 1fr) minmax(150px, 220px) minmax(150px, 220px); margin-bottom: 18px; }
    .rarity-filter { display: flex; gap: 8px; overflow-x: auto; padding-bottom: 2px; }
    button, select { color: #f3f5f7; background: #121820; border: 1px solid #2b3541; border-radius: 8px; font: inherit; font-size: 13px; }
    button { padding: 8px 10px; cursor: pointer; white-space: nowrap; }
    button.active { background: var(--rarity-color, #e8edf3); border-color: var(--rarity-color, #e8edf3); color: #071018; }
    select { min-width: 0; padding: 8px 10px; }
    .day { margin: 22px 0 10px; color: #8f98a3; font-size: 12px; font-weight: 800; letter-spacing: .08em; text-transform: uppercase; }
    .record { display: grid; grid-template-columns: minmax(0, 1fr) 86px; gap: 14px; padding: 16px; margin-top: 10px; border: 1px solid #232a34; border-radius: 10px; background: #11151b; }
    .record-head { display: flex; gap: 10px; align-items: baseline; flex-wrap: wrap; }
    .title { font-weight: 800; font-size: 17px; }
    .sub { color: #9ca6b3; font-size: 13px; margin-top: 6px; }
    .badge { display: inline-flex; align-items: center; gap: 6px; border: 1px solid #2d3946; border-radius: 999px; padding: 4px 8px; color: #c8d0d9; font-size: 12px; }
    .rarity { border-color: color-mix(in srgb, var(--rarity-color), transparent 45%); color: var(--rarity-color); background: color-mix(in srgb, var(--rarity-color), transparent 88%); }
    .record-side { display: grid; gap: 8px; justify-items: center; align-content: start; }
    .glyph { width: 76px; height: 76px; display: grid; place-items: center; color: var(--rarity-color, #8f98a3); }
    .glyph svg { width: 100%; height: 100%; display: block; overflow: visible; }
    .glyph path, .glyph polygon, .glyph circle { fill: currentColor; }
    .glyph-fallback { width: 72px; height: 72px; }
    .emoji { font-size: 30px; line-height: 1; }
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
      .filters { grid-template-columns: 1fr; }
      .record { grid-template-columns: minmax(0, 1fr) 72px; }
      .glyph { width: 64px; height: 64px; }
      .emoji { font-size: 26px; }
      audio { width: 100%; }
      .media img, .media video { width: calc(50vw - 34px); height: calc(50vw - 34px); }
    }
  </style>
</head>
<body>
  <header>
    <h1>Exeligmos Sync</h1>
    <div class="meta" id="status">Loading synced folders...</div>
    <nav><a href="/dataset">Dataset</a></nav>
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
    const state = { rarity: 'all', thread: 'all', group: 'all', data: null };
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
          ? \`Folder state: \${new Date(data.exportTimestamp).toLocaleString()} · \${data.entityCount} threads · \${data.recordCount} records · \${data.mediaCount} media\`
          : 'No synced records yet. Upload from the iOS app Settings screen.';
        state.data = data;
        renderPage();
      })
      .catch((error) => {
        status.textContent = error.message;
      });

    function renderPage() {
      const data = state.data || { records: [], threads: [], groups: [], rarities: [] };
      recordsEl.innerHTML = '';

      const filters = document.createElement('section');
      filters.className = 'filters';
      filters.append(renderRarityFilter(data.rarities || []));
      filters.append(renderSelect('thread', 'Thread', data.threads || [], (thread) => \`\${thread.emoji || ''} \${thread.title || 'Untitled thread'} (\${thread.recordCount})\`));
      filters.append(renderSelect('group', 'Group', data.groups || [], (group) => \`\${group.emoji || ''} \${group.name || 'Common'} (\${group.count})\`));
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
        button.textContent = \`\${rarity.name} \${rarity.count}\`;
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
      all.textContent = \`All \${label.toLowerCase()}s\`;
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
        if (state.thread !== 'all' && record.entityID !== state.thread) return false;
        if (state.group !== 'all' && record.groupID !== state.group) return false;
        return true;
      });
    }

    function renderRecord(record) {
      const node = document.createElement('article');
      node.className = 'record';
      const body = document.createElement('div');
      const side = document.createElement('div');
      side.className = 'record-side';
      side.appendChild(renderOctalGlyph(record.octalAddress, record.harmonicDepth || 7, record.rarity?.color || '#8f98a3'));
      const emoji = document.createElement('div');
      emoji.className = 'emoji';
      emoji.textContent = record.emoji || '✦';
      side.appendChild(emoji);

      body.innerHTML = \`
        <div class="record-head">
          <div class="title">\${escapeHTML(record.entityTitle)}</div>
          <span class="badge rarity" style="--rarity-color: \${escapeHTML(record.rarity?.color || '#8f98a3')}">\${escapeHTML(record.rarity?.title || 'Common')}</span>
          <span class="badge">\${escapeHTML(record.groupEmoji || '○')} \${escapeHTML(record.groupName || 'Common')}</span>
        </div>
        <div class="sub">\${new Date(record.eventDate).toLocaleString()} · Saros \${record.saros} · \${record.octalAddress}</div>
      \`;
      if (record.text) {
        const text = document.createElement('div');
        text.className = 'text';
        text.textContent = record.text;
        body.appendChild(text);
      }
      if (record.media?.length) {
        body.appendChild(renderMedia(record.media));
      }
      node.append(body, side);
      return node;
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

    function renderOctalGlyph(value, depth, color) {
      const glyph = document.createElement('div');
      glyph.className = 'glyph';
      glyph.style.setProperty('--rarity-color', color || '#8f98a3');
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

function slug(value) {
  return safeFolderName(value).toLowerCase() || 'untitled';
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

function unixOctal(value) {
  const time = new Date(value).getTime();
  if (!Number.isFinite(time)) return '';
  return Math.floor(time / 1000).toString(8);
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
