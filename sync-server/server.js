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

    if (req.method === 'GET' && url.pathname === '/favicon.ico') {
      send(res, 204, 'image/x-icon', '');
      return;
    }

    if (req.method === 'GET' && (url.pathname === '/api/status' || url.pathname === '/health')) {
      const payload = await readLatestPayload();
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
      const payload = await readLatestPayload();
      sendJSON(res, 200, manifestView(payload));
      return;
    }

    if (req.method === 'GET' && url.pathname === '/api/records') {
      const payload = await readLatestPayload();
      sendJSON(res, 200, payload ? recordsView(payload) : { threads: [], records: [] });
      return;
    }

    if (req.method === 'GET' && url.pathname === '/api/backups/latest') {
      const payload = await readLatestPayload();
      if (!payload) {
        sendJSON(res, 404, { error: 'No backup has been pushed yet.' });
        return;
      }
      sendJSON(res, 200, payload);
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
      const latestPayload = await readLatestPayload();
      const payload = mergeBackupPayload(latestPayload, deltaPayload);
      await writeBackup(payload);
      console.log(`Merged delta with ${deltaPayload.archive?.records?.length ?? 0} records and ${deltaPayload.media?.length ?? 0} media blobs.`);
      sendJSON(res, 200, {
        ok: true,
        exportTimestamp: payload.exportTimestamp,
        addedRecordCount: deltaPayload.archive?.records?.length ?? 0,
        addedMediaCount: deltaPayload.media?.length ?? 0,
        entityCount: payload.archive?.entities?.length ?? 0,
        recordCount: payload.archive?.records?.length ?? 0,
        mediaCount: payload.media?.length ?? 0
      });
      return;
    }

    if (req.method === 'GET' && url.pathname.startsWith('/media/')) {
      await serveMedia(url.pathname.slice('/media/'.length), res);
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

  const stamp = timestamp();
  const backupDir = path.join(DATA_DIR, 'backups', stamp);
  const latestDir = path.join(DATA_DIR, 'latest');
  await fs.rm(latestDir, { recursive: true, force: true });
  await fs.mkdir(backupDir, { recursive: true });
  await fs.mkdir(latestDir, { recursive: true });

  await writeBackupFiles(payload, backupDir);
  await writeBackupFiles(payload, latestDir);
}

async function writeBackupFiles(payload, rootDir) {
  await fs.writeFile(path.join(rootDir, 'payload.json'), JSON.stringify(payload));
  await fs.writeFile(path.join(rootDir, 'archive.json'), JSON.stringify(payload.archive, null, 2));
  await fs.writeFile(path.join(rootDir, 'entities.json'), JSON.stringify(payload.archive.entities ?? [], null, 2));
  await fs.writeFile(path.join(rootDir, 'records.json'), JSON.stringify(payload.archive.records ?? [], null, 2));

  for (const blob of payload.media ?? []) {
    const relativePath = safeRelativePath(blob.relativePath || `SarosMedia/${blob.fileName || blob.id}`);
    const destination = path.join(rootDir, relativePath);
    await fs.mkdir(path.dirname(destination), { recursive: true });
    await fs.writeFile(destination, Buffer.from(blob.dataBase64 ?? '', 'base64'));
  }
}

function mergeBackupPayload(currentPayload, deltaPayload) {
  validatePayload(deltaPayload);

  if (!currentPayload) {
    return {
      ...deltaPayload,
      exportTimestamp: new Date().toISOString()
    };
  }

  validatePayload(currentPayload);

  return {
    schemaVersion: 1,
    appVersion: deltaPayload.appVersion || currentPayload.appVersion,
    exportTimestamp: new Date().toISOString(),
    archive: {
      appVersion: deltaPayload.archive?.appVersion || currentPayload.archive?.appVersion || deltaPayload.appVersion,
      exportTimestamp: new Date().toISOString(),
      entities: mergeById(currentPayload.archive?.entities, deltaPayload.archive?.entities),
      records: mergeById(currentPayload.archive?.records, deltaPayload.archive?.records)
        .sort((a, b) => new Date(a.eventDate).getTime() - new Date(b.eventDate).getTime())
    },
    media: mergeById(currentPayload.media, deltaPayload.media)
  };
}

