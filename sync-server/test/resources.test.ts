import assert from "node:assert/strict";
import test from "node:test";

import type { QueryResultRow } from "pg";

import type { Principal } from "../src/auth/principal.js";
import type {
  Database,
  DatabaseReadiness,
  DatabaseResult,
  Queryable,
} from "../src/db/database.js";
import { HttpProblem } from "../src/http/problem.js";
import {
  publicProjection,
  renderTemplateBody,
  type PublicRecordResource,
} from "../src/resources/records.js";
import {
  assertApiKeyDevice,
  cursorSignature,
  decodeCursor,
  encodeCursor,
  executeIdempotentMutation,
  mergeJsonObject,
  PreconditionFailedProblem,
  requireMatchingEtag,
  resourceEtag,
} from "../src/resources/shared.js";

const userId = "e42b4fde-8baf-4b95-8bc8-5395b68d0dd2";
const actorId = "0ce129e6-cbf7-4731-8829-7592f69fb31e";
const deviceId = "2dca8eab-00a8-4e94-9bd2-2fcbfe17e890";
const otherDeviceId = "8f7bb69e-a087-4338-bcf2-03dbefd03b74";
const recordId = "2ea5377d-6251-459d-9f6e-3f48e07763a1";
const recordPublicId = "Q7_xA";

const apiKeyPrincipal: Principal = {
  kind: "api_key",
  userId,
  actorId,
  deviceId,
  scopes: new Set(["records:read", "records:write"]),
};

test("resource cursors are opaque and bound to user and filters", () => {
  const signature = cursorSignature({ userId, visibility: "public" });
  const cursor = encodeCursor("owner-records", signature, "2026-07-14T12:00:00.000Z", recordId);

  assert.deepEqual(decodeCursor(cursor, "owner-records", signature), {
    sort: "2026-07-14T12:00:00.000Z",
    id: recordId,
  });
  assert.throws(
    () => decodeCursor(cursor, "owner-records", cursorSignature({ userId, visibility: "private" })),
    (error: unknown) => error instanceof HttpProblem && error.code === "invalid_cursor",
  );
  assert.throws(
    () => decodeCursor("not-json", "owner-records", signature),
    (error: unknown) => error instanceof HttpProblem && error.status === 400,
  );
});

test("strong ETags enforce exact revision preconditions", () => {
  const etag = resourceEtag("record", recordId, 4);
  assert.equal(etag, `"record-${recordId}-r4"`);
  assert.doesNotThrow(() => requireMatchingEtag(etag, etag));
  assert.throws(
    () => requireMatchingEtag(`"record-${recordId}-r3"`, etag),
    (error: unknown) =>
      error instanceof PreconditionFailedProblem && error.currentEtag === etag,
  );
});

test("API-key principals cannot write through another device", () => {
  assert.doesNotThrow(() => assertApiKeyDevice(apiKeyPrincipal, deviceId));
  assert.throws(
    () => assertApiKeyDevice(apiKeyPrincipal, otherDeviceId),
    (error: unknown) =>
      error instanceof HttpProblem && error.code === "device_binding_mismatch",
  );
  assert.doesNotThrow(() =>
    assertApiKeyDevice(
      { kind: "jwt", userId, actorId, scopes: new Set(), deviceId },
      otherDeviceId,
    ),
  );
});

test("JSON Mustache rendering supports sections and typed exact variables", () => {
  const rendered = renderTemplateBody(
    {
      text: "{{#alerts}}{{name}} {{/alerts}}",
      count: "{{count}}",
      nested: "{{profile.temperature}}",
      escaped: "{{unsafe}}",
      raw: "{{{unsafe}}}",
    },
    {
      alerts: [{ name: "flare" }, { name: "aurora" }],
      count: 2,
      profile: { temperature: -12.5 },
      unsafe: "<strong>x</strong>",
    },
  );

  assert.deepEqual(rendered, {
    text: "flare aurora ",
    count: 2,
    nested: -12.5,
    escaped: "<strong>x</strong>",
    raw: "<strong>x</strong>",
  });
  assert.throws(
    () => renderTemplateBody({ text: "{{missing}}" }, {}),
    (error: unknown) =>
      error instanceof HttpProblem && error.code === "template_variable_missing",
  );
  assert.throws(
    () => renderTemplateBody({ text: "{{> shared}}" }, {}),
    (error: unknown) =>
      error instanceof HttpProblem && error.code === "template_partial_unsupported",
  );
});

test("anonymous projection strips owner-only record and media fields", () => {
  const ownerRecord: PublicRecordResource = {
    id: recordPublicId,
    originId: recordId,
    userId,
    author: { id: userId, login: "owner", displayName: "Owner" },
    deviceId,
    visibility: "public",
    occurredAt: "2026-07-14T12:00:00.000Z",
    payload: { text: "public" },
    tagIds: [],
    tags: [],
    media: [
      {
        id: otherDeviceId,
        userId,
        deviceId,
        fileName: "photo.jpg",
        contentType: "image/jpeg",
        byteLength: 123,
        sha256: "a".repeat(64),
        revision: 1,
        createdAt: "2026-07-14T12:00:00.000Z",
        contentUrl: `/v1/media/${otherDeviceId}/content`,
        publicContentUrl: `/v1/public/media/${otherDeviceId}/content`,
      },
    ],
    metadata: {},
    references: [],
    revision: 1,
    createdAt: "2026-07-14T12:00:00.000Z",
    updatedAt: "2026-07-14T12:00:00.000Z",
  };

  const projection = publicProjection(ownerRecord);
  assert.equal("deviceId" in projection, false);
  assert.equal("originId" in projection, false);
  assert.equal("userId" in projection.media[0]!, false);
  assert.equal("deviceId" in projection.media[0]!, false);
  assert.equal("contentUrl" in projection.media[0]!, false);
  assert.equal(projection.media[0]?.publicContentUrl, `/v1/public/media/${otherDeviceId}/content`);
});

