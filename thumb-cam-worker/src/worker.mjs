import path from "node:path";
import { rm, writeFile } from "node:fs/promises";

import { CacheGenerationStore } from "./cache-generation.mjs";
import {
  cleanupVisualArtifacts,
  fileNameForUpload,
  mediaTypeForUpload,
  symmetryOutputMode,
  transcribeAudio,
  transformVisual,
} from "./media.mjs";
import {
  combineObservations,
  createImagePrompt,
  createEmbedding,
  describeVisual,
  chooseRecordEmoji,
  normalizeTranscript,
} from "./agent-tasks.mjs";
import { generateMirroredImage } from "./image-generation.mjs";
import {
  deduplicateMedia,
  groupMedia,
  isMounted,
  SAROS_GROUP_SECONDS,
  settledScanState,
} from "./scanner.mjs";
import { FractonicaClient } from "./server-client.mjs";
import { SnapshotStore } from "./snapshots.mjs";
import { createWorkerLogger } from "./worker-logger.mjs";

class JobRevisionConflict extends Error {
  constructor(jobId, options) {
    super(`Job ${jobId} was advanced by another worker.`, options);
    this.name = "JobRevisionConflict";
  }
}

export class ThumbCamWorker {
  constructor(config, options = {}) {
    this.config = Object.freeze({
      ...config,
      sarosGroupSeconds: SAROS_GROUP_SECONDS,
    });
    this.client = options.client ?? new FractonicaClient(this.config);
    this.log = options.log ?? createWorkerLogger(this.client);
    this.sleep = options.sleep ?? delay;
    this.descriptionCache = options.descriptionCache ?? new Map();
    this.scanVolume = options.scanVolume ?? settledScanState;
    this.now = options.now ?? Date.now;
    this.groupObservedAt = options.groupObservedAt ?? new Map();
    this.completedSourceKeys = options.completedSourceKeys ?? new Set();
    this.sweptCompletedJobIds = options.sweptCompletedJobIds ?? new Set();
    this.cacheGeneration = options.cacheGeneration;
    this.cacheGenerationStore =
      options.cacheGenerationStore ??
      new CacheGenerationStore(this.config.workRoot ?? ".thumb-cam-worker");
    this.snapshotStore =
      options.snapshotStore ??
      new SnapshotStore(this.config, {
        concurrency: this.config.snapshotConcurrency,
        copy: options.snapshotCopy,
      });
    this.heartbeatIntervalMs =
      options.heartbeatIntervalMs ?? this.config.heartbeatIntervalMs ?? 30_000;
    this.stopped = false;
  }

  stop(signal = "stop requested") {
    this.stopped = true;
    void this.log.info?.(`THUMB worker stopping: ${signal}.`, {
      event: "worker_stopping",
      signal,
    });
  }

  async run() {
    await ensureDirectory(this.config.workRoot);
    await this.log.info?.("THUMB worker started.", {
      event: "worker_started",
      mountName: this.config.mountName,
    });
    if (this.config.once) {
      if (!(await isMounted(this.config.mountPath))) {
        throw new Error(
          `${this.config.mountName} is not mounted at ${this.config.mountPath}.`,
        );
      }
      while (!this.stopped) {
        const pendingUntil = await this.processMountedVolume();
        if (pendingUntil === undefined) break;
        await this.sleep(
          Math.max(
            1,
            Math.min(this.config.pollIntervalMs, pendingUntil - this.now()),
          ),
        );
      }
      return;
    }

    this.log.info(
      `Watching ${this.config.mountPath} for ${this.config.mountName}.`,
    );
    let wasMounted = false;
    while (!this.stopped) {
      await this.refreshWorkerConfig();
      if (this.config.enabled === false) {
        if (wasMounted) {
          this.log.info("THUMB worker disabled in server settings.");
        }
        wasMounted = false;
        await this.sleep(this.config.pollIntervalMs);
        continue;
      }
      const mounted = await isMounted(this.config.mountPath);
      if (mounted && !wasMounted) {
        this.log.info(`${this.config.mountName} mounted; scanning media.`);
      }
      if (mounted) {
        try {
          await this.processMountedVolume();
        } catch (error) {
          this.log.error(
            error instanceof Error ? error.message : String(error),
          );
        }
      } else if (wasMounted) {
        this.log.info(`${this.config.mountName} was unmounted.`);
        try {
          await this.resumeJobs(new Map());
        } catch (error) {
          this.log.error(
            error instanceof Error ? error.message : String(error),
          );
        }
      } else {
        try {
          await this.resumeJobs(new Map());
        } catch (error) {
          this.log.error(
            error instanceof Error ? error.message : String(error),
          );
        }
      }
      wasMounted = mounted;
      await this.sleep(this.config.pollIntervalMs);
    }
  }

