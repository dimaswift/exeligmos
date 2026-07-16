import { constants } from "node:fs";
import {
  mkdir,
  open,
  rename,
  unlink,
  type FileHandle,
} from "node:fs/promises";
import { createHash, randomUUID } from "node:crypto";
import path from "node:path";
import type { Readable } from "node:stream";

export interface StoredMediaStream {
  readonly stream: Readable;
  readonly byteLength: number;
}

export interface MediaStorage {
  writeVerified(
    key: string,
    source: AsyncIterable<Uint8Array | string>,
    expectedByteLength: number,
    expectedSha256: string,
  ): Promise<void>;
  open(key: string): Promise<StoredMediaStream>;
  delete(key: string): Promise<void>;
}

/** Canonical immutable object key used by the legacy importer. */
export function mediaStorageKey(userId: string, mediaId: string): string {
  if (!isCanonicalUuid(userId) || !isCanonicalUuid(mediaId)) {
    throw new Error("Media storage keys require canonical lowercase UUIDs");
  }
  return `media/${userId}/${mediaId}.blob`;
}

/**
 * Upload bytes must never share the final media ID as their filesystem key.
 * A client may accidentally reuse an ID from a completed or aborted session;
 * keeping each reservation in its own immutable object prevents that retry
 * from overwriting a ready media object's bytes before PostgreSQL rejects the
 * duplicate media ID at completion.
 */
export function mediaUploadStorageKey(userId: string, uploadId: string): string {
  if (!isCanonicalUuid(userId) || !isCanonicalUuid(uploadId)) {
    throw new Error("Media upload storage keys require canonical lowercase UUIDs");
  }
  return `uploads/${userId}/${uploadId}.blob`;
}

export class MediaStorageIntegrityError extends Error {
  constructor(
    readonly kind: "byte_length" | "sha256",
    readonly expected: string,
    readonly actual: string,
  ) {
    super(`Stored media ${kind} did not match its declaration`);
    this.name = "MediaStorageIntegrityError";
  }
}

export class MediaStorageMissingError extends Error {
  constructor() {
    super("Stored media bytes are missing");
    this.name = "MediaStorageMissingError";
  }
}

/**
 * Single-node media storage with atomic, verified writes. Database storage keys
 * are still treated as untrusted input: absolute paths, empty segments, dot
 * traversal, backslashes, and paths outside the configured root are rejected.
 */
export class LocalMediaStorage implements MediaStorage {
  private readonly root: string;

  constructor(root: string) {
    if (root.trim().length === 0) {
      throw new Error("The media storage root must not be empty");
    }
    this.root = path.resolve(root);
  }

  async writeVerified(
    key: string,
    source: AsyncIterable<Uint8Array | string>,
    expectedByteLength: number,
    expectedSha256: string,
  ): Promise<void> {
    if (!Number.isSafeInteger(expectedByteLength) || expectedByteLength < 1) {
      throw new Error("The expected media byte length must be a positive safe integer");
    }
    if (!/^[a-f0-9]{64}$/.test(expectedSha256)) {
      throw new Error("The expected media SHA-256 must be lowercase hexadecimal");
    }

    const destination = this.pathForKey(key);
    const attempt = `${destination}.attempt-${randomUUID()}`;
    await mkdir(path.dirname(destination), { recursive: true, mode: 0o700 });

    let handle: FileHandle | undefined;
    try {
      handle = await open(attempt, "wx", 0o600);
      const hash = createHash("sha256");
      let received = 0;

      for await (const value of source) {
        const chunk = typeof value === "string" ? Buffer.from(value) : Buffer.from(value);
        received += chunk.byteLength;
        if (received > expectedByteLength) {
          throw new MediaStorageIntegrityError(
            "byte_length",
            String(expectedByteLength),
            String(received),
          );
        }
        hash.update(chunk);
        await writeAll(handle, chunk);
      }

      if (received !== expectedByteLength) {
        throw new MediaStorageIntegrityError(
          "byte_length",
          String(expectedByteLength),
          String(received),
        );
      }
      const actualSha256 = hash.digest("hex");
      if (actualSha256 !== expectedSha256) {
        throw new MediaStorageIntegrityError("sha256", expectedSha256, actualSha256);
      }

      await handle.sync();
      await handle.close();
      handle = undefined;
      // POSIX rename atomically replaces an identical retry's earlier object.
      await rename(attempt, destination);
    } catch (error) {
      if (handle !== undefined) {
        await handle.close().catch(() => undefined);
      }
      await unlink(attempt).catch(() => undefined);
      throw error;
    }
  }

  async open(key: string): Promise<StoredMediaStream> {
    const filePath = this.pathForKey(key);
    let handle: FileHandle;
    try {
      handle = await open(filePath, constants.O_RDONLY | noFollowFlag());
    } catch (error) {
      if (isErrorCode(error, "ENOENT")) {
        throw new MediaStorageMissingError();
      }
      throw error;
    }

    try {
      const stat = await handle.stat();
      if (!stat.isFile() || !Number.isSafeInteger(stat.size)) {
        throw new MediaStorageMissingError();
      }
      return {
        stream: handle.createReadStream({ autoClose: true }),
        byteLength: stat.size,
      };
    } catch (error) {
      await handle.close().catch(() => undefined);
      throw error;
    }
  }

  async delete(key: string): Promise<void> {
    try {
      await unlink(this.pathForKey(key));
    } catch (error) {
      if (!isErrorCode(error, "ENOENT")) {
        throw error;
      }
    }
  }

  private pathForKey(key: string): string {
    if (
      key.length < 1 ||
      key.length > 512 ||
      key.includes("\\") ||
      key.includes("\0") ||
      path.isAbsolute(key)
    ) {
      throw new Error("Unsafe media storage key");
    }
    const segments = key.split("/");
    if (segments.some((segment) => segment.length === 0 || segment === "." || segment === "..")) {
      throw new Error("Unsafe media storage key");
    }

    const resolved = path.resolve(this.root, ...segments);
    const relative = path.relative(this.root, resolved);
    if (relative.length === 0 || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
      throw new Error("Unsafe media storage key");
    }
    return resolved;
  }
}

async function writeAll(handle: FileHandle, chunk: Buffer): Promise<void> {
  let offset = 0;
  while (offset < chunk.byteLength) {
    const result = await handle.write(chunk, offset, chunk.byteLength - offset, null);
    if (result.bytesWritten < 1) {
      throw new Error("Media storage write made no progress");
    }
    offset += result.bytesWritten;
  }
}

function noFollowFlag(): number {
  return "O_NOFOLLOW" in constants ? constants.O_NOFOLLOW : 0;
}

function isErrorCode(error: unknown, code: string): boolean {
  return error instanceof Error && "code" in error && String(error.code) === code;
}

function isCanonicalUuid(value: string): boolean {
  return (
    value === value.toLowerCase() &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(
      value,
    )
  );
}
