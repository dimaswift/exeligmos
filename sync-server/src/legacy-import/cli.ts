import { mkdir, rename, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { createPostgresDatabase } from "../db/database.js";
import { LocalMediaStorage } from "../media/storage.js";
import { importLegacyStore, type LegacyImportProgress } from "./importer.js";
import { loadLegacyImportMapping } from "./mapping.js";
import { scanLegacyStore, type LegacyScanProgress } from "./scanner.js";

interface Arguments {
  readonly source: string;
  readonly mapping: string;
  readonly storageRoot: string;
  readonly report?: string;
  readonly dryRun: boolean;
}

export async function runLegacyImportCli(
  argv: readonly string[] = process.argv.slice(2),
  environment: NodeJS.ProcessEnv = process.env,
): Promise<void> {
  const args = parseArguments(argv, environment);
  const databaseUrl = environment.DATABASE_URL?.trim();
  if (databaseUrl === undefined || databaseUrl.length === 0) {
    throw new Error("DATABASE_URL is required");
  }

  process.stderr.write(`Scanning read-only legacy source ${path.resolve(args.source)}\n`);
  const scan = await scanLegacyStore(args.source, { onProgress: scanProgress });
  process.stderr.write(
    `Validated ${scan.manifest.recordCount} records, ${scan.manifest.tagCount} tags, ` +
    `${scan.manifest.mediaCount} media objects (${scan.manifest.mediaBytes} bytes)\n`,
  );
  const mapping = await loadLegacyImportMapping(args.mapping, scan);
  const database = createPostgresDatabase({
    url: databaseUrl,
    poolMax: environmentInteger(environment, "DB_POOL_MAX", 5, 1, 100),
    connectionTimeoutMs: environmentInteger(environment, "DB_CONNECTION_TIMEOUT_MS", 5_000, 100, 120_000),
    idleTimeoutMs: environmentInteger(environment, "DB_IDLE_TIMEOUT_MS", 30_000, 1_000, 600_000),
    readinessTimeoutMs: environmentInteger(environment, "DB_READINESS_TIMEOUT_MS", 2_000, 100, 30_000),
    statementTimeoutMs: environmentInteger(environment, "DB_STATEMENT_TIMEOUT_MS", 15_000, 1_000, 300_000),
    lockTimeoutMs: environmentInteger(environment, "DB_LOCK_TIMEOUT_MS", 5_000, 100, 60_000),
    idleInTransactionSessionTimeoutMs: environmentInteger(
      environment,
      "DB_IDLE_IN_TRANSACTION_TIMEOUT_MS",
      15_000,
      1_000,
      300_000,
    ),
  });

  try {
    const report = await importLegacyStore({
      database,
      storage: new LocalMediaStorage(args.storageRoot),
      scan,
      mapping,
      dryRun: args.dryRun,
      onProgress: importProgress,
    });
    const serialized = `${JSON.stringify(report, null, 2)}\n`;
    if (args.report !== undefined) {
      await writeReportAtomic(args.report, serialized);
      process.stderr.write(`Wrote migration report to ${path.resolve(args.report)}\n`);
    }
    process.stdout.write(serialized);
  } finally {
    await database.close();
  }
}

function parseArguments(argv: readonly string[], environment: NodeJS.ProcessEnv): Arguments {
  let source: string | undefined;
  let mapping: string | undefined;
  let storageRoot: string | undefined;
  let report: string | undefined;
  let mode: "dry-run" | "apply" | undefined;

  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === "--help" || argument === "-h") {
      process.stdout.write(usage());
      throw new CliExit();
    }
    if (argument === "--dry-run" || argument === "--apply") {
      const nextMode = argument.slice(2) as "dry-run" | "apply";
      if (mode !== undefined && mode !== nextMode) {
        throw new Error("Choose exactly one of --dry-run or --apply");
      }
      mode = nextMode;
      continue;
    }
    if (argument === "--source" || argument === "--mapping" || argument === "--storage-root" || argument === "--report") {
      const value = argv[index + 1];
      if (value === undefined || value.startsWith("--")) {
        throw new Error(`${argument} requires a value`);
      }
      index += 1;
      if (argument === "--source") source = value;
      if (argument === "--mapping") mapping = value;
      if (argument === "--storage-root") storageRoot = value;
      if (argument === "--report") report = value;
      continue;
    }
    throw new Error(`Unknown argument ${argument ?? ""}\n${usage()}`);
  }

  if (source === undefined || mapping === undefined || mode === undefined) {
    throw new Error(`--source, --mapping, and exactly one mode are required\n${usage()}`);
  }
  const configuredStorageRoot = storageRoot ?? environment.MEDIA_STORAGE_ROOT?.trim();
  if (configuredStorageRoot === undefined || configuredStorageRoot.length === 0) {
    if (mode === "apply") {
      throw new Error("--storage-root or MEDIA_STORAGE_ROOT is required with --apply");
    }
    storageRoot = path.resolve(".legacy-import-dry-run-storage-not-used");
  } else {
    storageRoot = configuredStorageRoot;
  }
  return {
    source,
    mapping,
    storageRoot,
    ...(report === undefined ? {} : { report }),
    dryRun: mode === "dry-run",
  };
}

function usage(): string {
  return `Usage:
  npm run import:legacy -- --source <legacy-data> --mapping <mapping.json> --dry-run [--report <report.json>]
  npm run import:legacy -- --source <legacy-data> --mapping <mapping.json> --apply --storage-root <media-root> [--report <report.json>]

The source is never modified. DATABASE_URL is required. Apply mode also needs
MEDIA_STORAGE_ROOT or --storage-root. Run dry-run, review its checksum/counts,
freeze the old installation, then run apply against the identical source snapshot.
`;
}

function scanProgress(progress: LegacyScanProgress): void {
  if (progress.completed === progress.total || progress.completed % 100 === 0) {
    process.stderr.write(`scan ${progress.phase}: ${progress.completed}/${progress.total}\n`);
  }
}

function importProgress(progress: LegacyImportProgress): void {
  if (progress.completed === progress.total || progress.completed % 25 === 0) {
    process.stderr.write(`import ${progress.phase}: ${progress.completed}/${progress.total}\n`);
  }
}

async function writeReportAtomic(filePath: string, contents: string): Promise<void> {
  const destination = path.resolve(filePath);
  await mkdir(path.dirname(destination), { recursive: true });
  const temporary = `${destination}.${process.pid}.tmp`;
  await writeFile(temporary, contents, { mode: 0o600, flag: "wx" });
  await rename(temporary, destination);
}

function environmentInteger(
  environment: NodeJS.ProcessEnv,
  name: string,
  fallback: number,
  minimum: number,
  maximum: number,
): number {
  const raw = environment[name]?.trim();
  if (raw === undefined || raw.length === 0) return fallback;
  if (!/^\d+$/.test(raw)) throw new Error(`${name} must be an integer`);
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value < minimum || value > maximum) {
    throw new Error(`${name} must be between ${minimum} and ${maximum}`);
  }
  return value;
}

class CliExit extends Error {}

function isEntrypoint(): boolean {
  const entrypoint = process.argv[1];
  return entrypoint !== undefined && fileURLToPath(import.meta.url) === path.resolve(entrypoint);
}

if (isEntrypoint()) {
  void runLegacyImportCli().catch((error: unknown) => {
    if (!(error instanceof CliExit)) {
      console.error(error);
      process.exitCode = 1;
    }
  });
}