  async refreshWorkerConfig() {
    if (typeof this.client.getCurrentWorker !== "function") return;
    try {
      const worker = await this.client.getCurrentWorker();
      if (this.cacheGeneration === undefined) {
        this.cacheGeneration = await this.cacheGenerationStore.read();
      }
      const remoteCacheGeneration = Number(worker.cacheGeneration ?? 0);
      if (
        Number.isSafeInteger(remoteCacheGeneration) &&
        remoteCacheGeneration > this.cacheGeneration
      ) {
        await this.resetLocalCache(remoteCacheGeneration);
      }
      const remote = worker.config ?? {};
      this.config = Object.freeze({
        ...this.config,
        ...remote,
        mountPath: path.resolve(
          this.config.mountRoot,
          remote.mountName ?? this.config.mountName,
        ),
      });
    } catch (error) {
      this.log.warn?.(
        `Could not refresh worker settings; keeping the last known configuration: ${
          error instanceof Error ? error.message : String(error)
        }`,
      );
    }
  }

  async resetLocalCache(cacheGeneration) {
    this.descriptionCache.clear();
    this.groupObservedAt.clear();
    this.completedSourceKeys.clear();
    this.sweptCompletedJobIds.clear();
    await this.snapshotStore.reset();
    await this.cacheGenerationStore.write(cacheGeneration);
    this.cacheGeneration = cacheGeneration;
    await this.log.info?.("THUMB worker local cache cleared.", {
      event: "worker_cache_cleared",
      cacheGeneration,
    });
  }

  async processMountedVolume() {
    const scan = await this.scanVolume(
      this.config,
      this.sleep,
      this.descriptionCache,
    );
    const scanned = deduplicateMedia(scan.items);
    const sourceBySourceKey = new Map(
      scanned.map((item) => [item.sourceKey, item]),
    );
    await this.resumeJobs(sourceBySourceKey);

    if (scan.unstable.length > 0) {
      this.log.info(
        `Waiting for ${scan.unstable.length} supported media file(s) to settle before closing a Saros capture window on ${this.config.mountName}.`,
      );
      return (
        this.now() +
        Math.max(
          this.config.pollIntervalMs ?? 5_000,
          this.config.settleDelayMs ?? 1_500,
        )
      );
    }

    const groups = groupMedia(scanned, this.config.sarosGroupSeconds);
    if (groups.length === 0) {
      this.groupObservedAt.clear();
      this.log.info(
        `${this.config.mountName} contains no settled supported media.`,
      );
      return;
    }
    const maturity = partitionMatureGroups(
      groups,
      this.groupObservedAt,
      this.now(),
      this.config.sarosGroupSeconds,
    );
    if (maturity.ready.length === 0) {
      this.log.info(
        `Waiting for the current Saros capture window to close on ${this.config.mountName}.`,
      );
      return maturity.pendingUntil;
    }
    let queuedAny = false;
    const unprocessed = maturity.ready.filter(
      (group) =>
        !group.every((item) => this.completedSourceKeys.has(item.sourceKey)),
    );
    for (const batch of batchMediaGroups(unprocessed)) {
      // A server job is not allowed to exist until every source member has a
      // durable, content-verified local snapshot.
      const snapshottedBatch = await this.snapshotStore.snapshotGroups(batch);
      const snapshotBySourceKey = new Map(
        snapshottedBatch.flat().map((item) => [item.sourceKey, item]),
      );
      const submitted = await this.client.createJob(
        this.config,
        snapshottedBatch,
      );
      // An idempotent replay returns the original POST response. Reload the job
      // so restarts act on its current revision and item states.
      const job = await this.client.getJob(submitted.id);
      if (
        (job.totalItems ?? job.items?.length ?? 0) === 0 ||
        job.status === "completed" ||
        job.items?.every((item) => item.status === "completed")
      ) {
        await this.cleanupCompletedGroup(snapshottedBatch.flat());
        continue;
      }
      queuedAny = true;
      this.log.info(
        `Queued ${job.totalItems ?? job.items.length} media item(s) in job ${job.id}.`,
      );
      await this.processJob(job, snapshotBySourceKey);
    }
    if (!queuedAny) {
      this.log.info(`No new media on ${this.config.mountName}.`);
    }
    return maturity.pendingUntil;
  }

