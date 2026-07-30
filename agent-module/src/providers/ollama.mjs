import {
  requestJson,
  requireInput,
  requireMessages,
  requireModel,
} from "./shared.mjs";

export function createOllamaProvider(config, runtime) {
  return Object.freeze({
    provider: "ollama",
    capabilities: Object.freeze({
      text: true,
      images: true,
      embeddings: true,
      imageGeneration: false,
    }),
    async complete(request) {
      const model = requireModel(request.model);
      const messages = requireMessages(request.messages).map(ollamaMessage);
      const response = await requestJson(
        runtime.fetch,
        "ollama",
        `${config.baseUrl}/api/chat`,
        {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({
            model,
            stream: false,
            messages,
            options: { temperature: request.temperature ?? 0.2 },
          }),
          signal: request.signal ?? AbortSignal.timeout(config.timeoutMs),
        },
        runtime.ProviderError,
      );
      const text = response?.message?.content;
      if (typeof text !== "string" || text.trim() === "") {
        throw new runtime.ProviderError(`Ollama model ${model} returned empty text.`, {
          provider: "ollama",
        });
      }
      return {
        text: text.trim(),
        model: typeof response.model === "string" ? response.model : model,
        provider: "ollama",
        usage: ollamaUsage(response),
      };
    },
    async embed(request) {
      const model = requireModel(request.model);
      const input = requireInput(request.input);
      const response = await requestJson(
        runtime.fetch,
        "ollama",
        `${config.baseUrl}/api/embed`,
        {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ model, input }),
          signal: request.signal ?? AbortSignal.timeout(config.timeoutMs),
        },
        runtime.ProviderError,
      );
      const vectors = Array.isArray(response.embeddings)
        ? response.embeddings
        : Array.isArray(response.embedding)
          ? [response.embedding]
          : undefined;
      validateVectors(vectors, input.length, runtime.ProviderError);
      return {
        vectors,
        model: typeof response.model === "string" ? response.model : model,
        provider: "ollama",
        usage: ollamaUsage(response),
      };
    },
    async generateImage() {
      throw new runtime.CapabilityError("ollama", "image generation");
    },
  });
}

function ollamaMessage(message) {
  if (typeof message.content === "string") return message;
  const text = message.content
    .filter((block) => block.type === "text")
    .map((block) => block.text)
    .join("\n");
  const images = message.content
    .filter((block) => block.type === "image")
    .map((block) => block.data);
  return {
    role: message.role === "developer" ? "system" : message.role,
    content: text,
    ...(images.length === 0 ? {} : { images }),
  };
}

function validateVectors(vectors, count, ErrorType) {
  if (
    !Array.isArray(vectors) ||
    vectors.length !== count ||
    vectors.some(
      (vector) =>
        !Array.isArray(vector) ||
        vector.length === 0 ||
        vector.some((value) => typeof value !== "number" || !Number.isFinite(value)),
    )
  ) {
    throw new ErrorType("Ollama returned invalid embeddings.", {
      provider: "ollama",
    });
  }
}

function ollamaUsage(response) {
  return {
    promptTokens: finiteNumber(response.prompt_eval_count),
    completionTokens: finiteNumber(response.eval_count),
    totalTokens:
      finiteNumber(response.prompt_eval_count) + finiteNumber(response.eval_count),
  };
}

function finiteNumber(value) {
  return typeof value === "number" && Number.isFinite(value) ? value : 0;
}
