# Exeligmos agent module

Dependency-free provider interface for model-backed agents used by Exeligmos
workers and services.

```js
import { createAgent } from "@exeligmos/agent";

const agent = createAgent({
  provider: "ollama",
  baseUrl: "http://127.0.0.1:11434",
});

const answer = await agent.complete({
  model: "gemma4",
  messages: [{ role: "user", content: "Summarize this record." }],
});
```

The portable message format accepts plain strings or `text` and `image`
content blocks. Provider adapters translate those blocks without exposing
provider-specific request shapes to callers.

## Providers

- `ollama`: text, images, and embeddings through `/api/chat` and `/api/embed`
- `speshu`: text and images through the OpenAI-compatible
  `/chat/completions` REST endpoint
- `mlx-studio`: image generation through `/v1/images/generations`

SpeShu configuration requires an API key. Its documented chat API does not
define an embeddings endpoint, so `embed()` reports an explicit unsupported
capability. A caller may use SpeShu for generation and a separate Ollama agent
for embeddings.