  async resumeJobs(sourceBySourceKey) {
    let cursor;
    do {
      const page = await this.client.listJobs(cursor);
      for (const summary of page.data ?? []) {
        if (
          summary.status === "completed" &&
          this.sweptCompletedJobIds.has(summary.id)
        ) {
          continue;
        }
        const job = await this.client.getJob(summary.id);
        if (
          job.status === "completed" ||
          job.items?.every((item) => item.status === "completed")
        ) {
          await this.cleanupCompletedGroup(job.items ?? []);
          this.sweptCompletedJobIds.add(job.id);
          continue;
        }
        const snapshotBySourceKey = await this.resolveJobSnapshots(
          job,
          sourceBySourceKey,
        );
        if (snapshotBySourceKey.size === 0) continue;
        this.log.info(`Resuming ${job.status} job ${job.id}.`);
        await this.processJob(job, snapshotBySourceKey);
      }
      cursor = page.hasMore ? page.nextCursor : undefined;
    } while (cursor !== undefined);
  }

  async resolveJobSnapshots(job, sourceBySourceKey) {
    const groups = new Map();
    for (const remote of job.items ?? []) {
      const group = groups.get(remote.groupKey) ?? [];
      group.push(remote);
      groups.set(remote.groupKey, group);
    }
    const snapshots = new Map();
    for (const group of groups.values()) {
      if (group.every((item) => item.status === "completed")) {
        await this.cleanupCompletedGroup(group);
        continue;
      }
      const candidates = group.map((remote) => {
        const source = sourceBySourceKey.get(remote.sourceKey);
        return {
          ...source,
          ...remote,
          absolutePath: source?.absolutePath,
        };
      });
      try {
        const [snapshotted] = await this.snapshotStore.snapshotGroups([
          candidates,
        ]);
        for (const item of snapshotted) {
          snapshots.set(item.sourceKey, item);
        }
      } catch (error) {
        this.log.warn?.(
          `Job ${job.id} is waiting for a verified snapshot of group ${group[0].groupKey}: ${
            error instanceof Error ? error.message : String(error)
          }`,
        );
      }
    }
    return snapshots;
  }

