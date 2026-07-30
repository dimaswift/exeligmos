import { createHash } from "node:crypto";
import { mkdir } from "node:fs/promises";

import { createAgent } from "../../agent-module/src/index.mjs";
import {
  createEmbedding,
  createImagePrompt,
} from "../../thumb-cam-worker/src/agent-tasks.mjs";
import { generateMirroredImage } from "../../thumb-cam-worker/src/image-generation.mjs";
import { sarosRolloverScheduleAt } from "./schedule.mjs";
import { DreamerClient } from "./server-client.mjs";

export const ROLLOVER_MILLISECONDS = 1_111_260_000;
const ON_DEMAND_POLL_MILLISECONDS = 5_000;

export class DreamerWorker {
  constructor(config, options = {}) {
    this.config = config;
    this.client = options.client ?? new DreamerClient(config);
    this.log = options.log ?? console;
    this.sleep = options.sleep ?? delay;
    this.now = options.now ?? Date.now;
    this.scheduleAt = options.scheduleAt ?? sarosRolloverScheduleAt;
    this.scheduledRollover = undefined;
    this.stopped = false;
  }

  stop() {
    this.stopped = true;
  }

  async run() {
    await mkdir(this.config.workRoot, { recursive: true });
    do {
      await this.refreshConfig();
      if (this.config.enabled === false) {
        this.scheduledRollover = undefined;
        await this.reportRuntime({ state: "disabled" });
        if (this.config.once) break;
        await this.sleep(this.config.pollIntervalMs);
        continue;
      }

      if (this.scheduledRollover === undefined) {
        this.scheduledRollover = this.scheduleAt(this.now() / 1_000)[0];
      }
      const schedule = this.scheduledRollover;
      if (schedule === undefined) {
        await this.reportRuntime({
          state: "error",
          message: "No active Saros rollover could be scheduled.",
        });
        if (this.config.once) break;
        await this.sleep(this.config.pollIntervalMs);
        continue;
      }

      let request = null;
      try {
        request = await this.client.claimDreamRequest();
      } catch (error) {
        this.log.warn?.(
          `Could not read the on-demand dream queue: ${
            error instanceof Error ? error.message : String(error)
          }`,
        );
      }
      if (request !== null) {
        try {
          await this.reportRuntime({
            ...waitingRuntime(schedule),
            state: "creating",
            startedAt: new Date(this.now()).toISOString(),
            sourceRecordId: request.recordId,
            message: "Creating an on-demand dream.",
          });
          const record = await this.dreamOnDemand(request);
          await this.client.completeDreamRequest(request.jobId, record.id);
        } catch (error) {
          const message = error instanceof Error ? error.message : String(error);
          this.log.error(`On-demand dream failed: ${message}`);
          try {
            await this.client.failDreamRequest(request.jobId, message);
          } catch (reportError) {
            this.log.warn?.(
              `Could not mark on-demand dream ${request.jobId} failed: ${
                reportError instanceof Error
                  ? reportError.message
                  : String(reportError)
              }`,
            );
          }
          await this.reportRuntime({
            ...waitingRuntime(schedule),
            state: "error",
            sourceRecordId: request.recordId,
            message,
          });
        }
        if (this.config.once) break;
        await this.sleep(Math.min(this.config.pollIntervalMs, 1_000));
        continue;
      }

      const remainingMs = schedule.epochSeconds * 1_000 - this.now();
      if (!this.config.once && remainingMs > 0) {
        await this.reportRuntime(waitingRuntime(schedule));
        await this.sleep(
          Math.min(
            this.config.pollIntervalMs,
            ON_DEMAND_POLL_MILLISECONDS,
            remainingMs,
          ),
        );
        continue;
      }

      try {
        await this.reportRuntime({
          ...waitingRuntime(schedule),
          state: "creating",
          startedAt: new Date(this.now()).toISOString(),
        });
        const record = await this.dreamOnce(schedule);
        if (record === undefined) {
          this.log.info(
            `Dreamer found no eligible record with Saros ${schedule.saros}.`,
          );
        }
        this.scheduledRollover = undefined;
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        this.log.error(`Dreamer cycle failed: ${message}`);
        await this.reportRuntime({
          ...waitingRuntime(schedule),
          state: "error",
          message,
        });
      }
      if (this.config.once) break;
      await this.sleep(Math.min(this.config.pollIntervalMs, 1_000));
    } while (!this.stopped);
  }