test("nested resource patches use RFC 7396 merge semantics", () => {
  assert.deepEqual(
    mergeJsonObject(
      { keep: true, nested: { keep: 1, remove: 2 }, array: [1, 2] },
      { nested: { remove: null, add: 3 }, array: [9], newValue: "yes" },
    ),
    { keep: true, nested: { keep: 1, add: 3 }, array: [9], newValue: "yes" },
  );
});

test("bounded cleanup removes unrelated expired rows while live responses replay", async () => {
  const database = new IdempotencyDatabase();
  database.unrelatedExpiredRows = 137;
  database.row = {
    requestHash: Buffer.alloc(32, 9),
    responseStatus: 200,
    responseHeaders: { etag: '"old"' },
    responseBody: { old: true },
    expired: true,
  };
  let writes = 0;

  const first = await executeIdempotentMutation(
    database,
    apiKeyPrincipal,
    "createRecord",
    "expired-key",
    { body: { text: "new" } },
    async () => {
      writes += 1;
      return { status: 201, headers: { etag: '"new"' }, body: { id: recordId } };
    },
  );

  assert.equal(database.unrelatedExpiredRows, 37);
  assert.equal(database.unrelatedLiveResponseRetained, true);

  const replay = await executeIdempotentMutation(
    database,
    apiKeyPrincipal,
    "createRecord",
    "expired-key",
    { body: { text: "new" } },
    async () => {
      writes += 1;
      return { status: 500, headers: {}, body: { unexpected: true } };
    },
  );

  assert.equal(writes, 1);
  assert.equal(first.status, 201);
  assert.equal(replay.status, 201);
  assert.equal(replay.replayed, true);
  assert.deepEqual(replay.body, { id: recordId });
  assert.equal(database.unrelatedExpiredRows, 0);
  assert.equal(database.unrelatedLiveResponseRetained, true);
});

interface StoredRow {
  requestHash: Buffer;
  responseStatus: number | null;
  responseHeaders: Record<string, string> | null;
  responseBody: unknown;
  expired: boolean;
}

class IdempotencyDatabase implements Database {
  row: StoredRow | undefined;
  unrelatedExpiredRows = 0;
  unrelatedLiveResponseRetained = true;

  async checkReadiness(): Promise<DatabaseReadiness> {
    return { ready: true, database: "up", pgvector: "up", latencyMs: 0 };
  }

  async query<Row extends QueryResultRow = QueryResultRow>(
    _text: string,
    _values?: readonly unknown[],
  ): Promise<DatabaseResult<Row>> {
    throw new Error("Queries must be transactional in this test");
  }

  async transaction<Result>(work: (client: Queryable) => Promise<Result>): Promise<Result> {
    return work({ query: (text, values) => this.execute(text, values) });
  }

  async close(): Promise<void> {}

  private async execute<Row extends QueryResultRow = QueryResultRow>(
    text: string,
    values?: readonly unknown[],
  ): Promise<DatabaseResult<Row>> {
    if (text.includes("WITH expired AS")) {
      assert.match(text, /expires_at <= now\(\)/);
      assert.match(text, /<>\s*\(\$1::uuid, \$2::text, \$3::text\)/);
      assert.match(text, /LIMIT \$4/);
      assert.match(text, /FOR UPDATE SKIP LOCKED/);
      assert.deepEqual(values?.slice(0, 3), [userId, "createRecord", "expired-key"]);
      assert.equal(values?.[3], 100);
      const deleted = Math.min(this.unrelatedExpiredRows, 100);
      this.unrelatedExpiredRows -= deleted;
      return result([], deleted);
    }
    if (text.includes("DELETE FROM idempotency_keys")) {
      const deleted = this.row?.expired === true;
      if (deleted) {
        this.row = undefined;
      }
      return result([], deleted ? 1 : 0);
    }
    if (text.includes("INSERT INTO idempotency_keys")) {
      if (this.row !== undefined) {
        return result([], 0);
      }
      this.row = {
        requestHash: values?.[5] as Buffer,
        responseStatus: null,
        responseHeaders: null,
        responseBody: null,
        expired: false,
      };
      return result([], 1);
    }
    if (text.includes("SELECT request_hash")) {
      assert.ok(this.row);
      return result(
        [
          {
            request_hash: this.row.requestHash,
            response_status: this.row.responseStatus,
            response_headers: this.row.responseHeaders,
            response_body: this.row.responseBody,
          },
        ],
        1,
      ) as unknown as DatabaseResult<Row>;
    }
    if (text.includes("UPDATE idempotency_keys")) {
      assert.ok(this.row);
      this.row.responseStatus = values?.[3] as number;
      this.row.responseHeaders = JSON.parse(values?.[4] as string) as Record<string, string>;
      this.row.responseBody = JSON.parse(values?.[5] as string) as unknown;
      return result([], 1);
    }
    throw new Error(`Unexpected query: ${text}`);
  }
}

function result<Row extends QueryResultRow>(
  rows: readonly Row[],
  rowCount = rows.length,
): DatabaseResult<Row> {
  return { rows, rowCount };
}
