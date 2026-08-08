import { randomUUID } from "node:crypto";
import { mkdir, readFile, rename, rm, writeFile } from "node:fs/promises";
import path from "node:path";

export class CacheGenerationStore {
  constructor(workRoot) {
    this.path = path.join(path.resolve(workRoot), "cache-generation.json");
  }

  async read() {
    try {
      const parsed = JSON.parse(await readFile(this.path, "utf8"));
      return Number.isSafeInteger(parsed?.generation) && parsed.generation >= 0
        ? parsed.generation
        : 0;
    } catch (error) {
      if (error?.code === "ENOENT" || error instanceof SyntaxError) return 0;
      throw error;
    }
  }

  async write(generation) {
    if (!Number.isSafeInteger(generation) || generation < 0) {
      throw new Error("Cache generation must be a non-negative safe integer.");
    }
    const directory = path.dirname(this.path);
    await mkdir(directory, { recursive: true });
    const temporary = `${this.path}.${randomUUID()}.tmp`;
    try {
      await writeFile(temporary, `${JSON.stringify({ generation })}\n`, {
        encoding: "utf8",
        mode: 0o600,
      });
      await rename(temporary, this.path);
    } finally {
      await rm(temporary, { force: true });
    }
  }
}