  async processJob(job, snapshotBySourceKey) {
    const remoteGroups = new Map();
    for (const remote of job.items ?? []) {
      const group = remoteGroups.get(remote.groupKey) ?? [];
      group.push(remote);
      remoteGroups.set(remote.groupKey, group);
    }
    const groups = [];
    for (const remotes of remoteGroups.values()) {
      if (remotes.every((item) => item.status === "completed")) {
        await this.cleanupCompletedGroup(remotes);
        continue;
      }
      const group = [];
      for (const remote of remotes) {
        const snapshot = snapshotBySourceKey.get(remote.sourceKey);
        if (snapshot === undefined) {
          group.length = 0;
          break;
        }
        group.push({
          ...snapshot,
          ...remote,
          absolutePath: snapshot.absolutePath,
        });
      }
      if (group.length === remotes.length) groups.push(group);
    }

    for (const group of groups) {
      if (group.every((item) => item.status === "completed")) continue;
      group.sort(
        (left, right) =>
          Date.parse(left.capturedAt) - Date.parse(right.capturedAt) ||
          left.sourceKey.localeCompare(right.sourceKey),
      );
      try {
        await this.processGroup(job, group);
        if (group.every((item) => item.status === "completed")) {
          await this.cleanupCompletedGroup(group);
        }
      } catch (error) {
        if (error instanceof JobRevisionConflict) {
          this.log.warn?.(
            `Job ${job.id} changed remotely; yielding it until the next poll.`,
          );
          return;
        }
        const message = error instanceof Error ? error.message : String(error);
        this.log.error(`Group ${group[0].groupKey} failed: ${message}`);
        for (const item of group) {
          if (item.status === "completed") continue;
          try {
            await this.updateItem(job, item, {
              status: "failed",
              stage: item.stage ?? "queued",
              error: message.slice(0, 4_000),
            });
          } catch (updateError) {
            if (updateError instanceof JobRevisionConflict) {
              this.log.warn?.(
                `Job ${job.id} changed remotely while recording a failure; yielding it until the next poll.`,
              );
              return;
            }
            this.log.error(
              `Could not persist failure for ${item.relativePath}: ${
                updateError instanceof Error
                  ? updateError.message
                  : String(updateError)
              }`,
            );
          }
        }
      }
    }
  }

  async cleanupCompletedGroup(items) {
    await this.snapshotStore.cleanup(items);
    for (const item of items) {
      this.completedSourceKeys.add(item.sourceKey);
    }
  }

