import type { ApiSchemas } from "@fractonica/api-client";

import {
  createBackendApiClient,
  readBackendData,
} from "~/lib/backend.server";
import type { StoredAuthSession } from "~/lib/session.server";

type Authorization = Readonly<Pick<StoredAuthSession, "accessToken">>;
export type Worker = ApiSchemas["Worker"];
export type WorkerConfigPatch = ApiSchemas["WorkerConfigPatch"];
export type DreamRequest = ApiSchemas["DreamRequest"];

export async function readWorkers(
  auth: Authorization,
  signal?: AbortSignal,
): Promise<readonly Worker[]> {
  const client = createBackendApiClient({ accessToken: auth.accessToken });
  const page = await readBackendData(
    () => client.GET("/workers", { signal }),
    "Could not load registered workers.",
  );
  return page.data;
}

export async function updateWorker(
  auth: Authorization,
  deviceId: string,
  revision: number,
  patch: WorkerConfigPatch,
): Promise<Worker> {
  const client = createBackendApiClient({ accessToken: auth.accessToken });
  return readBackendData(
    () =>
      client.PATCH("/workers/{deviceId}", {
        params: {
          path: { deviceId },
          header: { "If-Match": `"worker-${deviceId}-r${revision}"` },
        },
        body: patch,
      }),
    "Could not update the worker.",
  );
}

export async function readRecordDreamRequest(
  auth: Authorization,
  recordId: string,
  signal?: AbortSignal,
): Promise<DreamRequest | null> {
  const client = createBackendApiClient({ accessToken: auth.accessToken });
  const envelope = await readBackendData(
    () =>
      client.GET("/records/{recordId}/dream", {
        params: { path: { recordId } },
        signal,
      }),
    "Could not load the record's Dreamer job.",
  );
  return envelope.request;
}

export async function scheduleRecordDream(
  auth: Authorization,
  recordId: string,
): Promise<DreamRequest> {
  const client = createBackendApiClient({ accessToken: auth.accessToken });
  return readBackendData(
    () =>
      client.POST("/records/{recordId}/dream", {
        params: { path: { recordId } },
      }),
    "Could not schedule this record for Dreamer.",
  );
}
