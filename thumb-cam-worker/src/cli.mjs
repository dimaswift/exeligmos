#!/usr/bin/env node

import { loadConfig } from "./config.mjs";
import { ThumbCamWorker } from "./worker.mjs";

async function main() {
  const config = await loadConfig();
  const worker = new ThumbCamWorker(config);
  process.once("SIGINT", () => worker.stop("SIGINT"));
  process.once("SIGTERM", () => worker.stop("SIGTERM"));
  await worker.run();
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
});
