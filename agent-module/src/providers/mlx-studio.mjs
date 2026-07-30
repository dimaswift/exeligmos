import { requestJson, requireModel } from "./shared.mjs";

export function createMlxStudioProvider(config, runtime) {
  return Object.freeze({
    provider: "mlx-studio",
    capabilities: Object.freeze({
      text: false,
      images: false,
      embeddings: false,
      imageGeneration: true,
    }),
    async complete() {
      throw new runtime.CapabilityError("mlx-studio", "text generation");
    },
    async embed() {
      throw new runtime.CapabilityError("mlx-studio", "embeddings");
    },
    async generateImage(request) {
      const model = requireModel(request.model);
      if (typeof request.prompt !== "string" || request.prompt.trim() === "") {
        throw new TypeError("Image generation prompt must be non-empty text.");
      }
      const size = imageSize(request.size ?? "512x512");
      const steps = boundedInteger(request.steps ?? 4, "steps", 1, 200);
      const guidance = boundedNumber(request.guidance ?? 0, "guidance", 0, 100);
      const response = await requestJson(
        runtime.fetch,
        "mlx-studio",
        `${config.baseUrl}/v1/images/generations`,
        {
          method: "POST",
          headers: {
            accept: "application/json",
            ...(typeof config.apiKey === "string" && config.apiKey !== ""
              ? { authorization: `Bearer ${config.apiKey}` }
              : {}),
            "content-type": "application/json",
          },
          body: JSON.stringify({
            model,
            prompt: request.prompt.trim(),
            size,
            steps,
            guidance,
            response_format: "b64_json",
          }),
          signal: request.signal ?? AbortSignal.timeout(config.timeoutMs),
        },
        runtime.ProviderError,
      );
      const encoded = response?.data?.[0]?.b64_json;
      if (typeof encoded !== "string" || encoded === "") {
        throw new runtime.ProviderError(
          `MLX Studio model ${model} returned no base64 image.`,
          { provider: "mlx-studio" },
        );
      }
      const mediaType = encoded.startsWith("/9j/")
        ? "image/jpeg"
        : "image/png";
      return {
        images: [{ data: encoded, mediaType }],
        model:
          typeof response.model === "string" && response.model !== ""
            ? response.model
            : model,
        provider: "mlx-studio",
        usage: {},
      };
    },
  });
}

function imageSize(value) {
  if (
    typeof value !== "string" ||
    !/^[1-9][0-9]{1,4}x[1-9][0-9]{1,4}$/.test(value)
  ) {
    throw new TypeError("Image size must use WIDTHxHEIGHT.");
  }
  return value;
}

function boundedInteger(value, name, minimum, maximum) {
  if (!Number.isSafeInteger(value) || value < minimum || value > maximum) {
    throw new TypeError(`${name} must be an integer from ${minimum} through ${maximum}.`);
  }
  return value;
}

function boundedNumber(value, name, minimum, maximum) {
  if (typeof value !== "number" || !Number.isFinite(value) || value < minimum || value > maximum) {
    throw new TypeError(`${name} must be from ${minimum} through ${maximum}.`);
  }
  return value;
}
