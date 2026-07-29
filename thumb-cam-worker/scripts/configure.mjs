#!/usr/bin/env node

import { randomUUID } from "node:crypto";
import { execFile } from "node:child_process";
import { chmod, rename, writeFile } from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { createInterface } from "node:readline/promises";
import { promisify } from "node:util";

import { installWorkerService } from "./install-service.mjs";

const workerRoot = path.resolve(import.meta.dirname, "..");
const run = promisify(execFile);
const serverUrl = (process.env.THUMB_CAM_SERVER_URL ?? "http://127.0.0.1:8788")
  .replace(/\/$/, "");
const terminal = createInterface({
  input: process.stdin,
  output: process.stdout,
  terminal: true,
});

const login = (await terminal.question("Fractonica login: ")).trim();
terminal.close();
const password = await hiddenQuestion("Fractonica password: ");
try {
  const session = await request("/auth/login", {
    method: "POST",
    body: { login, password },
  });
  const authorization = `Bearer ${session.accessToken}`;

  const devices = await request("/devices?limit=100", { authorization });
  let device = devices.data.find(
    (candidate) =>
      candidate.name === "THUMB" &&
      candidate.kind === "agent" &&
      candidate.revokedAt === null,
  );
  if (device === undefined) {
    device = await request("/devices", {
      method: "POST",
      authorization,
      idempotencyKey: randomUUID(),
      body: {
        name: "THUMB",
        kind: "agent",
        platform: "node",
        metadata: { source: "THUMB_CAM" },
      },
    });
  }

  const created = await request("/api-keys", {
    method: "POST",
    authorization,
    idempotencyKey: randomUUID(),
    body: {
      name: "THUMB_CAM worker",
      deviceId: device.id,
      scopes: [
        "jobs:read",
        "jobs:write",
        "records:read",
        "records:write",
        "media:read",
        "media:write",
      ],
    },
  });

  await atomicWrite(
    path.join(workerRoot, "thumb-cam.config.json"),
    `${JSON.stringify({
      serverUrl,
      deviceId: device.id,
      mountName: "THUMB_CAM",
      mountRoot: "/Volumes",
      pollIntervalMs: 5_000,
      settleDelayMs: 1_500,
      minimumFileAgeMs: 30_000,
      scanConcurrency: 2,
      snapshotConcurrency: 2,
      ollamaUrl: "http://127.0.0.1:11434",
      descriptionModel: "gemma4",
      descriptionPrompt:
        "describe the image from 1st person perspective as if you have captured it yourself in present tense, like an entry in the diary. Keep it short and informative",
      embeddingModel: "embeddinggemma",
      whisperExecutable: await executablePath("whisper"),
      whisperModel: "base",
      ffmpegExecutable: await executablePath("ffmpeg"),
      ffprobeExecutable: await executablePath("ffprobe"),
      workRoot: "~/Library/Application Support/Fractonica/ThumbCam",
    }, null, 2)}\n`,
    0o600,
  );
  await atomicWrite(
    path.join(workerRoot, ".env"),
    `THUMB_CAM_API_KEY=${created.secret}\n`,
    0o600,
  );
  await installWorkerService();
  console.log(`Configured THUMB agent ${device.id}.`);
  console.log("The background worker is running and will start automatically at login.");
} finally {
  password.fill?.(0);
}

async function request(
  pathname,
  { method = "GET", authorization, idempotencyKey, body } = {},
) {
  const response = await fetch(`${serverUrl}${pathname}`, {
    method,
    headers: {
      accept: "application/json",
      ...(body === undefined ? {} : { "content-type": "application/json" }),
      ...(authorization === undefined ? {} : { authorization }),
      ...(idempotencyKey === undefined
        ? {}
        : { "idempotency-key": idempotencyKey }),
    },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
  const value = await response.json().catch(() => undefined);
  if (!response.ok) {
    throw new Error(
      value?.detail ??
        value?.message ??
        `${method} ${pathname} failed with HTTP ${response.status}.`,
    );
  }
  return value;
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
      const text = chunk.toString("utf8");
      for (const character of text) {
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
          continue;
        }
        value += character;
      }
    };
    process.stdin.on("data", onData);
  });
}

async function atomicWrite(target, contents, mode) {
  const temporary = `${target}.${process.pid}.tmp`;
  await writeFile(temporary, contents, { encoding: "utf8", mode });
  await chmod(temporary, mode);
  await rename(temporary, target);
}

async function executablePath(name) {
  try {
    const { stdout } = await run("which", [name], { encoding: "utf8" });
    const resolved = stdout.trim();
    if (path.isAbsolute(resolved)) return resolved;
  } catch {
    // The config validator and worker diagnostics will report the missing tool.
  }
  return name;
}
