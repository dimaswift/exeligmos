import {
  requestJson,
  requireMessages,
  requireModel,
} from "./shared.mjs";

export function createSpeShuProvider(config, runtime) {
  if (typeof config.apiKey !== "string" || config.apiKey.trim() === "") {
    throw new TypeError("SpeShu agent provider requires apiKey.");
  }
  return Object.freeze({
    provider: "speshu",
    capabilities: Object.freeze({
      text: true,
      images: true,
      embeddings: false,
      imageGeneration: false,
    }),
    async complete(request) {
      const model = requireModel(request.model);
      const response = await requestJson(
        runtime.fetch,
        "speshu",
        `${config.baseUrl}/chat/completions`,
        {
          method: "POST",
          headers: {
            accept: "application/json",
            authorization: `Bearer ${config.apiKey}`,
            "content-type": "application/json",
          },
          body: JSON.stringify({
            model,
            messages: requireMessages(request.messages).map(speshuMessage),
            stream: false,
            temperature: request.temperature ?? 0.2,
            ...(request.maxTokens === undefined
              ? {}
              : { max_completion_tokens: request.maxTokens }),
            ...(request.responseFormat === undefined
              ? {}
              : { response_format: request.responseFormat }),
          }),
          signal: request.signal ?? AbortSignal.timeout(config.timeoutMs),
        },
        runtime.ProviderError,
      );
      const text = response?.choices?.[0]?.message?.content;
      if (typeof text !== "string" || text.trim() === "") {
        throw new runtime.ProviderError(`SpeShu model ${model} returned empty text.`, {
          provider: "speshu",
        });
      }
      return {
        text: text.trim(),
        model: typeof response.model === "string" ? response.model : model,
        provider:
          typeof response.provider === "string" ? response.provider : "speshu",
        usage: speshuUsage(response.usage),
      };
    },
    async embed() {
      throw new runtime.CapabilityError("speshu", "embeddings");
    },
    async generateImage() {
      throw new runtime.CapabilityError("speshu", "image generation");
    },
  });
}

function speshuMessage(message) {
  if (typeof message.content === "string") return message;
  return {
    ...message,
    content: message.content.map((block) =>
      block.type === "text"
        ? block
        : {
            type: "image_url",
            image_url: {
              url: `data:${block.mediaType};base64,${block.data}`,
            },
          },
    ),
  };
}

function speshuUsage(usage) {
  return {
    promptTokens: finiteNumber(usage?.prompt_tokens),
    completionTokens: finiteNumber(usage?.completion_tokens),
    totalTokens: finiteNumber(usage?.total_tokens),
    costRub: finiteNumber(usage?.cost_rub ?? usage?.cost),
  };
}

function finiteNumber(value) {
  return typeof value === "number" && Number.isFinite(value) ? value : 0;
}
