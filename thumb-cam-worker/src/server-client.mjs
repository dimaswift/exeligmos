import { createHash } from "node:crypto";
import { createReadStream } from "node:fs";
import { stat } from "node:fs/promises";

import { recordTemporalContextAt } from "./temporal-context.mjs";

export class ServerProblem extends Error {
  constructor(message, status, problem) {
    super(message);
    this.name = "ServerProblem";
    this.status = status;
    this.problem = problem;
  }
}

export class FractonicaClient {
  constructor(config) {
    this.baseUrl = config.serverUrl;
    this.apiKey = config.apiKey;
    this.deviceId = config.deviceId;
    this.idempotencyPrefix = config.idempotencyPrefix ?? "thumb-cam";
  }

  async getCurrentWorker() {
    return this.json("GET", "/workers/current");
  }

  async listJobs(cursor) {
    const query = new URLSearchParams({
      deviceId: this.deviceId,
      limit: "200",
    });
    if (cursor !== undefined) query.set("cursor", cursor);
    return this.json("GET", `/jobs?${query}`);
  }

  async getJob(jobId) {
    return this.json("GET", `/jobs/${encodeURIComponent(jobId)}`);
  }

  async createJob(config, groups) {
    const items = groups.flat().map((item) => ({
      sourceKey: item.sourceKey,
      groupKey: item.groupKey,
      relativePath: item.relativePath,
      kind: item.kind,
      capturedAt: item.capturedAt,
      byteLength: item.byteLength,
      contentSha256: item.contentSha256,
    }));
    const body = {
      deviceId: this.deviceId,
      source: { volume: config.mountName },
      config: {
        descriptionProvider: config.descriptionProvider,
        descriptionModel: config.descriptionModel,
        descriptionPrompt: config.descriptionPrompt,
        embeddingProvider: config.embeddingProvider,
        embeddingModel: config.embeddingModel,
        whisperModel: config.whisperModel,
        sarosWindowSeconds: config.sarosGroupSeconds,
        mirrorMode: "paired-rotated",
      },
      items,
    };
    const fingerprint = sha256Text(JSON.stringify(body));
    return this.json("POST", "/jobs", {
      idempotencyKey: `thumb-cam:${fingerprint}:job`,
      body,
    });
  }

  async updateJobItem(jobId, itemId, revision, patch) {
    const fingerprint = sha256Text(JSON.stringify(patch)).slice(0, 24);
    return this.json(
      "PATCH",
      `/jobs/${encodeURIComponent(jobId)}/items/${encodeURIComponent(itemId)}`,
      {
        idempotencyKey: `thumb-cam:${itemId}:r${revision}:${fingerprint}`,
        ifMatch: `"job-${jobId}-r${revision}"`,
        body: patch,
      },
    );
  }

  async getMedia(mediaId) {
    return this.json("GET", `/media/${encodeURIComponent(mediaId)}`, {
      allowNotFound: true,
    });
  }

  async getMediaUpload(uploadId) {
    return this.json(
      "GET",
      `/media-upload-sessions/${encodeURIComponent(uploadId)}`,
      { allowNotFound: true },
    );
  }