  async processGroup(job, group) {
    for (const item of group) this.snapshotStore.assertProcessingPath(item);
    const existingRecord = await this.client.findRecord(group[0].groupKey);
    if (existingRecord !== undefined) {
      await this.finishExistingRecord(job, group, existingRecord);
      return;
    }

    const observations = [];
    const media = [];
    for (const item of group) {
      let outputMode = item.outputMode;
      if (
        (item.kind === "photo" || item.kind === "video") &&
        outputMode == null
      ) {
        outputMode = symmetryOutputMode();
      }
      item.outputMode = outputMode;
      await this.updateItem(job, item, {
        status: "processing",
        stage: item.kind === "audio" ? "transcribing" : "mirroring",
        ...(outputMode === undefined ? {} : { outputMode }),
      });

      let transformed;
      let transcriptPath;
      try {
        let observation;
        if (item.kind === "audio") {
          const transcript = await this.withHeartbeat(
            job,
            item,
            "transcribing",
            () => transcribeAudio(this.config, item.absolutePath),
          );
          transcriptPath = `${item.absolutePath}.transcript.md`;
          await writeFile(
            transcriptPath,
            rawTranscriptMarkdown(item, transcript),
            "utf8",
          );
          observation = await this.withHeartbeat(job, item, "normalizing", () =>
            normalizeTranscript(this.config, transcript),
          );
        } else {
          transformed = await this.withHeartbeat(job, item, "mirroring", () =>
            transformVisual(this.config, item, outputMode),
          );
          if (item.kind === "photo") {
            await this.updateItem(job, item, {
              status: "processing",
              stage: "describing",
              outputMode,
            });
            observation = await this.withHeartbeat(
              job,
              item,
              "describing",
              () =>
                describeVisual(this.config, transformed.descriptionImagePath),
            );
          }
        }
        if (observation !== undefined) {
          observations.push({
            kind: item.kind,
            capturedAt: item.capturedAt,
            text: observation,
          });
        }

        const uploads = transformed?.outputs ?? [
          {
            absolutePath: item.absolutePath,
            contentType: mediaTypeForUpload(item),
            fileName: fileNameForUpload(item),
          },
        ];
        await this.updateItem(job, item, {
          status: "processing",
          stage: "uploading",
          ...(outputMode === undefined ? {} : { outputMode }),
        });
        const completedOutputs = [];
        for (const upload of uploads) {
          const completed = await this.withHeartbeat(
            job,
            item,
            "uploading",
            () =>
              this.client.uploadMedia(
                item,
                upload,
                completedOutputs.length === 0
                  ? async (reservation) => {
                      item.uploadId = reservation.id;
                      await this.updateItem(job, item, {
                        status: "processing",
                        stage: "uploading",
                        ...(outputMode === undefined ? {} : { outputMode }),
                        uploadId: reservation.id,
                      });
                    }
                  : undefined,
              ),
          );
          completedOutputs.push(completed);
          media.push(completed);
        }
        if (transcriptPath !== undefined) {
          const transcriptMedia = await this.withHeartbeat(
            job,
            item,
            "uploading",
            () =>
              this.client.uploadMedia(
                { sourceKey: `${item.sourceKey}:raw-transcript` },
                {
                  absolutePath: transcriptPath,
                  contentType: "text/markdown",
                  fileName: `${path.parse(item.relativePath).name}.transcript.md`,
                },
              ),
          );
          media.push(transcriptMedia);
        }
        item.mediaId = completedOutputs[0].id;
        await this.updateItem(job, item, {
          status: "processing",
          stage: "creating_record",
          ...(outputMode === undefined ? {} : { outputMode }),
          ...(item.uploadId === undefined ? {} : { uploadId: item.uploadId }),
          mediaId: item.mediaId,
        });
      } finally {
        try {
          await cleanupVisualArtifacts(transformed);
          if (transcriptPath !== undefined) {
            await rm(transcriptPath, { force: true });
          }
        } catch (error) {
          this.log.warn?.(
            `Could not clean temporary media for ${item.relativePath}: ${
              error instanceof Error ? error.message : String(error)
            }`,
          );
        }
      }
    }

    const anchorItem =
      group.find((item) => item.status !== "completed") ?? group[0];
    const text = await this.withHeartbeat(
      job,
      anchorItem,
      "creating_record",
      () => combineObservations(this.config, observations),
    );
    const emoji = await this.withHeartbeat(
      job,
      anchorItem,
      "creating_record",
      () => chooseRecordEmoji(this.config, text),
    );
    let generated;
    if (this.config.imageGenerationEnabled !== false) {
      try {
        const prompt = await this.withHeartbeat(
          job,
          anchorItem,
          "creating_record",
          () => createImagePrompt(this.config, text),
        );
        generated = await this.withHeartbeat(
          job,
          anchorItem,
          "creating_record",
          () => generateMirroredImage(this.config, prompt),
        );
        const uploaded = await this.withHeartbeat(
          job,
          anchorItem,
          "uploading",
          () =>
            this.client.uploadMedia(
              {
                sourceKey: `${group[0].groupKey}:generated:${generated.axis}`,
              },
              generated,
            ),
        );
        media.push(uploaded);
      } catch (error) {
        this.log.warn?.(
          `Image generation is unavailable; creating the record without it: ${
            error instanceof Error ? error.message : String(error)
          }`,
        );
      } finally {
        await generated?.cleanup?.();
      }
    }
    const record = await this.withHeartbeat(
      job,
      anchorItem,
      "creating_record",
      () => this.client.createRecord(group, media, text, emoji, this.config),
    );
    for (const item of group) {
      await this.updateItem(job, item, {
        status: "processing",
        stage: "embedding",
        ...(item.outputMode === undefined
          ? {}
          : { outputMode: item.outputMode }),
        ...(item.uploadId === undefined ? {} : { uploadId: item.uploadId }),
        mediaId: item.mediaId,
        recordId: record.id,
      });
    }

    const persistedText =
      typeof record.payload?.text === "string" &&
      record.payload.text.trim() !== ""
        ? record.payload.text
        : text;
    const embedding = await this.withHeartbeat(
      job,
      anchorItem,
      "embedding",
      () => createEmbedding(this.config, persistedText),
    );
    await this.withHeartbeat(job, anchorItem, "embedding", () =>
      this.client.storeEmbedding(
        record,
        persistedText,
        this.config.embeddingModel,
        embedding,
      ),
    );
    for (const item of group) {
      await this.updateItem(job, item, {
        status: "completed",
        stage: "completed",
        ...(item.outputMode === undefined
          ? {}
          : { outputMode: item.outputMode }),
        ...(item.uploadId === undefined ? {} : { uploadId: item.uploadId }),
        mediaId: item.mediaId,
        recordId: record.id,
      });
    }
    this.log.info(
      `Created record ${record.id} from ${group.length} media item(s) at ${group[0].capturedAt}.`,
    );
  }

