import type { ApiSchemas } from "@fractonica/api-client";

import {
  createBackendApiClient,
  readBackendData,
  type BackendConnectionOptions,
} from "~/lib/backend.server";
import type { StoredAuthSession } from "~/lib/session.server";

type JobsAuthorization = Readonly<Pick<StoredAuthSession, "accessToken">>;

export type JobCurrentItem = ApiSchemas["IngestionJobItem"];
export type Job = ApiSchemas["IngestionJob"];
export type JobPage = ApiSchemas["IngestionJobPage"];

export async function readJobs(
  auth: JobsAuthorization,
  options: BackendConnectionOptions & { readonly signal?: AbortSignal } = {},
): Promise<JobPage> {
  const client = createBackendApiClient({
    accessToken: auth.accessToken,
    baseUrl: options.baseUrl,
    fetch: options.fetch,
  });
  const [recent, processing] = await Promise.all([
    readBackendData(
      () =>
        client.GET("/jobs", {
          params: { query: { limit: 200 } },
          signal: options.signal,
        }),
      "Could not load ingestion jobs.",
    ),
    readBackendData(
      () =>
        client.GET("/jobs", {
          params: { query: { limit: 1, activity: "active" } },
          signal: options.signal,
        }),
      "Could not load active ingestion jobs.",
    ),
  ]);
  const activeJob = processing.data[0];
  if (activeJob === undefined || recent.data.some((job) => job.id === activeJob.id)) {
    return recent;
  }
  return {
    ...recent,
    data: [activeJob, ...recent.data],
  };
}