function validatePayload(payload) {
  if (!payload || payload.schemaVersion !== 1 || !payload.archive) {
    throw new Error('Invalid Exeligmos sync payload.');
  }
}

function mergeById(currentItems = [], nextItems = []) {
  const items = new Map();
  for (const item of currentItems || []) {
    if (item?.id) items.set(item.id, item);
  }
  for (const item of nextItems || []) {
    if (item?.id) items.set(item.id, item);
  }
  return [...items.values()];
}

async function readLatestPayload() {
  try {
    const data = await fs.readFile(path.join(DATA_DIR, 'latest', 'payload.json'), 'utf8');
    return JSON.parse(data);
  } catch {
    return null;
  }
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
  const media = new Map((payload.media ?? []).map((blob) => [blob.id, blob]));
  const records = [...(payload.archive.records ?? [])]
    .sort((a, b) => new Date(b.eventDate).getTime() - new Date(a.eventDate).getTime())
    .map((record) => {
      const entity = entities.get(record.entityID);
      return {
        id: record.id,
        entityID: record.entityID,
        entityTitle: entity?.title || 'Untitled thread',
        eventDate: record.eventDate,
        emoji: record.emoji,
        text: record.text,
        saros: record.saros,
        octalAddress: record.octalAddress,
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
      return {
        id: entity.id,
        title: entity.title || 'Untitled thread',
        emoji: entity.emoji,
        saros: entity.saros,
        recordCount: threadRecords.length,
        latestRecordDate: threadRecords[0]?.eventDate ?? null,
        records: threadRecords
      };
    })
    .filter((thread) => thread.recordCount > 0)
    .sort((a, b) => new Date(b.latestRecordDate).getTime() - new Date(a.latestRecordDate).getTime());

  return {
    exportTimestamp: payload.exportTimestamp,
    entityCount: payload.archive.entities?.length ?? 0,
    recordCount: records.length,
    mediaCount: payload.media?.length ?? 0,
    threads,
    records
  };
}

async function serveMedia(encodedRelativePath, res) {
  const relativePath = safeRelativePath(decodeURIComponent(encodedRelativePath));
  const filePath = path.join(DATA_DIR, 'latest', relativePath);
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
    header { position: sticky; top: 0; background: rgba(11,13,16,.92); backdrop-filter: blur(14px); padding: 18px 20px; border-bottom: 1px solid #222832; }
    h1 { margin: 0 0 6px; font-size: 22px; }
    .meta { color: #95a0ad; font-size: 13px; }
    main { max-width: 980px; margin: 0 auto; padding: 20px; }
    .thread { margin-bottom: 22px; }
    .thread-header { display: flex; align-items: center; justify-content: space-between; gap: 14px; padding: 14px 0 10px; border-bottom: 1px solid #232a34; }
    .thread-title { font-weight: 800; font-size: 20px; }
    .thread-meta { color: #95a0ad; font-size: 13px; margin-top: 4px; }
    .record { display: grid; grid-template-columns: 1fr auto; gap: 12px; padding: 16px; margin-top: 12px; border: 1px solid #232a34; border-radius: 10px; background: #11151b; }
    .title { font-weight: 700; font-size: 17px; }
    .sub { color: #9ca6b3; font-size: 13px; margin-top: 4px; }
    .emoji { font-size: 38px; line-height: 1; }
    .text { margin-top: 10px; white-space: pre-wrap; color: #d8dde4; }
    .media { display: flex; gap: 10px; flex-wrap: wrap; margin-top: 12px; }
    .media img, .media video { width: 160px; height: 160px; object-fit: cover; border-radius: 8px; background: #050607; }
    audio { width: 260px; }
    .empty { color: #95a0ad; padding: 40px 0; text-align: center; }
  </style>
</head>
<body>
  <header>
    <h1>Exeligmos Sync</h1>
    <div class="meta" id="status">Loading backup...</div>
  </header>
  <main id="records"></main>
  <script>
    const status = document.getElementById('status');
    const recordsEl = document.getElementById('records');

    fetch('/api/records')
      .then((response) => response.json())
      .then((data) => {
        status.textContent = data.exportTimestamp
          ? \`Latest backup: \${new Date(data.exportTimestamp).toLocaleString()} · \${data.entityCount} threads · \${data.recordCount} records · \${data.mediaCount} media\`
          : 'No backup yet. Push one from the iOS app Settings screen.';
        recordsEl.innerHTML = '';
        if ((!data.threads || data.threads.length === 0) && (!data.records || data.records.length === 0)) {
          recordsEl.innerHTML = '<div class="empty">No records to show.</div>';
          return;
        }
        if (data.threads?.length) {
          for (const thread of data.threads) {
            recordsEl.appendChild(renderThread(thread));
          }
        } else {
          for (const record of data.records) {
            recordsEl.appendChild(renderRecord(record, true));
          }
        }
      })
      .catch((error) => {
        status.textContent = error.message;
      });

    function renderThread(thread) {
      const section = document.createElement('section');
      section.className = 'thread';

      const header = document.createElement('div');
      header.className = 'thread-header';
      const body = document.createElement('div');
      body.innerHTML = \`
        <div class="thread-title">\${escapeHTML(thread.title || 'Untitled thread')}</div>
        <div class="thread-meta">Saros \${thread.saros} · \${thread.recordCount} \${thread.recordCount === 1 ? 'record' : 'records'}\${thread.latestRecordDate ? \` · latest \${new Date(thread.latestRecordDate).toLocaleString()}\` : ''}</div>
      \`;

      const emoji = document.createElement('div');
      emoji.className = 'emoji';
      emoji.textContent = thread.emoji || '✦';
      header.append(body, emoji);
      section.appendChild(header);

      for (const record of thread.records || []) {
        section.appendChild(renderRecord(record, false));
      }

      return section;
    }

    function renderRecord(record, showThreadTitle) {
      const node = document.createElement('article');
      node.className = 'record';
      const body = document.createElement('div');
      const emoji = document.createElement('div');
      emoji.className = 'emoji';
      emoji.textContent = record.emoji || '✦';

      body.innerHTML = \`
        \${showThreadTitle ? \`<div class="title">\${escapeHTML(record.entityTitle)}</div>\` : ''}
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
      node.append(body, emoji);
      return node;
    }

    function renderMedia(media) {
      const wrap = document.createElement('div');
      wrap.className = 'media';
      for (const item of media) {
        if (item.type === 'photo' || item.type === 'symbolicPhoto') {
          const image = document.createElement('img');
          image.src = item.url;
          image.loading = 'lazy';
          wrap.appendChild(image);
        } else if (item.type === 'video') {
          const video = document.createElement('video');
          video.src = item.url;
          video.controls = true;
          wrap.appendChild(video);
        } else if (item.type === 'audio') {
          const audio = document.createElement('audio');
          audio.src = item.url;
          audio.controls = true;
          wrap.appendChild(audio);
        }
      }
      return wrap;
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
  const parts = String(value || '')
    .replaceAll('\\\\', '/')
    .split('/')
    .filter((part) => part && part !== '.' && part !== '..');
  const relative = parts.join('/');
  return relative.startsWith('SarosMedia/') ? relative : `SarosMedia/${path.basename(relative || 'media.bin')}`;
}

function encodePath(value) {
  return safeRelativePath(value).split('/').map(encodeURIComponent).join('/');
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

function timestamp() {
  return new Date().toISOString().replaceAll(':', '-').replaceAll('.', '-');
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
