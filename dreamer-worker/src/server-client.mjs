import { createHash } from "node:crypto";

import {
  FractonicaClient,
  uuidFromHex,
} from "../../thumb-cam-worker/src/server-client.mjs";
import { recordTemporalContextAt } from "../../thumb-cam-worker/src/temporal-context.mjs";

export class DreamerClient extends FractonicaClient {
  async listRecords(cursor) {
    const query = new URLSearchParams({ limit: "25" });
    if (cursor !== undefined) query.set("cursor", cursor);
    return this.json("GET", `/records?${query}`);
  }

  async listTags(cursor) {
    const query = new URLSearchParams({ limit: "25" });
    if (cursor !== undefined) query.set("cursor", cursor);
    return this.json("GET", `/tags?${query}`);
  }

  async ensureDreamerTag() {
    let cursor;
    do {
      const page = await this.listTags(cursor);
      const existing = page.data?.find(
        (tag) => tag.name.toLocaleLowerCase() === "dreamer",
      );
      if (existing !== undefined) return existing;
      cursor = page.hasMore ? page.nextCursor : undefined;
    } while (cursor !== undefined);
    return this.json("POST", "/tags", {
      idempotencyKey: "dreamer:tag:v1",
      body: {
        name: "Dreamer",
        emoji: "💭",
        color: "#9B8CFF",
        metadata: { worker: "dreamer" },
      },
    });
  }

  async readMedia(media) {
    const response = await fetch(`${this.baseUrl}${media.contentUrl}`, {
      headers: {
        authorization: `Bearer ${this.apiKey}`,
      },
      signal: AbortSignal.timeout(120_000),
    });
    if (!response.ok) {
      throw new Error(
        `Could not read ${media.fileName}: HTTP ${response.status}.`,
      );
    }
    return Buffer.from(await response.arrayBuffer());
  }

  async getRecord(recordId) {
    return this.json("GET", `/records/${encodeURIComponent(recordId)}`);
  }

  async claimDreamRequest() {
    const response = await this.json(
      "POST",
      "/workers/current/dream-requests/claim",
    );
    return response.request ?? null;
  }

  async completeDreamRequest(jobId, dreamRecordId) {
    await this.json(
      "POST",
      `/workers/current/dream-requests/${encodeURIComponent(jobId)}/complete`,
      { body: { dreamRecordId } },
    );
  }

  async failDreamRequest(jobId, error) {
    await this.json(
      "POST",
      `/workers/current/dream-requests/${encodeURIComponent(jobId)}/fail`,
      { body: { error } },
    );
  }

  async findDream(scheduleId) {
    const page = await this.json(
      "GET",
      `/records?limit=1&sourceProvider=dreamer&sourceExternalId=${encodeURIComponent(scheduleId)}`,
    );
    return page.data?.[0];
  }

  async createDream(identity, source, tag, media, text, emoji, occurredAt) {
    const existing = await this.findDream(identity.id);
    if (existing !== undefined) return existing;
    const fingerprint = createHash("sha256")
      .update(`dreamer\0${source.userId}\0${identity.id}`)
      .digest("hex");
    return this.json("POST", "/records", {
      idempotencyKey: `dreamer:${identity.id}:record`,
      body: {
        originId: uuidFromHex(fingerprint),
        deviceId: this.deviceId,
        visibility: "public",
        occurredAt,
        payload: {
          createdAt: occurredAt,
          updatedAt: occurredAt,
          eventDate: occurredAt,
          unixTimestamp: Math.trunc(Date.parse(occurredAt) / 1_000),
          text,
          emoji,
          mediaItems: [],
          context: recordTemporalContextAt(occurredAt),
          sourceDeviceID: this.deviceId,
          sourceDeviceEmoji: "💭",
          sourceDeviceName: "Dreamer",
        },
        tagIds: [tag.id],
        mediaIds: [media.id],
        references: [
          {
            relation: "dream-of",
            targetType: "record",
            targetUserId: source.userId,
            targetId: source.id,
          },
        ],
        metadata: {
          dreamer: {
            sourceRecordId: source.id,
            rolloverSeconds: 1_111_260,
            requestKind: identity.kind,
            identity: identity.id,
            ...(identity.kind === "scheduled"
              ? {
                  scheduledSaros: identity.saros,
                  scheduledRolloverAt: new Date(
                    identity.epochSeconds * 1_000,
                  ).toISOString(),
                  scheduleId: identity.id,
                }
              : {
                  jobId: identity.jobId,
                  requestedAt: identity.requestedAt,
                }),
          },
        },
        source: {
          kind: "agent",
          provider: "dreamer",
          externalId: identity.id,
          metadata: {},
        },
      },
    });
  }

  async markDreamed(recordId) {
    await this.json(
      "POST",
      `/workers/current/dreamed/${encodeURIComponent(recordId)}`,
    );
  }

  async reportRuntime(runtime) {
    await this.json("PUT", "/workers/current/dreamer-runtime", {
      body: runtime,
    });
  }
}