  async uploadMedia(item, upload, onReserved) {
    const file = await stat(upload.absolutePath);
    const sha256 = await sha256File(upload.absolutePath);
    const requestedMediaId = uuidFromHex(
      sha256Text(`${item.sourceKey}\0${upload.fileName}`),
    );
    const existing = await this.getMedia(requestedMediaId);
    if (existing !== undefined) return existing;

    let reservation =
      item.uploadId === undefined
        ? undefined
        : await this.getMediaUpload(item.uploadId);
    if (reservation?.mediaId !== requestedMediaId) reservation = undefined;
    let reservationSeed = item.uploadId ?? "initial";
    for (
      let attempt = 0;
      !usableUploadReservation(reservation, requestedMediaId) && attempt < 3;
      attempt += 1
    ) {
      const submitted = await this.json("POST", "/media-upload-sessions", {
        idempotencyKey: `${this.idempotencyPrefix}:${item.sourceKey}:media:${requestedMediaId}:reserve:${reservationSeed}`,
        body: {
          mediaId: requestedMediaId,
          deviceId: this.deviceId,
          fileName: upload.fileName,
          contentType: upload.contentType,
          byteLength: file.size,
          sha256,
        },
      });
      // Idempotency replays the original response body. Reloading distinguishes
      // a still-usable reservation from one that expired since it was created.
      reservation = (await this.getMediaUpload(submitted.id)) ?? submitted;
      reservationSeed = reservation.id;
    }
    if (!usableUploadReservation(reservation, requestedMediaId)) {
      throw new ServerProblem(
        "Could not obtain a live media upload reservation.",
        409,
        { uploadId: reservation?.id },
      );
    }
    await onReserved?.(reservation);

    if (reservation.status === "reserved") {
      await this.binary(
        "PUT",
        reservation.uploadUrl,
        createReadStream(upload.absolutePath),
        {
          "content-length": String(file.size),
          "content-type": "application/octet-stream",
          "x-content-sha256": sha256,
        },
      );
    }
    if (
      reservation.status === "completed" &&
      reservation.mediaId !== undefined
    ) {
      const completed = await this.getMedia(reservation.mediaId);
      if (completed !== undefined) return completed;
    }
    return this.json(
      "POST",
      `/media-upload-sessions/${encodeURIComponent(reservation.id)}/complete`,
      {
        idempotencyKey: `${this.idempotencyPrefix}:${item.sourceKey}:media:${reservation.id}:complete`,
      },
    );
  }

  async createRecord(group, media, text, emoji, config) {
    const groupKey = group[0].groupKey;
    const existing = await this.findRecord(groupKey);
    if (existing !== undefined) return existing;
    const occurredAt = group[0].capturedAt;
    const endedAt = group.at(-1).capturedAt;
    const originId = uuidFromHex(groupKey);
    const context = recordTemporalContextAt(occurredAt);
    return this.json("POST", "/records", {
      idempotencyKey: `thumb-cam:${groupKey}:record`,
      body: {
        originId,
        deviceId: this.deviceId,
        visibility: "public",
        occurredAt,
        ...(endedAt === occurredAt ? {} : { endedAt }),
        payload: {
          createdAt: occurredAt,
          updatedAt: endedAt,
          eventDate: occurredAt,
          ...(endedAt === occurredAt ? {} : { endDate: endedAt }),
          unixTimestamp: Math.trunc(Date.parse(occurredAt) / 1_000),
          text,
          emoji,
          // The iOS sync projection replaces this with downloaded server
          // media. Keeping the required snapshot field empty avoids
          // duplicating an arbitrarily large attachment list in JSON.
          mediaItems: [],
          context,
          sourceDeviceID: this.deviceId,
          sourceDeviceEmoji: "📷",
          sourceDeviceName: "THUMB",
        },
        mediaIds: media.map((entry) => entry.id),
        metadata: {
          ingest: {
            source: config.mountName,
            descriptionProvider: config.descriptionProvider,
            descriptionModel: config.descriptionModel,
            embeddingProvider: config.embeddingProvider,
            embeddingModel: config.embeddingModel,
            mirror: "paired-rotated",
            groupKey,
            mediaCount: media.length,
          },
        },
        source: {
          kind: "agent",
          provider: "thumb-cam",
          externalId: groupKey,
          metadata: {},
        },
      },
    });
  }

  async findRecord(groupKey) {
    const page = await this.json(
      "GET",
      `/records?limit=1&sourceProvider=thumb-cam&sourceExternalId=${encodeURIComponent(groupKey)}`,
    );
    return Array.isArray(page.data) ? page.data[0] : undefined;
  }

  async storeEmbedding(record, text, model, embedding) {
    const contentHash = sha256Text(text);
    const fingerprint = sha256Text(
      `${record.revision}\0${model}\0${contentHash}`,
    );
    return this.json(
      "PUT",
      `/records/${encodeURIComponent(record.id)}/embeddings`,
      {
        idempotencyKey: `thumb-cam:${record.originId}:embedding:r${record.revision}:${fingerprint}`,
        body: {
          recordRevision: record.revision,
          model,
          contentHash,
          vector: embedding,
        },
      },
    );
  }

