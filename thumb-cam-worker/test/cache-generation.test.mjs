import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import { CacheGenerationStore } from "../src/cache-generation.mjs";

test("persists the acknowledged cache generation across worker restarts", async (context) => {
  const root = await mkdtemp(path.join(os.tmpdir(), "thumb-cache-generation-"));
  context.after(() => rm(root, { force: true, recursive: true }));
  const first = new CacheGenerationStore(root);

  assert.equal(await first.read(), 0);
  await first.write(7);

  assert.equal(await new CacheGenerationStore(root).read(), 7);
});
