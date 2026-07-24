import { fileURLToPath } from "node:url";
import path from "node:path";

import { loadConfig } from "../config.js";
import { createPostgresDatabase } from "../db/database.js";
import {
  loadArchiveSnapshot,
  writeReadableArchive,
} from "./exporter.js";

function usage(): never {
  console.error(
    "Usage: npm run archive -- --output /path/to/new-archive-directory",
  );
  process.exit(2);
}

function outputArgument(arguments_: readonly string[]): string {
  if (arguments_.length !== 2 || arguments_[0] !== "--output") {
    usage();
  }
  const output = arguments_[1];
  if (output === undefined || output.trim().length === 0) {
    usage();
  }
  return path.resolve(output);
}

export async function runArchiveCli(arguments_: readonly string[]): Promise<void> {
  const destination = outputArgument(arguments_);
  const config = loadConfig();
  const database = createPostgresDatabase(config.database);
  try {
    const snapshot = await loadArchiveSnapshot(database);
    const result = await writeReadableArchive(
      snapshot,
      config.media.storageRoot,
      destination,
    );
    console.log(
      `archive complete: ${result.destination} ` +
        `(${result.counts.users} users, ${result.counts.records} records, ` +
        `${result.counts.media} media objects)`,
    );
  } finally {
    await database.close();
  }
}

function isEntrypoint(): boolean {
  const entrypoint = process.argv[1];
  return entrypoint !== undefined && fileURLToPath(import.meta.url) === path.resolve(entrypoint);
}

if (isEntrypoint()) {
  void runArchiveCli(process.argv.slice(2)).catch((error: unknown) => {
    console.error(error);
    process.exitCode = 1;
  });
}
