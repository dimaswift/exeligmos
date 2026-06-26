import path from 'node:path';
import fs from 'node:fs/promises';
import { DatabaseSync } from 'node:sqlite';

const __dirname = path.dirname(new URL(import.meta.url).pathname);
const DATA_DIR = process.env.EXELIGMOS_SYNC_DATA || path.join(__dirname, 'data');
const db = new DatabaseSync(path.join(DATA_DIR, 'sync.sqlite'));

const device = db.prepare('SELECT id, name, emoji FROM devices ORDER BY first_seen ASC LIMIT 1').get();
if (!device?.id) {
  console.error('No registered devices found. Open the app and connect to this server first.');
  process.exit(1);
}

let patched = 0;
let skipped = 0;
const entriesRoot = path.join(DATA_DIR, 'entries');

for (const directory of await childDirectories(entriesRoot)) {
  const file = path.join(directory, 'entry.json');
  const entry = await readJSON(file);
  if (!entry?.id) {
    skipped += 1;
    continue;
  }
  if (entry.sourceDeviceID) {
    skipped += 1;
    continue;
  }
  entry.sourceDeviceID = device.id;
  entry.sourceDeviceName = device.name;
  entry.sourceDeviceEmoji = device.emoji;
  await writeJSONAtomic(file, entry);
  patched += 1;
}

console.log(`Patched ${patched} entries with ${device.emoji} ${device.name} (${device.id}). Skipped ${skipped}.`);

async function childDirectories(root) {
  try {
    return (await fs.readdir(root, { withFileTypes: true }))
      .filter((entry) => entry.isDirectory())
      .map((entry) => path.join(root, entry.name));
  } catch {
    return [];
  }
}

async function readJSON(file) {
  try {
    return JSON.parse(await fs.readFile(file, 'utf8'));
  } catch {
    return null;
  }
}

async function writeJSONAtomic(file, value) {
  const tempPath = `${file}.${process.pid}.${Date.now()}.tmp`;
  await fs.writeFile(tempPath, JSON.stringify(value, null, 2));
  await fs.rename(tempPath, file);
}
