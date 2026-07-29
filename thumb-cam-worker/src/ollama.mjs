import { readFile } from "node:fs/promises";

export async function describeVisual(config, imagePath) {
  const image = (await readFile(imagePath)).toString("base64");
  return ollamaChat(config, config.descriptionPrompt, [image]);
}

export async function normalizeTranscript(config, transcript) {
  return ollamaChat(
    config,
    [
      "Normalize this speech-to-text transcript into a short first-person diary entry in present tense.",
      "Repair likely recognition mistakes and fill only clearly recoverable gaps; never invent events or details.",
      "",
      transcript,
    ].join("\n"),
  );
}

export async function combineObservations(config, observations) {
  const included = observations.filter(
    (observation) => observation.kind !== "video",
  );
  const ordered = included
    .map(
      (observation, index) =>
        `${index + 1}. ${observation.kind} captured at ${observation.capturedAt}: ${observation.text}`,
    )
    .join("\n");
  return ollamaChat(
    config,
    [
      config.descriptionPrompt,
      "",
      included.length === 0
        ? "Write one short first-person diary sentence saying that I capture a video. Do not infer its contents."
        : "Combine the following chronological photo and audio observations into one coherent diary entry.",
      "Do not mention filenames, models, transcription, or the act of combining notes.",
      ...(ordered === "" ? [] : ["", ordered]),
    ].join("\n"),
  );
}

export async function chooseRecordEmoji(config, summary) {
  const response = await ollamaChat(
    config,
    [
      "Choose the single emoji that best captures this diary entry.",
      "Reply with exactly one emoji and no words, punctuation, or explanation.",
      "",
      summary,
    ].join("\n"),
  );
  const emoji = firstEmoji(response);
  if (emoji === undefined) {
    throw new Error(
      `Ollama model ${config.descriptionModel} did not return an emoji.`,
    );
  }
  return emoji;
}

export async function createEmbedding(config, text) {
  const response = await ollamaRequest(config, "/api/embed", {
    model: config.embeddingModel,
    input: text,
  });
  const embedding = Array.isArray(response.embeddings)
    ? response.embeddings[0]
    : response.embedding;
  if (
    !Array.isArray(embedding) ||
    embedding.length < 1 ||
    embedding.some(
      (value) => typeof value !== "number" || !Number.isFinite(value),
    )
  ) {
    throw new Error("Ollama returned an invalid embedding.");
  }
  return embedding;
}

async function ollamaChat(config, content, images = []) {
  const response = await ollamaRequest(config, "/api/chat", {
    model: config.descriptionModel,
    stream: false,
    messages: [
      {
        role: "user",
        content,
        ...(images.length === 0 ? {} : { images }),
      },
    ],
    options: { temperature: 0.2 },
  });
  const text = response?.message?.content;
  if (typeof text !== "string" || text.trim() === "") {
    throw new Error(
      `Ollama model ${config.descriptionModel} returned an empty response.`,
    );
  }
  return text.trim();
}

async function ollamaRequest(config, pathname, body) {
  let response;
  try {
    response = await fetch(`${config.ollamaUrl}${pathname}`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(10 * 60_000),
    });
  } catch (cause) {
    throw new Error(`Could not reach Ollama at ${config.ollamaUrl}.`, {
      cause,
    });
  }
  if (!response.ok) {
    const detail = (await response.text()).slice(0, 2_000);
    throw new Error(
      `Ollama ${pathname} failed (${response.status}): ${detail}`,
    );
  }
  return response.json();
}

function firstEmoji(value) {
  const segments = new Intl.Segmenter(undefined, {
    granularity: "grapheme",
  }).segment(value.trim());
  for (const { segment } of segments) {
    if (
      /[\p{Extended_Pictographic}\p{Emoji_Presentation}\u20E3]/u.test(segment)
    ) {
      return segment;
    }
  }
  return undefined;
}
