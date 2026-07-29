import { createHash, randomUUID } from "node:crypto";
import { createReadStream } from "node:fs";
import { chmod, mkdir, open, rename, rm, rmdir, stat } from "node:fs/promises";
import path from "node:path";

const SOURCE_KEY_PATTERN = /^[a-f0-9]{64}$/;

export class SnapshotStore {
  constructor(config, options = {}) {
    this.root = path.join(
      path.resolve(config.workRoot ?? ".thumb-cam-worker"),
      "snapshots",
    );
    this.concurrency = options.concurrency ?? config.snapshotConcurrency ?? 2;
    this.copy = options.copy ?? copySnapshotBytes;
  }

  async snapshotGroups(groups) {
    const items = groups.flat();
    const snapshots = await mapConcurrent(
      items,
      this.concurrency,
      async (item) => this.ensure(item, item.absolutePath),
    );
    const bySourceKey = new Map(
      snapshots.map((item) => [item.sourceKey, item]),
    );
    return groups.map((group) =>
      group.map((item) => bySourceKey.get(item.sourceKey)),
    );
  }

  async ensure(item, sourcePath) {
    validateDeclaration(item);
    const absolutePath = snapshotPathFor(this.root, item);
    if (await snapshotMatches(absolutePath, item)) {
      return { ...item, absolutePath };
    }
    if (typeof sourcePath !== "string" || sourcePath === "") {
      throw new Error(
        `No verified snapshot is available for ${item.relativePath}.`,
      );
    }

    const directory = path.dirname(absolutePath);
    await ensureDurableDirectory(path.dirname(this.root));
    await ensureDurableDirectory(this.root);
    await ensureDurableDirectory(directory);
    const temporaryPath = path.join(
      directory,
      `.${path.basename(absolutePath)}.${process.pid}.${randomUUID()}.part`,
    );
    try {
      const copied = await this.copy(sourcePath, temporaryPath);
      if (
        copied.byteLength !== item.byteLength ||
        copied.contentSha256 !== item.contentSha256
      ) {
        throw new Error(
          `Source changed while snapshotting ${item.relativePath}; expected ${item.byteLength} bytes/${item.contentSha256}, copied ${copied.byteLength} bytes/${copied.contentSha256}.`,
        );
      }
      await chmod(temporaryPath, 0o400);
      await syncFile(temporaryPath);
      await rename(temporaryPath, absolutePath);
      await syncDirectory(directory);
      if (!(await snapshotMatches(absolutePath, item))) {
        throw new Error(
          `Snapshot verification failed after publishing ${item.relativePath}.`,
        );
      }
      return { ...item, absolutePath };
    } finally {
      await rm(temporaryPath, { force: true });
    }
  }

  async existing(item) {
    validateDeclaration(item);
    const absolutePath = snapshotPathFor(this.root, item);
    if (!(await snapshotMatches(absolutePath, item))) return undefined;
    return { ...item, absolutePath };
  }

  assertProcessingPath(item) {
    const expected = snapshotPathFor(this.root, item);
    if (path.resolve(item.absolutePath ?? "") !== path.resolve(expected)) {
      throw new Error(
        `Processing is restricted to the local verified snapshot for ${item.relativePath}.`,
      );
    }
  }

  async cleanup(items) {
    const unique = new Map(
      items.map((item) => [item.sourceKey, snapshotPathFor(this.root, item)]),
    );
    await mapConcurrent(
      [...unique.values()],
      this.concurrency,
      async (absolutePath) => {
        await rm(absolutePath, { force: true });
        await removeEmptyDirectory(path.dirname(absolutePath));
      },
    );
    await removeEmptyDirectory(this.root);
  }
}

export function snapshotPathFor(root, item) {
  validateDeclaration(item);
  const extension = safeExtension(item.relativePath);
  return path.join(
    root,
    item.sourceKey.slice(0, 2),
    `${item.sourceKey}${extension}`,
  );
}

export async function copySnapshotBytes(sourcePath, destinationPath) {
  const source = await open(sourcePath, "r");
  let destination;
  const hash = createHash("sha256");
  let byteLength = 0;
  try {
    destination = await open(destinationPath, "wx", 0o600);
    const buffer = Buffer.allocUnsafe(1024 * 1024);
    while (true) {
      const { bytesRead } = await source.read(
        buffer,
        0,
        buffer.length,
        byteLength,
      );
      if (bytesRead === 0) break;
      const chunk = buffer.subarray(0, bytesRead);
      hash.update(chunk);
      let written = 0;
      while (written < bytesRead) {
        const result = await destination.write(
          chunk,
          written,
          bytesRead - written,
        );
        written += result.bytesWritten;
      }
      byteLength += bytesRead;
    }
    await destination.sync();
  } finally {
    await Promise.allSettled([source.close(), destination?.close()]);
  }
  return { byteLength, contentSha256: hash.digest("hex") };
}

async function snapshotMatches(absolutePath, item) {
  try {
    const file = await stat(absolutePath);
    if (!file.isFile() || file.size !== item.byteLength) return false;
    return (await sha256File(absolutePath)) === item.contentSha256;
  } catch {
    return false;
  }
}

async function sha256File(absolutePath) {
  const hash = createHash("sha256");
  for await (const chunk of createReadStream(absolutePath)) hash.update(chunk);
  return hash.digest("hex");
}

function validateDeclaration(item) {
  if (
    typeof item?.sourceKey !== "string" ||
    !SOURCE_KEY_PATTERN.test(item.sourceKey)
  ) {
    throw new Error("Snapshot sourceKey must be 64 lowercase hex characters.");
  }
  if (
    typeof item.contentSha256 !== "string" ||
    !SOURCE_KEY_PATTERN.test(item.contentSha256)
  ) {
    throw new Error(
      `Snapshot SHA-256 is invalid for ${item.relativePath ?? item.sourceKey}.`,
    );
  }
  if (!Number.isSafeInteger(item.byteLength) || item.byteLength < 1) {
    throw new Error(
      `Snapshot byte length is invalid for ${item.relativePath ?? item.sourceKey}.`,
    );
  }
}

function safeExtension(relativePath) {
  const extension = path.extname(relativePath).toLowerCase();
  return /^\.[a-z0-9]{1,10}$/.test(extension) ? extension : "";
}

async function syncDirectory(directory) {
  let handle;
  try {
    handle = await open(directory, "r");
    await handle.sync();
  } catch (error) {
    if (!["EINVAL", "ENOTSUP", "EISDIR"].includes(error?.code)) throw error;
  } finally {
    await handle?.close();
  }
}

async function syncFile(absolutePath) {
  const handle = await open(absolutePath, "r");
  try {
    await handle.sync();
  } finally {
    await handle.close();
  }
}

async function ensureDurableDirectory(directory) {
  let existed = true;
  try {
    const entry = await stat(directory);
    if (!entry.isDirectory()) {
      throw new Error(`${directory} exists but is not a directory.`);
    }
  } catch (error) {
    if (error?.code !== "ENOENT") throw error;
    existed = false;
  }
  await mkdir(directory, { recursive: true, mode: 0o700 });
  if (!existed) await syncDirectory(path.dirname(directory));
}

async function removeEmptyDirectory(directory) {
  try {
    await rmdir(directory);
  } catch (error) {
    if (!["ENOENT", "ENOTEMPTY", "EEXIST"].includes(error?.code)) throw error;
  }
}

async function mapConcurrent(items, concurrency, visit) {
  if (!Number.isSafeInteger(concurrency) || concurrency < 1) {
    throw new Error("snapshot concurrency must be a positive integer.");
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
