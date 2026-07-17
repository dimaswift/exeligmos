import type { ApiSchemas } from "@exeligmos/api-client";

import {
  backendApiBaseUrl,
  backendRequestError,
  BackendRequestError,
  createBackendApiClient,
  readBackendData,
} from "~/lib/backend.server";
import type { StoredAuthSession } from "~/lib/session.server";

import { WEB_ATTACHMENT_MAX_FILE_BYTES } from "./attachment-policy";

type Auth = Readonly<Pick<StoredAuthSession, "accessToken">>;
export type ManagedTag = ApiSchemas["Tag"];
export type ManagedDevice = ApiSchemas["Device"];
export type ManagedRecord = ApiSchemas["Record"];
export type ManagedMedia = ApiSchemas["MediaObject"];
type ManagedMediaUpload = ApiSchemas["MediaUpload"];

export class ManagedMutationOutcomeUnknownError extends BackendRequestError {}

export class ManagedRecordOutcomeUnknownError extends ManagedMutationOutcomeUnknownError {
  public constructor(cause: unknown) {
    super(
      "The server may have created the record, but its response could not be confirmed. Retry the unchanged form to reconcile it.",
      502,
      { cause },
    );
    this.name = "ManagedRecordOutcomeUnknownError";
  }
}

class ManagedMediaOutcomeUnknownError extends ManagedMutationOutcomeUnknownError {
  public constructor(fileName: string, cause: unknown) {
    super(`The upload outcome for ${fileName} could not be confirmed.`, 502, { cause });
    this.name = "ManagedMediaOutcomeUnknownError";
  }
}

export async function listManagedTags(auth: Auth, signal?: AbortSignal) {
  const client = clientFor(auth);
  return readBackendData(
    () => client.GET("/v1/tags", { params: { query: { limit: 100 } }, signal }),
    "Could not load tags.",
  );
}

export async function listManagedDevices(auth: Auth, signal?: AbortSignal) {
  const client = clientFor(auth);
  return readBackendData(
    () => client.GET("/v1/devices", { params: { query: { limit: 100 } }, signal }),
    "Could not load devices.",
  );
}

export async function resolveManagedDevice(auth: Auth, requestedId?: string): Promise<string> {
  if (requestedId !== undefined && requestedId !== "") return requestedId;
  const active = (await listManagedDevices(auth)).data.find((device) => device.revokedAt == null);
  if (active !== undefined) return active.id;
  const client = clientFor(auth);
  const created = await readBackendData(
    () =>
      client.POST("/v1/devices", {
        params: { header: { "Idempotency-Key": crypto.randomUUID() } },
        body: { name: "Exeligmos web", kind: "web", platform: "browser", metadata: {} },
      }),
    "Could not register a web device.",
  );
  return created.id;
}

export async function createManagedTag(auth: Auth, body: ApiSchemas["CreateTagRequest"]) {
  const client = clientFor(auth);
  return readBackendData(
    () =>
      client.POST("/v1/tags", {
        params: { header: { "Idempotency-Key": crypto.randomUUID() } },
        body,
      }),
    "Could not create the tag.",
  );
}

export async function updateManagedTag(
  auth: Auth,
  tagId: string,
  revision: number,
  body: ApiSchemas["UpdateTagRequest"],
) {
  const client = clientFor(auth);
  return readBackendData(
    () =>
      client.PATCH("/v1/tags/{tagId}", {
        params: {
          path: { tagId },
          header: {
            "Idempotency-Key": crypto.randomUUID(),
            "If-Match": `"tag-${tagId}-r${revision}"`,
          },
        },
        body,
      }),
    "Could not update the tag.",
  );
}

export async function deleteManagedTag(auth: Auth, tagId: string, revision: number) {
  const client = clientFor(auth);
  const result = await client.DELETE("/v1/tags/{tagId}", {
    params: {
      path: { tagId },
      header: {
        "Idempotency-Key": crypto.randomUUID(),
        "If-Match": `"tag-${tagId}-r${revision}"`,
      },
    },
  });
  if (!result.response.ok) {
    throw backendRequestError(result.error, result.response, "Could not delete the tag.");
  }
}