  async json(method, pathname, options = {}) {
    const headers = {
      accept: "application/json",
      authorization: `Bearer ${this.apiKey}`,
    };
    if (options.body !== undefined)
      headers["content-type"] = "application/json";
    if (options.idempotencyKey !== undefined) {
      headers["idempotency-key"] = options.idempotencyKey;
    }
    if (options.ifMatch !== undefined) headers["if-match"] = options.ifMatch;
    let response;
    try {
      response = await fetch(`${this.baseUrl}${pathname}`, {
        method,
        headers,
        ...(options.body === undefined
          ? {}
          : { body: JSON.stringify(options.body) }),
        signal: AbortSignal.timeout(120_000),
      });
    } catch (cause) {
      throw new ServerProblem(
        `Could not reach Fractonica at ${this.baseUrl}.`,
        502,
        {
          cause,
        },
      );
    }
    if (options.allowNotFound === true && response.status === 404)
      return undefined;
    if (!response.ok) {
      const problem = await response.json().catch(async () => ({
        detail: (await response.text()).slice(0, 2_000),
      }));
      const fieldErrors = Array.isArray(problem?.errors)
        ? problem.errors
        : Array.isArray(problem?.extensions?.errors)
          ? problem.extensions.errors
          : [];
      const fieldDetail = fieldErrors
        .map((entry) => {
          if (typeof entry === "string") return entry;
          if (entry === null || typeof entry !== "object") return undefined;
          const path =
            entry.path ?? entry.instancePath ?? entry.field ?? entry.pointer;
          const message = entry.message ?? entry.detail;
          return [path, message].filter(Boolean).join(" ");
        })
        .filter(Boolean)
        .join("; ");
      const message =
        problem.detail ??
        problem.title ??
        `Fractonica returned HTTP ${response.status}.`;
      throw new ServerProblem(
        fieldDetail.length > 0 ? `${message} ${fieldDetail}` : message,
        response.status,
        problem,
      );
    }
    if (response.status === 204) return undefined;
    return response.json();
  }

  async binary(method, pathname, body, extraHeaders) {
    let response;
    try {
      response = await fetch(`${this.baseUrl}${pathname}`, {
        method,
        headers: {
          authorization: `Bearer ${this.apiKey}`,
          ...extraHeaders,
        },
        body,
        duplex: "half",
        signal: AbortSignal.timeout(30 * 60_000),
      });
    } catch (cause) {
      throw new ServerProblem("The media byte upload was interrupted.", 502, {
        cause,
      });
    }
    if (!response.ok) {
      throw new ServerProblem(
        `Media upload failed with HTTP ${response.status}: ${(await response.text()).slice(0, 2_000)}`,
        response.status,
      );
    }
  }
}

export function uuidFromHex(hex) {
  const normalized = hex
    .replace(/[^a-f0-9]/gi, "")
    .toLowerCase()
    .padEnd(32, "0")
    .slice(0, 32);
  const characters = normalized.split("");
  characters[12] = "4";
  characters[16] = ["8", "9", "a", "b"][
    Number.parseInt(characters[16], 16) % 4
  ];
  const value = characters.join("");
  return `${value.slice(0, 8)}-${value.slice(8, 12)}-${value.slice(12, 16)}-${value.slice(16, 20)}-${value.slice(20)}`;
}

export function sha256Text(value) {
  return createHash("sha256").update(value, "utf8").digest("hex");
}

function usableUploadReservation(reservation, requestedMediaId) {
  return (
    reservation !== undefined &&
    reservation.mediaId === requestedMediaId &&
    ["reserved", "received", "completed"].includes(reservation.status)
  );
}

async function sha256File(absolutePath) {
  const hash = createHash("sha256");
  for await (const chunk of createReadStream(absolutePath)) hash.update(chunk);
  return hash.digest("hex");
}
