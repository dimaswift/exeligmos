import { readFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

const defaults = Object.freeze({
  serverUrl: "http://127.0.0.1:8788",
  idempotencyPrefix: "dreamer",
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
  workRoot: "~/Library/Application Support/Fractonica/Dreamer",
});

export async function loadConfig(
  argv = process.argv.slice(2),
  env = process.env,
) {
  const once = argv.includes("--once");
  const configIndex = argv.indexOf("--config");
  const configPath =
    configIndex === -1 ? "dreamer.config.json" : argv[configIndex + 1];
  if (configIndex !== -1 && configPath === undefined) {
    throw new Error("--config requires a value.");
  }
  const file = await readFile(path.resolve(configPath), "utf8");
  const saved = JSON.parse(file);
  const config = {
    ...defaults,
    ...saved,
    apiKey: env.DREAMER_API_KEY ?? saved.apiKey,
    descriptionApiKey:
      env.DREAMER_DESCRIPTION_API_KEY ?? saved.descriptionApiKey ?? env.SPESHU_API_KEY,
    embeddingApiKey:
      env.DREAMER_EMBEDDING_API_KEY ?? saved.embeddingApiKey ?? env.SPESHU_API_KEY,
    imageApiKey: env.DREAMER_IMAGE_API_KEY ?? saved.imageApiKey,
    once,
  };
  for (const key of [
    "serverUrl",
    "deviceId",
    "apiKey",
    "descriptionProvider",
    "descriptionBaseUrl",
    "descriptionModel",
    "descriptionPrompt",
    "embeddingProvider",
    "embeddingBaseUrl",
    "embeddingModel",
    "imageProvider",
    "imageBaseUrl",
    "imageModel",
    "imagePromptReference",
    "imageSize",
    "ffmpegExecutable",
    "workRoot",
  ]) {
    if (typeof config[key] !== "string" || config[key].trim() === "") {
      throw new Error(`${key} must be a non-empty string.`);
    }
  }
  if (!/^[0-9a-f-]{36}$/i.test(config.deviceId)) {
    throw new Error("deviceId must be a UUID.");
  }
  return Object.freeze({
    ...config,
    serverUrl: httpUrl(config.serverUrl),
    descriptionBaseUrl: httpUrl(config.descriptionBaseUrl),
    embeddingBaseUrl: httpUrl(config.embeddingBaseUrl),
    imageBaseUrl: httpUrl(config.imageBaseUrl),
    workRoot: expandHome(config.workRoot),
  });
}

function httpUrl(value) {
  const url = new URL(value);
  if (!["http:", "https:"].includes(url.protocol)) {
    throw new Error("Agent URLs must use HTTP or HTTPS.");
  }
  return url.toString().replace(/\/$/, "");
}

function expandHome(value) {
  if (value === "~") return os.homedir();
  if (value.startsWith("~/")) return path.join(os.homedir(), value.slice(2));
  return path.resolve(value);
}