  async finishExistingRecord(job, group, record) {
    const text = record.payload?.text;
    if (typeof text !== "string" || text.trim() === "") {
      throw new Error(`Existing record ${record.id} has no text to embed.`);
    }
    for (const item of group) {
      if (item.status === "completed") continue;
      if (item.mediaId === undefined) {
        throw new Error(
          `Job item ${item.relativePath} has no persisted media ID for existing record ${record.id}.`,
        );
      }
      await this.updateItem(job, item, {
        status: "processing",
        stage: "embedding",
        ...(item.outputMode === undefined
          ? {}
          : { outputMode: item.outputMode }),
        ...(item.uploadId === undefined ? {} : { uploadId: item.uploadId }),
        mediaId: item.mediaId,
        recordId: record.id,
      });
    }
    const anchorItem =
      group.find((item) => item.status !== "completed") ?? group[0];
    const embedding = await this.withHeartbeat(
      job,
      anchorItem,
      "embedding",
      () => createEmbedding(this.config, text),
    );
    await this.withHeartbeat(job, anchorItem, "embedding", () =>
      this.client.storeEmbedding(
        record,
        text,
        this.config.embeddingModel,
        embedding,
      ),
    );
    for (const item of group) {
      if (item.status === "completed") continue;
      await this.updateItem(job, item, {
        status: "completed",
        stage: "completed",
        ...(item.outputMode === undefined
          ? {}
          : { outputMode: item.outputMode }),
        ...(item.uploadId === undefined ? {} : { uploadId: item.uploadId }),
        mediaId: item.mediaId,
        recordId: record.id,
      });
    }
    this.log.info(
      `Reconciled existing record ${record.id} with job ${job.id}.`,
    );
  }

  async updateItem(job, item, patch) {
    const previous = job.updateQueue ?? Promise.resolve();
    const pending = previous
      .catch(() => undefined)
      .then(async () => {
        let updated;
        try {
          updated = await this.client.updateJobItem(
            job.id,
            item.id,
            job.revision,
            patch,
          );
        } catch (error) {
          if (error?.status !== 412) throw error;
          await this.refreshJob(job, item);
          throw new JobRevisionConflict(job.id, { cause: error });
        }
        const localItems = job.items;
        Object.assign(job, updated, { items: localItems });
        const remote =
          updated.item ??
          updated.items?.find((candidate) => candidate.id === item.id);
        if (remote !== undefined) {
          Object.assign(item, remote, { absolutePath: item.absolutePath });
          const local = localItems?.find(
            (candidate) => candidate.id === item.id,
          );
          if (local !== undefined) Object.assign(local, remote);
        }
        return updated;
      });
    job.updateQueue = pending.then(
      () => undefined,
      () => undefined,
    );
    return pending;
  }