  async refreshConfig() {
    try {
      const worker = await this.client.getCurrentWorker();
      this.config = Object.freeze({ ...this.config, ...worker.config });
    } catch (error) {
      this.log.warn?.(
        `Could not refresh Dreamer settings: ${
          error instanceof Error ? error.message : String(error)
        }`,
      );
    }
  }

  async reportRuntime(runtime) {
    try {
      await this.client.reportRuntime({
        nextRolloverAt: null,
        saros: null,
        scheduleId: null,
        startedAt: null,
        sourceRecordId: null,
        message: null,
        ...runtime,
      });
    } catch (error) {
      this.log.warn?.(
        `Could not report Dreamer status: ${
          error instanceof Error ? error.message : String(error)
        }`,
      );
    }
  }

  async dreamOnce(schedule) {
    if (this.config.imageGenerationEnabled === false) return undefined;
    const tag = await this.client.ensureDreamerTag();
    const existing = await this.client.findDream(schedule.id);
    if (existing !== undefined) {
      const sourceRecordId = existing.metadata?.dreamer?.sourceRecordId;
      if (typeof sourceRecordId === "string") {
        await this.client.markDreamed(sourceRecordId);
      }
      return existing;
    }
    const source = await chooseMostDistantSource(
      this.client,
      tag.id,
      schedule.saros,
    );
    if (source === undefined) return undefined;

    await this.reportRuntime({
      ...waitingRuntime(schedule),
      state: "creating",
      startedAt: new Date(this.now()).toISOString(),
      sourceRecordId: source.id,
    });
    return this.dreamSource(
      { ...schedule, kind: "scheduled" },
      source,
      tag,
    );
  }

  async dreamOnDemand(request) {
    if (this.config.imageGenerationEnabled === false) {
      throw new Error("Dreamer image generation is disabled.");
    }
    const source = await this.client.getRecord(request.recordId);
    if (source.visibility !== "public") {
      throw new Error("Only public records can be dreamed.");
    }
    const tag = await this.client.ensureDreamerTag();
    return this.dreamSource(
      {
        id: `on-demand:${request.jobId}`,
        kind: "on-demand",
        jobId: request.jobId,
        requestedAt: request.requestedAt,
      },
      source,
      tag,
    );
  }

  async dreamSource(identity, source, tag) {
    const existing = await this.client.findDream(identity.id);
    if (existing !== undefined) {
      await this.client.markDreamed(source.id);
      return existing;
    }
    const observations = [];
    const originalText =
      typeof source.payload?.text === "string" ? source.payload.text.trim() : "";
    if (originalText !== "") observations.push(`Original entry: ${originalText}`);
    for (const media of source.media ?? []) {
      if (!media.contentType.startsWith("image/")) continue;
      const bytes = await this.client.readMedia(media);
      observations.push(
        `Image ${observations.length + 1}: ${await describeImage(
          this.config,
          bytes,
          media.contentType,
        )}`,
      );
    }
    const summary = await summarizeDream(this.config, observations);
    const emojiSignature = await createDreamEmojiSignature(
      this.config,
      summary,
    );
    const signedSummary = `${emojiSignature}\n\n${summary}`;
    const imagePrompt = await createImagePrompt(this.config, summary);
    const generated = await generateMirroredImage(this.config, imagePrompt);
    try {
      const uploaded = await this.client.uploadMedia(
        {
          sourceKey: createHash("sha256")
            .update(`dreamer\0${source.userId}\0${identity.id}`)
            .digest("hex"),
        },
        {
          ...generated,
          fileName: `dream-${source.id}-${generated.axis}.${generated.contentType === "image/jpeg" ? "jpg" : "png"}`,
        },
      );
      const emoji = firstEmoji(emojiSignature);
      const occurredAt = nextRolloverInFuture(source.occurredAt, this.now());
      const record = await this.client.createDream(
        identity,
        source,
        tag,
        uploaded,
        signedSummary,
        emoji,
        occurredAt,
      );
      await this.client.markDreamed(source.id);
      const embedding = await createEmbedding(this.config, signedSummary);
      await this.client.storeEmbedding(
        record,
        signedSummary,
        this.config.embeddingModel,
        embedding,
      );
      this.log.info(
        `Dreamed record ${record.id} from ${source.id} at ${occurredAt}.`,
      );
      return record;
    } finally {
      await generated.cleanup();
    }
  }
}

