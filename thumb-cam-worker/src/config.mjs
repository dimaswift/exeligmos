import { readFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

export const DEFAULT_DESCRIPTION_PROMPT =
  "describe the image from 1st person perspective as if you have captured it yourself in present tense, like an entry in the diary. Keep it short and informative";

const defaults = Object.freeze({
  serverUrl: "http://127.0.0.1:8788",
  mountName: "THUMB_CAM",
  mountRoot: "/Volumes",
  pollIntervalMs: 5_000,
  settleDelayMs: 1_500,
  minimumFileAgeMs: 30_000,
  scanConcurrency: 2,
  snapshotConcurrency: 2,
  descriptionProvider: "ollama",
  descriptionBaseUrl: "http://127.0.0.1:11434",
  descriptionModel: "gemma4",
  descriptionPrompt: DEFAULT_DESCRIPTION_PROMPT,
  embeddingProvider: "ollama",
  embeddingBaseUrl: "http://127.0.0.1:11434",
  embeddingModel: "embeddinggemma",
  imageGenerationEnabled: true,
  imageProvider: "mlx-studio",
  imageBaseUrl: "http://127.0.0.1:8001",
  imageModel: "schnell",
  imageSize: "512x512",
  imageSteps: 4,
  imageGuidance: 0,
  imageTimeoutMs: 30_000,
  pythonExecutable: "python3",
  whisperModel: "mlx-community/whisper-large-v3-mlx",
  ffmpegExecutable: "ffmpeg",
  ffprobeExecutable: "ffprobe",
  workRoot: "~/Library/Application Support/Fractonica/ThumbCam",
});

const cliNames = new Map([
  ["--server", "serverUrl"],
  ["--device-id", "deviceId"],
  ["--volume", "mountName"],
  ["--mount-root", "mountRoot"],
  ["--description-provider", "descriptionProvider"],
  ["--description-base-url", "descriptionBaseUrl"],
  ["--model", "descriptionModel"],
  ["--prompt", "descriptionPrompt"],
  ["--embedding-provider", "embeddingProvider"],
  ["--embedding-base-url", "embeddingBaseUrl"],
  ["--embedding-model", "embeddingModel"],
  ["--image-base-url", "imageBaseUrl"],
  ["--image-model", "imageModel"],
  ["--image-size", "imageSize"],
  ["--image-steps", "imageSteps"],
  ["--image-guidance", "imageGuidance"],
  ["--whisper-model", "whisperModel"],
  ["--poll-ms", "pollIntervalMs"],
  ["--settle-ms", "settleDelayMs"],
  ["--minimum-age-ms", "minimumFileAgeMs"],
  ["--scan-concurrency", "scanConcurrency"],
  ["--snapshot-concurrency", "snapshotConcurrency"],
  ["--work-root", "workRoot"],
]);

export async function loadConfig(
  argv = process.argv.slice(2),
  env = process.env,
) {
  const parsed = parseArguments(argv);
  const fileConfig =
    parsed.configPath === undefined
      ? {}
      : JSON.parse(await readFile(path.resolve(parsed.configPath), "utf8"));
  const config = {
    ...defaults,
    ...fileConfig,
    ...environmentConfig(env),
    ...parsed.overrides,
    apiKey: parsed.apiKey ?? env.THUMB_CAM_API_KEY ?? fileConfig.apiKey,
    descriptionApiKey:
      env.THUMB_CAM_DESCRIPTION_API_KEY ??
      fileConfig.descriptionApiKey ??
      env.SPESHU_API_KEY,
    embeddingApiKey:
      env.THUMB_CAM_EMBEDDING_API_KEY ??
      fileConfig.embeddingApiKey ??
      env.SPESHU_API_KEY,
    imageApiKey:
      env.THUMB_CAM_IMAGE_API_KEY ?? fileConfig.imageApiKey,
    once: parsed.once,
  };

  for (const key of [
    "serverUrl",
    "deviceId",
    "apiKey",
    "mountName",
    "mountRoot",
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
    "imageSize",
    "pythonExecutable",
    "whisperModel",
    "ffmpegExecutable",
    "ffprobeExecutable",
    "workRoot",
  ]) {
    if (typeof config[key] !== "string" || config[key].trim() === "") {
      throw new Error(`${key} must be a non-empty string.`);
    }
  }
  if (!isUuid(config.deviceId)) {
    throw new Error("deviceId must be the UUID of the THUMB device.");
  }
  for (const name of ["descriptionProvider", "embeddingProvider"]) {
    if (!["ollama", "speshu"].includes(config[name])) {
      throw new Error(`${name} must be ollama or speshu.`);
    }
    const secretName =
      name === "descriptionProvider" ? "descriptionApiKey" : "embeddingApiKey";
    if (
      config[name] === "speshu" &&
      (typeof config[secretName] !== "string" ||
        config[secretName].trim() === "")
    ) {
      throw new Error(
        `${secretName} is required when ${name} is speshu.`,
      );
    }
  }
  for (const key of ["pollIntervalMs", "settleDelayMs"]) {
    if (!Number.isSafeInteger(config[key]) || config[key] < 100) {
      throw new Error(
        `${key} must be an integer of at least 100 milliseconds.`,
      );
    }
  }
  if (!Number.isSafeInteger(config.imageSteps) || config.imageSteps < 1) {
    throw new Error("imageSteps must be a positive integer.");
  }
  if (!Number.isFinite(config.imageGuidance) || config.imageGuidance < 0) {
    throw new Error("imageGuidance must be a non-negative number.");
  }
  if (!Number.isSafeInteger(config.imageTimeoutMs) || config.imageTimeoutMs < 1) {
    throw new Error("imageTimeoutMs must be a positive integer.");
  }
  if (
    !Number.isSafeInteger(config.minimumFileAgeMs) ||
    config.minimumFileAgeMs < 0
  ) {
    throw new Error("minimumFileAgeMs must be a non-negative integer.");
  }
  for (const key of ["scanConcurrency", "snapshotConcurrency"]) {
    if (
      !Number.isSafeInteger(config[key]) ||
      config[key] < 1 ||
      config[key] > 16
    ) {
      throw new Error(`${key} must be an integer from 1 through 16.`);
    }
  }

  return Object.freeze({
    ...config,
    serverUrl: absoluteHttpUrl(config.serverUrl, "serverUrl"),
    descriptionBaseUrl: absoluteHttpUrl(
      config.descriptionBaseUrl,
      "descriptionBaseUrl",
    ),
    embeddingBaseUrl: absoluteHttpUrl(
      config.embeddingBaseUrl,
      "embeddingBaseUrl",
    ),
    imageBaseUrl: absoluteHttpUrl(config.imageBaseUrl, "imageBaseUrl"),
    mountPath: path.resolve(config.mountRoot, config.mountName),
    workRoot: expandHome(config.workRoot),
  });
}

function parseArguments(argv) {
  const overrides = {};
  let configPath;
  let apiKey;
  let once = false;
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === "--once") {
      once = true;
      continue;
    }
    if (argument === "--config" || argument === "--api-key") {
      const value = argv[index + 1];
      if (value === undefined) throw new Error(`${argument} requires a value.`);
      index += 1;
      if (argument === "--config") configPath = value;
      else apiKey = value;
      continue;
    }
    const key = cliNames.get(argument);
    if (key === undefined) {
      throw new Error(`Unknown argument: ${argument}`);
    }
    const value = argv[index + 1];
    if (value === undefined) throw new Error(`${argument} requires a value.`);
    index += 1;
    overrides[key] = [
      "pollIntervalMs",
      "settleDelayMs",
      "minimumFileAgeMs",
      "scanConcurrency",
      "snapshotConcurrency",
      "imageSteps",
      "imageGuidance",
    ].includes(key)
      ? Number(value)
      : value;
  }
  return { apiKey, configPath, once, overrides };
}

