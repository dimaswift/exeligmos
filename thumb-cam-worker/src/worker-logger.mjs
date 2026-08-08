export function createWorkerLogger(client, sink = console) {
  let lastPersistedSignature;

  async function write(level, message, context = {}) {
    const normalized = String(message).trim();
    sink[level]?.(normalized);
    if (normalized === "") return;
    const signature = JSON.stringify([level, normalized, context]);
    if (signature === lastPersistedSignature) return;
    lastPersistedSignature = signature;
    try {
      await client.writeWorkerLog(level, normalized, context);
    } catch (error) {
      lastPersistedSignature = undefined;
      sink.warn?.(
        `Could not persist worker log: ${
          error instanceof Error ? error.message : String(error)
        }`,
      );
    }
  }

  return Object.freeze({
    debug: (message, context) => write("debug", message, context),
    info: (message, context) => write("info", message, context),
    warn: (message, context) => write("warn", message, context),
    error: (message, context) => write("error", message, context),
  });
}
