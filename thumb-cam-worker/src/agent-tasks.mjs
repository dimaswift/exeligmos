import { readFile } from "node:fs/promises";

import { createAgent } from "../../agent-module/src/index.mjs";

export async function describeVisual(config, imagePath) {
  const image = (await readFile(imagePath)).toString("base64");
  return agentChat(config, config.descriptionPrompt, image);
}

export async function normalizeTranscript(config, transcript) {
  return agentChat(
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
  return agentChat(
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
  const response = await agentChat(
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
      `Agent model ${config.descriptionModel} did not return an emoji.`,
    );
  }
  return emoji;
}

export async function createImagePrompt(config, summary) {
  return agentChat(
    config,
    [
      "Write a concise image-generation prompt that recreates the scene in this diary entry.",
      "Describe only visible subjects, setting, lighting, camera angle, mood, and composition.",
      "The scene must be upright: sky and ceilings above, ground and floors below, and no inverted subjects.",
      "Do not mention a diary, summary, text, prompt, model, or anything that is not visually renderable.",
      ...(typeof config.imagePromptReference === "string" &&
      config.imagePromptReference.trim() !== ""
        ? [
            "Use the following only as a reference for prompt structure, specificity, and style. Do not copy its scene:",
            config.imagePromptReference.trim(),
          ]
        : []),
      "Reply with the prompt only.",
      "",
      summary,
    ].join("\n"),
  );
}

export async function createEmbedding(config, text) {
  const response = await embeddingAgent(config).embed({
    model: config.embeddingModel,
    input: text,
  });
  return response.vectors[0];
}

async function agentChat(config, content, image) {
  const response = await descriptionAgent(config).complete({
    model: config.descriptionModel,
    messages: [
      {
        role: "user",
        content:
          image === undefined
            ? content
            : [
                { type: "text", text: content },
                { type: "image", mediaType: "image/jpeg", data: image },
              ],
      },
    ],
    temperature: 0.2,
  });
  return response.text;
}

function descriptionAgent(config) {
  return createAgent({
    provider: config.descriptionProvider,
    baseUrl: config.descriptionBaseUrl,
    apiKey: config.descriptionApiKey,
  });
}

function embeddingAgent(config) {
  return createAgent({
    provider: config.embeddingProvider,
    baseUrl: config.embeddingBaseUrl,
    apiKey: config.embeddingApiKey,
  });
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