function environmentConfig(env) {
  const entries = [
    ["THUMB_CAM_SERVER_URL", "serverUrl"],
    ["THUMB_CAM_DEVICE_ID", "deviceId"],
    ["THUMB_CAM_MOUNT_NAME", "mountName"],
    ["THUMB_CAM_MOUNT_ROOT", "mountRoot"],
    ["THUMB_CAM_DESCRIPTION_PROVIDER", "descriptionProvider"],
    ["THUMB_CAM_DESCRIPTION_BASE_URL", "descriptionBaseUrl"],
    ["THUMB_CAM_DESCRIPTION_MODEL", "descriptionModel"],
    ["THUMB_CAM_DESCRIPTION_PROMPT", "descriptionPrompt"],
    ["THUMB_CAM_EMBEDDING_PROVIDER", "embeddingProvider"],
    ["THUMB_CAM_EMBEDDING_BASE_URL", "embeddingBaseUrl"],
    ["THUMB_CAM_EMBEDDING_MODEL", "embeddingModel"],
    ["THUMB_CAM_IMAGE_BASE_URL", "imageBaseUrl"],
    ["THUMB_CAM_IMAGE_MODEL", "imageModel"],
    ["THUMB_CAM_IMAGE_SIZE", "imageSize"],
    ["THUMB_CAM_PYTHON_EXECUTABLE", "pythonExecutable"],
    ["THUMB_CAM_WHISPER_MODEL", "whisperModel"],
    ["THUMB_CAM_FFMPEG_EXECUTABLE", "ffmpegExecutable"],
    ["THUMB_CAM_FFPROBE_EXECUTABLE", "ffprobeExecutable"],
    ["THUMB_CAM_WORK_ROOT", "workRoot"],
  ];
  const result = {};
  for (const [environmentName, key] of entries) {
    if (env[environmentName] !== undefined) result[key] = env[environmentName];
  }
  for (const [environmentName, key] of [
    ["THUMB_CAM_POLL_INTERVAL_MS", "pollIntervalMs"],
    ["THUMB_CAM_SETTLE_DELAY_MS", "settleDelayMs"],
    ["THUMB_CAM_MINIMUM_FILE_AGE_MS", "minimumFileAgeMs"],
    ["THUMB_CAM_SCAN_CONCURRENCY", "scanConcurrency"],
    ["THUMB_CAM_SNAPSHOT_CONCURRENCY", "snapshotConcurrency"],
    ["THUMB_CAM_IMAGE_STEPS", "imageSteps"],
    ["THUMB_CAM_IMAGE_GUIDANCE", "imageGuidance"],
    ["THUMB_CAM_IMAGE_TIMEOUT_MS", "imageTimeoutMs"],
  ]) {
    if (env[environmentName] !== undefined)
      result[key] = Number(env[environmentName]);
  }
  return result;
}

function expandHome(value) {
  if (value === "~") return os.homedir();
  if (value.startsWith("~/")) return path.join(os.homedir(), value.slice(2));
  return path.resolve(value);
}

function absoluteHttpUrl(value, name) {
  const url = new URL(value);
  if (url.protocol !== "http:" && url.protocol !== "https:") {
    throw new Error(`${name} must use http or https.`);
  }
  return url.toString().replace(/\/$/, "");
}

function isUuid(value) {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(
    value,
  );
}
