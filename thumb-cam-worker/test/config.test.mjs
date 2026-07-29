import assert from "node:assert/strict";
import test from "node:test";

import { DEFAULT_DESCRIPTION_PROMPT, loadConfig } from "../src/config.mjs";

test("uses the requested Gemma prompt and configurable local models", async () => {
  const config = await loadConfig(["--once", "--model", "gemma4:e4b"], {
    THUMB_CAM_API_KEY: "exk_secret",
    THUMB_CAM_DEVICE_ID: "11111111-1111-4111-8111-111111111111",
    THUMB_CAM_EMBEDDING_MODEL: "embeddinggemma:latest",
  });
  assert.equal(config.once, true);
  assert.equal(config.descriptionModel, "gemma4:e4b");
  assert.equal(config.descriptionPrompt, DEFAULT_DESCRIPTION_PROMPT);
  assert.equal(config.embeddingModel, "embeddinggemma:latest");
  assert.equal(config.whisperModel, "base");
  assert.equal(config.mountPath, "/Volumes/THUMB_CAM");
  assert.equal(config.minimumFileAgeMs, 30_000);
  assert.equal(config.scanConcurrency, 2);
  assert.equal(config.snapshotConcurrency, 2);
});

test("rejects a missing device-bound API key", async () => {
  await assert.rejects(
    loadConfig([], {
      THUMB_CAM_DEVICE_ID: "11111111-1111-4111-8111-111111111111",
    }),
    /apiKey must be a non-empty string/,
  );
});

test("configures quiescence and bounded filesystem concurrency", async () => {
  const config = await loadConfig(
    [
      "--minimum-age-ms",
      "45000",
      "--scan-concurrency",
      "3",
      "--snapshot-concurrency",
      "4",
    ],
    {
      THUMB_CAM_API_KEY: "exk_secret",
      THUMB_CAM_DEVICE_ID: "11111111-1111-4111-8111-111111111111",
    },
  );
  assert.equal(config.minimumFileAgeMs, 45_000);
  assert.equal(config.scanConcurrency, 3);
  assert.equal(config.snapshotConcurrency, 4);

  await assert.rejects(
    loadConfig(["--scan-concurrency", "0"], {
      THUMB_CAM_API_KEY: "exk_secret",
      THUMB_CAM_DEVICE_ID: "11111111-1111-4111-8111-111111111111",
    }),
    /scanConcurrency must be an integer from 1 through 16/,
  );
  await assert.rejects(
    loadConfig(["--snapshot-concurrency", "17"], {
      THUMB_CAM_API_KEY: "exk_secret",
      THUMB_CAM_DEVICE_ID: "11111111-1111-4111-8111-111111111111",
    }),
    /snapshotConcurrency must be an integer from 1 through 16/,
  );
});
