#!/usr/bin/env node

import { randomUUID } from "node:crypto";
import { chmod, rename, writeFile } from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { createInterface } from "node:readline/promises";

import { installWorkerService } from "./install-service.mjs";

const root = path.resolve(import.meta.dirname, "..");
const serverUrl = (process.env.DREAMER_SERVER_URL ?? "http://127.0.0.1:8788")
  .replace(/\/$/, "");
const terminal = createInterface({
  input: process.stdin,
  output: process.stdout,
  terminal: true,
});
const login = (await terminal.question("Fractonica login: ")).trim();
terminal.close();
const password = await hiddenQuestion("Fractonica password: ");

const session = await request("/auth/login", {
  method: "POST",
  body: { login, password },
});
const authorization = `Bearer ${session.accessToken}`;
const devices = await request("/devices?limit=100", { authorization });
let device = devices.data.find(
  (candidate) =>
    candidate.name === "Dreamer" &&
    candidate.kind === "agent" &&
    candidate.revokedAt === null,
);
if (device === undefined) {
  device = await request("/devices", {
    method: "POST",
    authorization,
    idempotencyKey: randomUUID(),
    body: {
      name: "Dreamer",
      kind: "agent",
      platform: "node",
      metadata: { source: "DREAMER" },
    },
  });
}
const key = await request("/api-keys", {
  method: "POST",
  authorization,
  idempotencyKey: randomUUID(),
  body: {
    name: "Dreamer worker",
    deviceId: device.id,
    scopes: [
      "jobs:read",
      "records:read",
      "records:write",
      "media:read",
      "media:write",
      "tags:read",
      "tags:write"
    ],
  },
});
await atomicWrite(
  path.join(root, "dreamer.config.json"),
  `${JSON.stringify({
    serverUrl,
    deviceId: device.id,
    pollIntervalMs: 60_000,
    descriptionProvider: "ollama",
    descriptionBaseUrl: "http://127.0.0.1:11434",
    descriptionModel: "gemma4",
    descriptionPrompt:
      "Describe this image as one concise factual visual observation. Mention the subjects, setting, lighting, mood, and composition.",
    embeddingProvider: "ollama",
    embeddingBaseUrl: "http://127.0.0.1:11434",
    embeddingModel: "embeddinggemma",
    imageGenerationEnabled: true,
    imageProvider: "mlx-studio",
    imageBaseUrl: "http://127.0.0.1:8001",
    imageModel: "schnell",
    imagePromptReference:
      "A compact workstation on a walnut desk, soft window light, eye-level product photo, quiet focused mood",
    imageSize: "512x512",
    imageSteps: 4,
    imageGuidance: 0,
    imageTimeoutMs: 30_000,
    ffmpegExecutable: "ffmpeg",
    workRoot: "~/Library/Application Support/Fractonica/Dreamer"
  }, null, 2)}\n`,
  0o600,
);
await atomicWrite(
  path.join(root, ".env"),
  `DREAMER_API_KEY=${key.secret}\n`,
  0o600,
);
await installWorkerService();
console.log(`Configured Dreamer agent ${device.id}.`);
console.log("Use the Workers page to start and stop it.");

async function request(
  pathname,
  { method = "GET", authorization: auth, idempotencyKey, body } = {},
) {
  const response = await fetch(`${serverUrl}${pathname}`, {
    method,
    headers: {
      accept: "application/json",
      ...(body === undefined ? {} : { "content-type": "application/json" }),
      ...(auth === undefined ? {} : { authorization: auth }),
      ...(idempotencyKey === undefined
        ? {}
        : { "idempotency-key": idempotencyKey }),
    },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
  const value = await response.json().catch(() => undefined);
  if (!response.ok) {
    throw new Error(value?.detail ?? `${method} ${pathname} failed (${response.status}).`);
  }
  return value;
}

async function atomicWrite(target, contents, mode) {
  const temporary = `${target}.${process.pid}.tmp`;
  await writeFile(temporary, contents, { encoding: "utf8", mode });
  await chmod(temporary, mode);
  await rename(temporary, target);
}

async function hiddenQuestion(prompt) {
  if (!process.stdin.isTTY || process.stdin.setRawMode === undefined) {
    const fallback = createInterface({ input: process.stdin });
    try {
      return await fallback.question(prompt);
    } finally {
      fallback.close();
    }
  }
  process.stdout.write(prompt);
  const wasRaw = process.stdin.isRaw;
  process.stdin.setRawMode(true);
  process.stdin.resume();
  return new Promise((resolve, reject) => {
    let value = "";
    const finish = () => {
      process.stdin.off("data", onData);
      process.stdin.setRawMode(wasRaw);
      process.stdin.pause();
      process.stdout.write("\n");
    };
    const onData = (chunk) => {
      for (const character of chunk.toString("utf8")) {
        if (character === "\r" || character === "\n") {
          finish();
          resolve(value);
          return;
        }
        if (character === "\u0003") {
          finish();
          reject(new Error("Configuration cancelled."));
          return;
        }
        if (character === "\u007f" || character === "\b") {
          value = value.slice(0, -1);
        } else {
          value += character;
        }
      }
    };
    process.stdin.on("data", onData);
  });
}
