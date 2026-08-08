#!/usr/bin/env node

import { loadConfig } from "./config.mjs";
import { DreamerWorker } from "./worker.mjs";

const config = await loadConfig();
const worker = new DreamerWorker(config);
process.once("SIGINT", () => worker.stop("SIGINT"));
process.once("SIGTERM", () => worker.stop("SIGTERM"));
try {
  await worker.run();
} catch (error) {
  console.error(error instanceof Error ? error.stack : String(error));
  process.exitCode = 1;
}