export async function createDreamEmojiSignature(config, summary) {
  const response = await languageAgent(config).complete({
    model: config.descriptionModel,
    messages: [
      {
        role: "user",
        content: [
          "Create an emoji signature for this dream diary entry.",
          "Use between 3 and 12 emojis total.",
          "You may arrange them into meaningfully spaced groups of any size.",
          "Use spaces only between groups. Do not use words, punctuation, labels, or explanation.",
          "Reply with one line containing only the emoji signature.",
          "",
          summary,
        ].join("\n"),
      },
    ],
    temperature: 0.4,
  });
  return validateDreamEmojiSignature(response.text);
}

export function validateDreamEmojiSignature(value) {
  const line = value.trim().replaceAll(/\r?\n/g, " ");
  let count = 0;
  for (const { segment } of new Intl.Segmenter(undefined, {
    granularity: "grapheme",
  }).segment(line)) {
    if (/^\s+$/u.test(segment)) continue;
    if (!isEmoji(segment)) {
      throw new Error("Dream emoji signature contains non-emoji characters.");
    }
    count += 1;
  }
  if (count < 3 || count > 12) {
    throw new Error(
      `Dream emoji signature must contain 3 to 12 emojis; received ${count}.`,
    );
  }
  return line;
}

export function nextRolloverInFuture(occurredAt, now = Date.now()) {
  const source = Date.parse(occurredAt);
  if (!Number.isFinite(source)) throw new Error("Source record date is invalid.");
  const periods = Math.max(
    0,
    Math.floor((now - source) / ROLLOVER_MILLISECONDS) + 1,
  );
  return new Date(source + periods * ROLLOVER_MILLISECONDS).toISOString();
}

export async function chooseMostDistantSource(client, dreamerTagId, saros) {
  let selected;
  let cursor;
  do {
    const page = await client.listRecords(cursor);
    for (const record of page.data ?? []) {
      if (
        record.visibility !== "public" ||
        record.tagIds?.includes(dreamerTagId) ||
        record.source?.provider === "dreamer" ||
        !recordHasSarosSpike(record, saros)
      ) {
        continue;
      }
      if (
        selected === undefined ||
        Date.parse(record.occurredAt) < Date.parse(selected.occurredAt) ||
        (record.occurredAt === selected.occurredAt && record.id < selected.id)
      ) {
        selected = record;
      }
    }
    cursor = page.hasMore ? page.nextCursor : undefined;
  } while (cursor !== undefined);
  return selected;
}

function recordHasSarosSpike(record, saros) {
  return (
    Array.isArray(record.payload?.context?.spikes) &&
    record.payload.context.spikes.some((spike) => spike?.saros === saros)
  );
}

function waitingRuntime(schedule) {
  return {
    state: "waiting",
    nextRolloverAt: new Date(schedule.epochSeconds * 1_000).toISOString(),
    saros: schedule.saros,
    scheduleId: schedule.id,
  };
}

async function describeImage(config, bytes, mediaType) {
  const response = await languageAgent(config).complete({
    model: config.descriptionModel,
    messages: [
      {
        role: "user",
        content: [
          { type: "text", text: config.descriptionPrompt },
          { type: "image", mediaType, data: bytes.toString("base64") },
        ],
      },
    ],
    temperature: 0.2,
  });
  return response.text;
}

async function summarizeDream(config, observations) {
  const response = await languageAgent(config).complete({
    model: config.descriptionModel,
    messages: [
      {
        role: "user",
        content: [
          "Turn these observations into a short surreal first-person dream diary entry.",
          "Keep recognizable details from the source, but connect them with dreamlike logic.",
          "Do not mention images, source records, observations, or analysis.",
          "",
          observations.length === 0
            ? "There are no visible details; describe a quiet, indistinct dream."
            : observations.join("\n"),
        ].join("\n"),
      },
    ],
    temperature: 0.5,
  });
  return response.text;
}

function languageAgent(config) {
  return createAgent({
    provider: config.descriptionProvider,
    baseUrl: config.descriptionBaseUrl,
    apiKey: config.descriptionApiKey,
  });
}

function firstEmoji(value) {
  for (const { segment } of new Intl.Segmenter(undefined, {
    granularity: "grapheme",
  }).segment(value)) {
    if (isEmoji(segment)) return segment;
  }
  throw new Error("Dream emoji signature has no emoji.");
}

function isEmoji(value) {
  return /[\p{Extended_Pictographic}\p{Emoji_Presentation}\u20E3]/u.test(
    value,
  );
}

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}
