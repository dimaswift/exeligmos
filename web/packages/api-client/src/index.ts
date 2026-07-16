import createClient from "openapi-fetch";

import type { components, paths } from "./schema.js";

export type ApiPaths = paths;
export type ApiSchemas = components["schemas"];
export type AuthSession = ApiSchemas["AuthSession"];
export type LoginRequest = ApiSchemas["LoginRequest"];
export type User = ApiSchemas["User"];
export type Problem = ApiSchemas["Problem"];
export type PublicUserSummary = ApiSchemas["PublicUserSummary"];
export type PublicUserProfile = ApiSchemas["PublicUserProfile"];
export type PublicRecordProjection = ApiSchemas["PublicRecordProjection"];
export type PublicRecordProjectionPage = ApiSchemas["PublicRecordProjectionPage"];
export type RecordResource = ApiSchemas["Record"];
export type RecordPage = ApiSchemas["RecordPage"];
export type PublicEventProjection = ApiSchemas["PublicEventProjection"];
export type PublicEventPage = ApiSchemas["PublicEventPage"];
export type EventResource = ApiSchemas["Event"];
export type EventPage = ApiSchemas["EventPage"];
export type PublicActivityResourceType = ApiSchemas["PublicActivityResourceType"];
export type PublicActivityItem = ApiSchemas["PublicActivityItem"];
export type PublicActivityPage = ApiSchemas["PublicActivityPage"];
export type ResourceReference = ApiSchemas["ResourceReference"];

export interface ApiClientOptions {
  readonly baseUrl: string;
  readonly accessToken?: string;
  readonly fetch?: typeof globalThis.fetch;
}

/** Creates a contract-typed client. Authentication is opt-in and server callers own token storage. */
export function createApiClient({ baseUrl, accessToken, fetch }: ApiClientOptions) {
  return createClient<paths>({
    baseUrl: baseUrl.replace(/\/$/, ""),
    fetch,
    headers: accessToken === undefined ? undefined : { Authorization: `Bearer ${accessToken}` },
  });
}
