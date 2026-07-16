import { fileURLToPath } from "node:url";
import { resolve } from "node:path";

import type { FastifyInstance } from "fastify";

import { buildApp } from "./app.js";
import { loadConfig, type ServerConfig } from "./config.js";
import { createPostgresDatabase } from "./db/database.js";

export interface RunningServer {
  readonly app: FastifyInstance;
  stop(): Promise<void>;
}

export async function startServer(config: ServerConfig = loadConfig()): Promise<RunningServer> {
  const database = createPostgresDatabase(config.database);
  const app = buildApp({ config, database });
  let stopping: Promise<void> | undefined;

  const stop = (): Promise<void> => {
    stopping ??= closeWithDeadline(app, config.shutdownTimeoutMs);
    return stopping;
  };

  const handleSignal = (signal: NodeJS.Signals): void => {
    app.log.info({ signal }, "shutdown signal received");
    void stop().catch((error: unknown) => {
      app.log.error({ err: error }, "graceful shutdown failed");
      process.exitCode = 1;
    });
  };

  process.once("SIGINT", handleSignal);
  process.once("SIGTERM", handleSignal);

  app.addHook("onClose", async () => {
    process.removeListener("SIGINT", handleSignal);
    process.removeListener("SIGTERM", handleSignal);
  });

  try {
    await app.listen({ host: config.host, port: config.port });
    app.log.info({ host: config.host, port: config.port }, "server listening");
  } catch (error) {
    await app.close();
    throw error;
  }

  return { app, stop };
}

async function closeWithDeadline(app: FastifyInstance, timeoutMs: number): Promise<void> {
  let timeout: NodeJS.Timeout | undefined;
  const deadline = new Promise<never>((_resolve, reject) => {
    timeout = setTimeout(() => {
      app.server.closeAllConnections?.();
      reject(new Error(`Graceful shutdown exceeded ${timeoutMs} ms`));
    }, timeoutMs);
    timeout.unref();
  });

  try {
    await Promise.race([app.close(), deadline]);
  } finally {
    if (timeout !== undefined) {
      clearTimeout(timeout);
    }
  }
}

function isEntrypoint(): boolean {
  const entrypoint = process.argv[1];
  return entrypoint !== undefined && fileURLToPath(import.meta.url) === resolve(entrypoint);
}

if (isEntrypoint()) {
  void startServer().catch((error: unknown) => {
    console.error(error);
    process.exitCode = 1;
  });
}
