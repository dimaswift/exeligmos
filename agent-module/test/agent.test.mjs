import assert from "node:assert/strict";
import test from "node:test";

import {
  AgentCapabilityError,
  AgentProviderError,
  createAgent,
} from "../src/index.mjs";

test("Ollama maps portable image messages and normalizes completion usage", async () => {
  let request;
  const agent = createAgent(
    {
      provider: "ollama",
      baseUrl: "http://ollama.test",
    },
    {
      fetch: async (input, init) => {
        request = new Request(input, init);
        return Response.json({
          model: "gemma4",
          message: { content: "  I see two mirrored faces.  " },
          prompt_eval_count: 12,
          eval_count: 8,
        });
      },
    },
  );

  const result = await agent.complete({
    model: "gemma4",
    messages: [
      {
        role: "user",
        content: [
          { type: "text", text: "Describe this." },
          { type: "image", mediaType: "image/jpeg", data: "aW1hZ2U=" },
        ],
      },
    ],
  });

  assert.equal(request.url, "http://ollama.test/api/chat");
  assert.deepEqual(await request.json(), {
    model: "gemma4",
    stream: false,
    messages: [
      {
        role: "user",
        content: "Describe this.",
        images: ["aW1hZ2U="],
      },
    ],
    options: { temperature: 0.2 },
  });
  assert.deepEqual(result, {
    text: "I see two mirrored faces.",
    model: "gemma4",
    provider: "ollama",
    usage: { promptTokens: 12, completionTokens: 8, totalTokens: 20 },
  });
});

test("Ollama normalizes one embedding vector per input", async () => {
  const agent = createAgent(
    { provider: "ollama", baseUrl: "http://ollama.test" },
    {
      fetch: async () =>
        Response.json({
          model: "embeddinggemma",
          embeddings: [
            [0.1, 0.2],
            [0.3, 0.4],
          ],
        }),
    },
  );

  const result = await agent.embed({
    model: "embeddinggemma",
    input: ["first", "second"],
  });

  assert.deepEqual(result.vectors, [
    [0.1, 0.2],
    [0.3, 0.4],
  ]);
});

test("SpeShu uses its OpenAI-compatible REST contract for vision chat", async () => {
  let request;
  const agent = createAgent(
    {
      provider: "speshu",
      baseUrl: "https://speshu.ai/api/v1",
      apiKey: "speshu-secret",
    },
    {
      fetch: async (input, init) => {
        request = new Request(input, init);
        return Response.json({
          model: "google/gemini-2.5-flash",
          provider: "Google",
          choices: [
            {
              message: { role: "assistant", content: "A mirrored room." },
            },
          ],
          usage: {
            prompt_tokens: 20,
            completion_tokens: 4,
            total_tokens: 24,
            cost_rub: 0.03,
          },
        });
      },
    },
  );

  const result = await agent.complete({
    model: "google/gemini-2.5-flash",
    messages: [
      {
        role: "user",
        content: [
          { type: "text", text: "Describe this." },
          { type: "image", mediaType: "image/jpeg", data: "aW1hZ2U=" },
        ],
      },
    ],
    maxTokens: 80,
  });

  assert.equal(request.url, "https://speshu.ai/api/v1/chat/completions");
  assert.equal(request.headers.get("authorization"), "Bearer speshu-secret");
  assert.deepEqual(await request.json(), {
    model: "google/gemini-2.5-flash",
    messages: [
      {
        role: "user",
        content: [
          { type: "text", text: "Describe this." },
          {
            type: "image_url",
            image_url: {
              url: "data:image/jpeg;base64,aW1hZ2U=",
            },
          },
        ],
      },
    ],
    stream: false,
    temperature: 0.2,
    max_completion_tokens: 80,
  });
  assert.deepEqual(result, {
    text: "A mirrored room.",
    model: "google/gemini-2.5-flash",
    provider: "Google",
    usage: {
      promptTokens: 20,
      completionTokens: 4,
      totalTokens: 24,
      costRub: 0.03,
    },
  });
  await assert.rejects(
    agent.embed({ model: "anything", input: "text" }),
    AgentCapabilityError,
  );
});

test("providers expose actionable normalized HTTP failures", async () => {
  const agent = createAgent(
    {
      provider: "speshu",
      baseUrl: "https://speshu.ai/api/v1",
      apiKey: "speshu-secret",
    },
    {
      fetch: async () =>
        new Response('{"message":"rate limited"}', { status: 429 }),
    },
  );

  await assert.rejects(
    agent.complete({
      model: "openai/gpt-5.5",
      messages: [{ role: "user", content: "Hello" }],
    }),
    (error) => {
      assert.ok(error instanceof AgentProviderError);
      assert.equal(error.provider, "speshu");
      assert.equal(error.status, 429);
      assert.equal(error.retryable, true);
      assert.match(error.detail, /rate limited/);
      return true;
    },
  );
});

test("MLX Studio generates a portable base64 image", async () => {
  let request;
  const agent = createAgent(
    {
      provider: "mlx-studio",
      baseUrl: "http://localhost:8001",
      timeoutMs: 30_000,
    },
    {
      fetch: async (input, init) => {
        request = new Request(input, init);
        return Response.json({
          model: "schnell",
          data: [{ b64_json: "iVBORw0KGgo=" }],
        });
      },
    },
  );

  const result = await agent.generateImage({
    model: "schnell",
    prompt: "A compact workstation on a walnut desk",
    size: "512x512",
    steps: 4,
    guidance: 0,
  });

  assert.equal(request.url, "http://localhost:8001/v1/images/generations");
  assert.deepEqual(await request.json(), {
    model: "schnell",
    prompt: "A compact workstation on a walnut desk",
    size: "512x512",
    steps: 4,
    guidance: 0,
    response_format: "b64_json",
  });
  assert.deepEqual(result, {
    images: [{ data: "iVBORw0KGgo=", mediaType: "image/png" }],
    model: "schnell",
    provider: "mlx-studio",
    usage: {},
  });
});
