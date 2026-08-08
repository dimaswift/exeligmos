import assert from "node:assert/strict";
import test from "node:test";

import { createWorkerLogger } from "../src/worker-logger.mjs";

test("deduplicates consecutive durable worker logs but keeps distinct attempts", async () => {
  const persisted = [];
  const logger = createWorkerLogger(
    {
      async writeWorkerLog(level, message, context) {
        persisted.push({ level, message, context });
      },
    },
    { info() {}, warn() {}, error() {}, debug() {} },
  );

  await logger.info("waiting", {});
  await logger.info("waiting", {});
  await logger.error("dream failed", { attempt: 1 });
  await logger.error("dream failed", { attempt: 2 });
  await logger.info("waiting", {});

  assert.deepEqual(persisted, [
    { level: "info", message: "waiting", context: {} },
    { level: "error", message: "dream failed", context: { attempt: 1 } },
    { level: "error", message: "dream failed", context: { attempt: 2 } },
    { level: "info", message: "waiting", context: {} },
  ]);
});
