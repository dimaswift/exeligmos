import { createOllamaProvider } from "./providers/ollama.mjs";
import { createSpeShuProvider } from "./providers/speshu.mjs";
import { createMlxStudioProvider } from "./providers/mlx-studio.mjs";

const factories = new Map([
  ["ollama", createOllamaProvider],
  ["speshu", createSpeShuProvider],
  ["mlx-studio", createMlxStudioProvider],
]);

export class AgentCapabilityError extends Error {
  constructor(provider, capability) {
    super(`Agent provider ${provider} does not support ${capability}.`);
    this.name = "AgentCapabilityError";
    this.provider = provider;
    this.capability = capability;
  }
}

export class AgentProviderError extends Error {
  constructor(message, options) {
    super(message, options?.cause === undefined ? undefined : { cause: options.cause });
    this.name = "AgentProviderError";
    this.provider = options.provider;
    this.status = options.status;
    this.retryable = options.retryable ?? false;
    this.detail = options.detail;
  }
}

/**
 * Create a provider-neutral language-model agent.
 *
 * Messages use strings or portable content blocks:
 * `{type: "text", text}` and `{type: "image", data, mediaType}`.
 */
export function createAgent(config, options = {}) {
  const provider = normalizedProvider(config?.provider);
  const factory = factories.get(provider);
  if (factory === undefined) {
    throw new RangeError(
      `Unknown agent provider ${JSON.stringify(config?.provider)}. Expected ollama, speshu, or mlx-studio.`,
    );
  }
  return factory(
    {
      ...config,
      provider,
      baseUrl: normalizedBaseUrl(config.baseUrl),
      timeoutMs: positiveInteger(config.timeoutMs ?? 10 * 60_000, "timeoutMs"),
    },
    {
      fetch: options.fetch ?? globalThis.fetch,
      CapabilityError: AgentCapabilityError,
      ProviderError: AgentProviderError,
    },
  );
}

function normalizedProvider(value) {
  if (typeof value !== "string" || value.trim() === "") {
    throw new TypeError("Agent provider must be a non-empty string.");
  }
  return value.trim().toLowerCase();
}

function normalizedBaseUrl(value) {
  const url = new URL(value);
  if (!["http:", "https:"].includes(url.protocol)) {
    throw new TypeError("Agent baseUrl must use HTTP or HTTPS.");
  }
  return url.toString().replace(/\/$/, "");
}

function positiveInteger(value, name) {
  if (!Number.isSafeInteger(value) || value < 1) {
    throw new TypeError(`${name} must be a positive integer.`);
  }
  return value;
}
