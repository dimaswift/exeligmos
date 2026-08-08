import assert from "node:assert/strict";
import test from "node:test";

import {
  chooseMostDistantSource,
  createDreamEmojiSignature,
  DreamAttemptFailure,
  DreamerWorker,
  MAX_DREAM_ATTEMPTS,
  nextRolloverInFuture,
  ROLLOVER_MILLISECONDS,
  validateDreamEmojiSignature,
} from "../src/worker.mjs";

test("moves a source forward by whole rollover periods until it is future", () => {
  const source = Date.parse("2026-01-01T00:00:00.000Z");
  const now = source + ROLLOVER_MILLISECONDS * 2;
  assert.equal(
    nextRolloverInFuture(new Date(source).toISOString(), now),
    new Date(source + ROLLOVER_MILLISECONDS * 3).toISOString(),
  );
});

test("keeps an already-future source date unchanged", () => {
  const future = "2026-08-01T00:00:00.000Z";
  assert.equal(
    nextRolloverInFuture(future, Date.parse("2026-07-30T00:00:00.000Z")),
    future,
  );
});

test("selects the oldest public source with the scheduled Saros spike", async () => {
  const selected = await chooseMostDistantSource(
    {
      async listRecords() {
        return {
          data: [
            record("taggd", "2020-01-01", ["dreamer"], 141),
            { ...record("privt", "2019-01-01", [], 141), visibility: "private" },
            {
              ...record("dream", "2018-01-01", [], 141),
              source: { provider: "dreamer" },
            },
            record("other", "2017-01-01", [], 142),
            record("newer", "2022-01-01", [], 141),
            record("oldest", "2021-01-01", [], 141),
          ],
          hasMore: false,
        };
      },
    },
    "dreamer",
    141,
  );
  assert.equal(selected.id, "oldest");
});

test("keeps meaningful spacing in a 3-12 emoji dream signature", () => {
  assert.equal(
    validateDreamEmojiSignature("🌙🪞✨   🏠🌲  👁️🫧"),
    "🌙🪞✨   🏠🌲  👁️🫧",
  );
  assert.throws(
    () => validateDreamEmojiSignature("dream 🌙🪞✨"),
    /non-emoji/,
  );
  assert.throws(
    () => validateDreamEmojiSignature("🌙✨"),
    /3 to 12/,
  );
});

test("asks the configured language agent for the signature", async () => {
  let prompt;
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (_input, init) => {
    prompt = JSON.parse(init.body).messages[0].content;
    return Response.json({ message: { content: "🌙🪞✨  🌲🏠" } });
  };
  try {
    const signature = await createDreamEmojiSignature(
      {
        descriptionProvider: "ollama",
        descriptionBaseUrl: "http://ollama.test",
        descriptionModel: "gemma4",
      },
      "I wander through a mirrored forest toward home.",
    );
    assert.equal(signature, "🌙🪞✨  🌲🏠");
    assert.match(prompt, /between 3 and 12 emojis/);
    assert.match(prompt, /mirrored forest/);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("skips a source after its third durable Dreamer failure", async () => {
  let attempts = 0;
  const marked = [];
  const worker = new DreamerWorker(
    {
      workRoot: "/tmp/dreamer-test",
      imageGenerationEnabled: true,
    },
    {
      client: {
        async findDream() {
          return undefined;
        },
        async startDreamAttempt(recordId) {
          attempts += 1;
          return {
            recordId,
            attempt: attempts,
            maxAttempts: MAX_DREAM_ATTEMPTS,
            allowed: attempts <= MAX_DREAM_ATTEMPTS,
          };
        },
        async markDreamed(recordId) {
          marked.push(recordId);
        },
      },
      log: { info() {} },
    },
  );
  worker.processDreamSource = async () => {
    throw new Error("image generator unavailable");
  };
  const identity = { id: "schedule:141", kind: "scheduled" };
  const source = { id: "src01" };

  for (let expected = 1; expected <= MAX_DREAM_ATTEMPTS; expected += 1) {
    await assert.rejects(
      () => worker.dreamSource(identity, source, { id: "dreamer" }),
      (error) => {
        assert.ok(error instanceof DreamAttemptFailure);
        assert.equal(error.attempt, expected);
        assert.equal(error.exhausted, expected === MAX_DREAM_ATTEMPTS);
        return true;
      },
    );
  }
  assert.deepEqual(marked, ["src01"]);
});

test("does not process a source whose durable attempt limit was already exceeded", async () => {
  let processed = false;
  const marked = [];
  const worker = new DreamerWorker(
    {
      workRoot: "/tmp/dreamer-test",
      imageGenerationEnabled: true,
    },
    {
      client: {
        async findDream() {
          return undefined;
        },
        async startDreamAttempt(recordId) {
          return {
            recordId,
            attempt: MAX_DREAM_ATTEMPTS + 1,
            maxAttempts: MAX_DREAM_ATTEMPTS,
            allowed: false,
          };
        },
        async markDreamed(recordId) {
          marked.push(recordId);
        },
      },
      log: { info() {} },
    },
  );
  worker.processDreamSource = async () => {
    processed = true;
  };

  await assert.rejects(
    () =>
      worker.dreamSource(
        { id: "schedule:141", kind: "scheduled" },
        { id: "src01" },
        { id: "dreamer" },
      ),
    (error) => {
      assert.ok(error instanceof DreamAttemptFailure);
      assert.equal(error.exhausted, true);
      return true;
    },
  );
  assert.equal(processed, false);
  assert.deepEqual(marked, ["src01"]);
});

function record(id, occurredAt, tagIds, saros) {
  return {
    id,
    visibility: "public",
    occurredAt: new Date(occurredAt).toISOString(),
    tagIds,
    payload: { context: { spikes: [{ saros }] } },
  };
}
