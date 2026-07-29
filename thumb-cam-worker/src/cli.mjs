#!/usr/bin/env node

import { loadConfig } from "./config.mjs";
import { ThumbCamWorker } from "./worker.mjs";

async function main() {
  const config = await loadConfig();
  const worker = new ThumbCamWorker(config);
  const stop = () => worker.stop();
  process.once("SIGINT", stop);
  process.once("SIGTERM", stop);
  await worker.run();
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
});
