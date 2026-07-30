import assert from "node:assert/strict";
import test from "node:test";

import {
  chooseRecordEmoji,
  combineObservations,
  createImagePrompt,
} from "../src/agent-tasks.mjs";

const config = {
  descriptionProvider: "ollama",
  descriptionBaseUrl: "http://ollama.test",
  embeddingProvider: "ollama",
  embeddingBaseUrl: "http://ollama.test",
  descriptionModel: "gemma4",
  descriptionPrompt: "Write a short first-person diary entry.",
};

test("summarizes photo and audio observations while excluding video", async () => {
  let prompt;
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (_input, init) => {
    prompt = JSON.parse(init.body).messages[0].content;
    return Response.json({
      message: { content: "I hear rain while photographing the street." },
    });
  };

  try {
    const summary = await combineObservations(config, [
      {
        kind: "photo",
        capturedAt: "2026-07-30T10:00:00.000Z",
        text: "I photograph a wet street.",
      },
      {
        kind: "video",
        capturedAt: "2026-07-30T10:00:01.000Z",
        text: "I film a passing red car.",
      },
      {
        kind: "audio",
        capturedAt: "2026-07-30T10:00:02.000Z",
        text: "I hear rain on my umbrella.",
      },
    ]);

    assert.equal(summary, "I hear rain while photographing the street.");
    assert.match(prompt, /wet street/);
    assert.match(prompt, /rain on my umbrella/);
    assert.doesNotMatch(prompt, /passing red car/);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("chooses one emoji only after receiving the record summary", async () => {
  let prompt;
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (_input, init) => {
    prompt = JSON.parse(init.body).messages[0].content;
    return Response.json({
      message: { content: "The best match is 🌧️." },
    });
  };

  try {
    const emoji = await chooseRecordEmoji(
      config,
      "I hear rain while photographing the street.",
    );
    assert.equal(emoji, "🌧️");
    assert.match(prompt, /I hear rain while photographing the street/);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("turns the final summary into a visual-only generation prompt", async () => {
  let prompt;
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (_input, init) => {
    prompt = JSON.parse(init.body).messages[0].content;
    return Response.json({
      message: {
        content:
          "First-person view of a rain-slick street under amber lamps, cinematic reflections",
      },
    });
  };

  try {
    const result = await createImagePrompt(
      {
        ...config,
        imagePromptReference:
          "A compact workstation on a walnut desk, product photo",
      },
      "I walk along a wet street beneath amber lamps.",
    );
    assert.match(result, /rain-slick street/);
    assert.match(prompt, /I walk along a wet street/);
    assert.match(prompt, /visually renderable/);
    assert.match(prompt, /compact workstation on a walnut desk/);
    assert.match(prompt, /Do not copy its scene/);
  } finally {
    globalThis.fetch = originalFetch;
  }
});