  async refreshJob(job, activeItem) {
    const refreshed = await this.client.getJob(job.id);
    const localItems = job.items ?? [];
    const localById = new Map(localItems.map((item) => [item.id, item]));
    const mergedItems = (refreshed.items ?? []).map((remote) => {
      const local = localById.get(remote.id);
      if (local === undefined) return remote;
      const absolutePath = local.absolutePath;
      Object.assign(local, remote);
      if (absolutePath !== undefined) local.absolutePath = absolutePath;
      return local;
    });
    Object.assign(job, refreshed, { items: mergedItems });
    const remoteActive = mergedItems.find(
      (candidate) => candidate.id === activeItem.id,
    );
    if (remoteActive !== undefined && remoteActive !== activeItem) {
      const absolutePath = activeItem.absolutePath;
      Object.assign(activeItem, remoteActive);
      if (absolutePath !== undefined) activeItem.absolutePath = absolutePath;
    }
  }

  async withHeartbeat(job, item, stage, work) {
    let stopped = false;
    let timer;
    let wake;
    let heartbeatFailure;
    const wait = () =>
      new Promise((resolve) => {
        wake = resolve;
        timer = setTimeout(resolve, this.heartbeatIntervalMs);
      });
    const heartbeat = (async () => {
      while (!stopped) {
        await wait();
        if (stopped) break;
        await this.updateItem(job, item, {
          status: "processing",
          stage,
        });
      }
    })().catch((error) => {
      heartbeatFailure = error;
    });
    const finish = async () => {
      stopped = true;
      clearTimeout(timer);
      wake?.();
      await heartbeat;
    };
    try {
      const result = await work();
      await finish();
      if (heartbeatFailure !== undefined) throw heartbeatFailure;
      return result;
    } catch (error) {
      await finish();
      if (heartbeatFailure instanceof JobRevisionConflict) {
        throw heartbeatFailure;
      }
      throw error;
    }
  }
}

export function rawTranscriptMarkdown(item, transcript) {
  return [
    "# Raw transcription",
    "",
    `- Source: ${path.basename(item.relativePath)}`,
    `- Captured: ${item.capturedAt}`,
    "",
    transcript.trim(),
    "",
  ].join("\n");
}

export function batchMediaGroups(groups, maximumItems = 1_000) {
  const batches = [];
  let batch = [];
  let itemCount = 0;
  for (const group of groups) {
    if (group.length > maximumItems) {
      throw new Error(
        `One Saros group contains ${group.length} media items; the server accepts at most ${maximumItems} per job.`,
      );
    }
    if (itemCount > 0 && itemCount + group.length > maximumItems) {
      batches.push(batch);
      batch = [];
      itemCount = 0;
    }
    batch.push(group);
    itemCount += group.length;
  }
  if (batch.length > 0) {
    batches.push(batch);
  }
  return batches;
}

export function partitionMatureGroups(
  groups,
  observedAtByGroup,
  nowMs = Date.now(),
  spanSeconds = SAROS_GROUP_SECONDS,
) {
  const spanMs = spanSeconds * 1_000;
  const currentKeys = new Set();
  const ready = [];
  let pendingUntil;
  for (const group of groups) {
    const first = group[0];
    if (first === undefined) continue;
    currentKeys.add(first.groupKey);
    const observedAt = observedAtByGroup.get(first.groupKey) ?? nowMs;
    observedAtByGroup.set(first.groupKey, observedAt);
    const deadline = Math.max(
      Date.parse(first.capturedAt) + spanMs,
      observedAt + spanMs,
    );
    if (deadline <= nowMs) {
      ready.push(group);
    } else {
      pendingUntil =
        pendingUntil === undefined
          ? deadline
          : Math.min(pendingUntil, deadline);
    }
  }
  for (const key of observedAtByGroup.keys()) {
    if (!currentKeys.has(key)) observedAtByGroup.delete(key);
  }
  return { ready, pendingUntil };
}

async function ensureDirectory(directory) {
  const { mkdir } = await import("node:fs/promises");
  await mkdir(directory, { recursive: true });
}

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}