export async function createManagedRecord(
  auth: Auth,
  body: ApiSchemas["PublicRecordInput"],
  operationId: string,
) {
  validateOperationId(operationId);
  const client = clientFor(auth);
  const create = () =>
    readBackendData(
      () =>
        client.POST("/v1/records", {
          params: { header: { "Idempotency-Key": `web:${operationId}:record:create` } },
          body,
        }),
      "Could not create the record.",
    );
  try {
    return await create();
  } catch (error) {
    if (!isTransportFailure(error)) throw error;
    try {
      // The same key replays a response if the first request committed but its
      // response was lost between the API and this web process.
      return await create();
    } catch (retryError) {
      if (!isTransportFailure(retryError)) throw retryError;
      throw new ManagedRecordOutcomeUnknownError(retryError);
    }
  }
}

export async function uploadManagedMedia(
  auth: Auth,
  deviceId: string,
  file: File,
  options: { readonly operationId: string; readonly position: number },
): Promise<ManagedMedia> {
  validateOperationId(options.operationId);
  if (!Number.isSafeInteger(options.position) || options.position < 0) {
    throw new RangeError("Attachment position must be a non-negative safe integer.");
  }
  validateManagedFile(file);
  const bytes = new Uint8Array(await file.arrayBuffer());
  const sha256 = Buffer.from(await crypto.subtle.digest("SHA-256", bytes)).toString("hex");
  const client = clientFor(auth);
  const declaration = {
    deviceId,
    fileName: file.name,
    contentType: normalizedContentType(file.type),
    byteLength: bytes.byteLength,
    sha256,
  };
  const declarationFingerprint = await sha256Hex(JSON.stringify(declaration));
  const reserveKey = `web:${options.operationId}:media:${options.position}:reserve:${declarationFingerprint}`;
  const reserve = () =>
    readBackendData(
      () =>
        client.POST("/v1/media-upload-sessions", {
          params: { header: { "Idempotency-Key": reserveKey } },
          body: declaration,
        }),
      `Could not reserve an upload for ${file.name}.`,
    );
  let upload: ManagedMediaUpload;
  try {
    upload = await reserve();
  } catch (error) {
    if (!isTransportFailure(error)) throw error;
    try {
      upload = await reserve();
    } catch (retryError) {
      if (!isTransportFailure(retryError)) throw retryError;
      throw new ManagedMediaOutcomeUnknownError(file.name, retryError);
    }
  }
  const completeKey = `web:${options.operationId}:media:${options.position}:complete:${upload.id}`;

  try {
    if (upload.status === "completed") {
      return await completedMediaOrUnknown(client, upload, upload, file.name, upload);
    }
    if (upload.status === "aborted" || upload.status === "expired") {
      throw inactiveUploadError(file.name, upload.status);
    }
    if (upload.status === "reserved") {
      await receiveManagedUpload(auth, client, upload, file.name, bytes, sha256);
    }
    return await completeManagedUpload(client, upload, file.name, completeKey);
  } catch (error) {
    if (error instanceof ManagedMediaOutcomeUnknownError) throw error;
    await client
      .DELETE("/v1/media-upload-sessions/{uploadId}", {
        params: { path: { uploadId: upload.id } },
      })
      .catch(() => undefined);
    if (error instanceof BackendRequestError) throw error;
    throw new BackendRequestError(`Could not upload ${file.name}.`, 502, { cause: error });
  }
}

export async function cleanupManagedMedia(auth: Auth, media: readonly ManagedMedia[]) {
  const client = clientFor(auth);
  await Promise.allSettled(
    media.map((item) =>
      client.DELETE("/v1/media/{mediaId}", {
        params: {
          path: { mediaId: item.id },
          header: {
            "Idempotency-Key": crypto.randomUUID(),
            "If-Match": `"media-${item.id}-r${item.revision}"`,
          },
        },
      }),
    ),
  );
}

