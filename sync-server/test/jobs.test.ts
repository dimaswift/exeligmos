import assert from "node:assert/strict";
import test from "node:test";

import { HttpProblem } from "../src/http/problem.js";
import {
  validateCreateIngestionJobInput,
  validateUpdateIngestionItemInput,
} from "../src/resources/jobs.js";
import { validateRecordEmbeddingInput } from "../src/resources/records.js";

const deviceId = "2dca8eab-00a8-4e94-9bd2-2fcbfe17e890";

test("ingestion declarations normalize capture time and reject unsafe or duplicate sources", () => {
  const sourceKey = "a".repeat(64);
  const valid = validateCreateIngestionJobInput({
    deviceId,
    source: { volume: "THUMB_CAM" },
    config: { model: "gemma4" },
    items: [
      {
        sourceKey,
        groupKey: "b".repeat(64),
        relativePath: "PHOTO/IMG_0001.JPG",
        kind: "photo",
        capturedAt: "2026-07-29T11:00:00+03:00",
        byteLength: 42,
        contentSha256: "c".repeat(64),
      },
    ],
  });
  assert.equal(valid.items[0]?.capturedAt, "2026-07-29T08:00:00.000Z");

  assert.throws(
    () =>
      validateCreateIngestionJobInput({
        ...valid,
        items: [
          {
            ...valid.items[0]!,
            relativePath: "../IMG_0001.JPG",
          },
        ],
      }),
    isProblem("invalid_job_item"),
  );
  assert.throws(
    () =>
      validateCreateIngestionJobInput({
        ...valid,
        items: [valid.items[0]!, valid.items[0]!],
      }),
    isProblem("invalid_job_item"),
  );
});

test("job item progress requires failure errors and validates persisted output tokens", () => {
  assert.deepEqual(
    validateUpdateIngestionItemInput({
      status: "processing",
      stage: "creating_record",
      outputMode: "single-positive",
    }),
    {
      status: "processing",
      stage: "creating_record",
      outputMode: "single-positive",
    },
  );
  assert.throws(
    () => validateUpdateIngestionItemInput({ status: "failed" }),
    isProblem("job_item_error_required"),
  );
  assert.throws(
    () =>
      validateUpdateIngestionItemInput({
        status: "processing",
        outputMode: "Single Positive",
      }),
    isProblem("invalid_job_output_mode"),
  );
});

test("embedding validation accepts finite vectors and rejects non-finite values", () => {
  const valid = validateRecordEmbeddingInput({
    recordRevision: 1,
    model: "embeddinggemma",
    contentHash: "d".repeat(64),
    vector: [0, -0.5, 1],
  });
  assert.deepEqual(valid.vector, [0, -0.5, 1]);

  assert.throws(
    () =>
      validateRecordEmbeddingInput({
        ...valid,
        vector: [Number.NaN],
      }),
    isProblem("invalid_embedding_vector"),
  );
  assert.throws(
    () =>
      validateRecordEmbeddingInput({
        ...valid,
        vector: [1e100],
      }),
    isProblem("invalid_embedding_vector"),
  );
});

function isProblem(code: string): (error: unknown) => boolean {
  return (error) => error instanceof HttpProblem && error.code === code;
}
