#!/usr/bin/env node

import { loadConfig } from "./config.mjs";
import { DreamerWorker } from "./worker.mjs";

const config = await loadConfig();
const worker = new DreamerWorker(config);
const stop = () => worker.stop();
process.once("SIGINT", stop);
process.once("SIGTERM", stop);
await worker.run();