export async function updateManagedRecord(
  auth: Auth,
  recordId: string,
  revision: number,
  fields: {
    readonly text?: string;
    readonly emoji?: string;
    readonly tagIds: string[];
    readonly deviceId: string;
    readonly occurredAt: string;
    readonly endedAt?: string;
    readonly context: Readonly<Record<string, unknown>>;
  },
) {
  const client = clientFor(auth);
  const current = await readBackendData(
    () => client.GET("/v1/records/{recordId}", { params: { path: { recordId } } }),
    "Could not load the record before editing.",
  );
  if (current.visibility !== "public") {
    throw new Response("Encrypted records must be edited by a client holding their key.", {
      status: 409,
    });
  }
  // PATCH payloads use RFC 7396. Null explicitly removes an optional field;
  // undefined would disappear during JSON serialization and retain the old value.
  const payloadPatch = {
    text: fields.text ?? null,
    emoji: fields.emoji ?? null,
    context: fields.context,
  } as unknown as ApiSchemas["PublicRecordPayload"];
  return readBackendData(
    () =>
      client.PATCH("/v1/records/{recordId}", {
        params: {
          path: { recordId },
          header: {
            "Idempotency-Key": crypto.randomUUID(),
            "If-Match": `"record-${recordId}-r${revision}"`,
          },
        },
        body: {
          visibility: "public",
          deviceId: fields.deviceId,
          occurredAt: fields.occurredAt,
          endedAt: fields.endedAt ?? null,
          payload: payloadPatch,
          tagIds: fields.tagIds,
        },
      }),
    "Could not update the record.",
  );
}

export async function deleteManagedRecord(auth: Auth, recordId: string, revision: number) {
  const client = clientFor(auth);
  const result = await client.DELETE("/v1/records/{recordId}", {
    params: {
      path: { recordId },
      header: {
        "Idempotency-Key": crypto.randomUUID(),
        "If-Match": `"record-${recordId}-r${revision}"`,
      },
    },
  });
  if (!result.response.ok) {
    throw backendRequestError(result.error, result.response, "Could not delete the record.");
  }
}

async function receiveManagedUpload(
  auth: Auth,
  client: ReturnType<typeof clientFor>,
  upload: ManagedMediaUpload,
  fileName: string,
  bytes: Uint8Array<ArrayBuffer>,
  sha256: string,
): Promise<void> {
  const put = () => putManagedBytes(auth, upload.uploadUrl, fileName, bytes, sha256);
  try {
    await put();
    return;
  } catch (error) {
    if (!isTransportFailure(error)) throw error;
    const status = await uploadStatusOrUnknown(client, upload.id, fileName, error);
    if (status.status === "received" || status.status === "completed") return;
    if (status.status !== "reserved") throw inactiveUploadError(fileName, status.status);
  }

  try {
    await put();
  } catch (error) {
    if (!isTransportFailure(error)) throw error;
    const status = await uploadStatusOrUnknown(client, upload.id, fileName, error);
    if (status.status === "received" || status.status === "completed") return;
    if (status.status === "reserved") {
      throw new BackendRequestError(`The server did not receive ${fileName}.`, 502, {
        cause: error,
      });
    }
    throw inactiveUploadError(fileName, status.status);
  }
}

async function completeManagedUpload(
  client: ReturnType<typeof clientFor>,
  upload: ManagedMediaUpload,
  fileName: string,
  idempotencyKey: string,
): Promise<ManagedMedia> {
  const complete = () =>
    readBackendData(
      () =>
        client.POST("/v1/media-upload-sessions/{uploadId}/complete", {
          params: {
            path: { uploadId: upload.id },
            header: { "Idempotency-Key": idempotencyKey },
          },
        }),
      `Could not complete ${fileName}.`,
    );
  try {
    return await complete();
  } catch (error) {
    if (!isTransportFailure(error)) throw error;
    const status = await uploadStatusOrUnknown(client, upload.id, fileName, error);
    if (status.status === "completed") {
      return completedMediaOrUnknown(client, status, upload, fileName, error);
    }
    if (status.status !== "received") throw inactiveUploadError(fileName, status.status);
  }

  try {
    return await complete();
  } catch (error) {
    if (!isTransportFailure(error)) throw error;
    const status = await uploadStatusOrUnknown(client, upload.id, fileName, error);
    if (status.status === "completed") {
      return completedMediaOrUnknown(client, status, upload, fileName, error);
    }
    if (status.status === "received") {
      throw new ManagedMediaOutcomeUnknownError(fileName, error);
    }
    throw inactiveUploadError(fileName, status.status);
  }
}

async function completedMediaOrUnknown(
  client: ReturnType<typeof clientFor>,
  status: ManagedMediaUpload,
  upload: ManagedMediaUpload,
  fileName: string,
  cause: unknown,
): Promise<ManagedMedia> {
  const mediaId = status.mediaId ?? upload.mediaId;
  if (mediaId === undefined) throw new ManagedMediaOutcomeUnknownError(fileName, cause);
  try {
    return await readBackendData(
      () => client.GET("/v1/media/{mediaId}", { params: { path: { mediaId } } }),
      `Could not reconcile completed media ${fileName}.`,
    );
  } catch (error) {
    throw new ManagedMediaOutcomeUnknownError(fileName, error);
  }
}

async function uploadStatusOrUnknown(
  client: ReturnType<typeof clientFor>,
  uploadId: string,
  fileName: string,
  cause: unknown,
): Promise<ManagedMediaUpload> {
  try {
    return await readBackendData(
      () =>
        client.GET("/v1/media-upload-sessions/{uploadId}", {
          params: { path: { uploadId } },
        }),
      `Could not reconcile upload ${fileName}.`,
    );
  } catch (error) {
    throw new ManagedMediaOutcomeUnknownError(fileName, error ?? cause);
  }
}

async function putManagedBytes(
  auth: Auth,
  uploadUrl: string,
  fileName: string,
  bytes: Uint8Array<ArrayBuffer>,
  sha256: string,
): Promise<void> {
  const apiBase = new URL(`${backendApiBaseUrl()}/`);
  let target: URL;
  try {
    target = new URL(uploadUrl, apiBase);
  } catch (cause) {
    throw new BackendRequestError(
      `The server returned an invalid upload URL for ${fileName}.`,
      502,
      {
        cause,
      },
    );
  }
  if (
    !["http:", "https:"].includes(target.protocol) ||
    target.username !== "" ||
    target.password !== "" ||
    (apiBase.protocol === "https:" && target.protocol !== "https:")
  ) {
    throw new BackendRequestError(`The server returned an unsafe upload URL for ${fileName}.`, 502);
  }
  const headers = new Headers({
    "Content-Type": "application/octet-stream",
    "Content-Length": String(bytes.byteLength),
    "X-Content-SHA256": sha256,
  });
  // Bearer credentials only follow same-origin upload URLs. A future external
  // presigned upload target receives its signature through its URL instead.
  if (target.origin === apiBase.origin) headers.set("Authorization", `Bearer ${auth.accessToken}`);
  const response = await fetch(target, {
    method: "PUT",
    headers,
    body: bytes,
    redirect: "error",
  });
  if (!response.ok) {
    throw backendRequestError(
      await response.json().catch(() => undefined),
      response,
      `Could not upload ${fileName}.`,
    );
  }
}

function inactiveUploadError(fileName: string, status: ManagedMediaUpload["status"]) {
  return new BackendRequestError(`The upload for ${fileName} is ${status}.`, 409);
}

function clientFor(auth: Auth) {
  return createBackendApiClient({ accessToken: auth.accessToken });
}

function validateOperationId(value: string): void {
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value)) {
    throw new RangeError("operationId must be a UUID.");
  }
}

function isTransportFailure(error: unknown): boolean {
  return !(error instanceof BackendRequestError) || error.cause !== undefined;
}

async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return Buffer.from(digest).toString("hex");
}

function validateManagedFile(file: File): void {
  const name = file.name.trim();
  if (
    name === "" ||
    name !== file.name ||
    [...name].length > 255 ||
    name.includes("/") ||
    name.includes("\\")
  ) {
    throw new RangeError(
      "Attachment names must contain 1–255 trimmed characters and no path separators.",
    );
  }
  if (file.size < 1 || file.size > WEB_ATTACHMENT_MAX_FILE_BYTES) {
    throw new RangeError(
      `${file.name} must be between 1 byte and ${WEB_ATTACHMENT_MAX_FILE_BYTES / 1_024 / 1_024} MiB.`,
    );
  }
}

function normalizedContentType(value: string): string {
  const normalized = value.split(";", 1)[0]?.trim() || "application/octet-stream";
  return /^[A-Za-z0-9][A-Za-z0-9.+_-]{0,126}\/[A-Za-z0-9][A-Za-z0-9.+_-]{0,126}$/.test(normalized)
    ? normalized
    : "application/octet-stream";
}
