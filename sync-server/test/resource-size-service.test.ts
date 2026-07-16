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
import { EventService } from "../src/resources/events.js";
import {
  PRIVATE_RECORD_CIPHERTEXT_MAX_BYTES,
  PUBLIC_RECORD_PAYLOAD_MAX_BYTES,
  RESOURCE_METADATA_MAX_BYTES,
} from "../src/resources/limits.js";
import { RecordService } from "../src/resources/records.js";
import { resourceEtag, type JsonObject } from "../src/resources/shared.js";

const userId = "e42b4fde-8baf-4b95-8bc8-5395b68d0dd2";
const actorId = "0ce129e6-cbf7-4731-8829-7592f69fb31e";
const deviceId = "2dca8eab-00a8-4e94-9bd2-2fcbfe17e890";
const recordId = "2ea5377d-6251-459d-9f6e-3f48e07763a1";
const eventId = "20a78723-c33e-4794-a036-5da69a15e8bf";

const principal: Principal = {
  kind: "api_key",
  userId,
  actorId,
  deviceId,
  scopes: new Set(["records:write", "events:write"]),
};

test("record service rejects oversized payload and metadata on create and merged patch", async () => {
  const cases: readonly {
    readonly name: string;
    readonly expectedCode: string;
    readonly createInput: Record<string, unknown>;
    readonly patchInput: Record<string, unknown>;
  }[] = [
    {
      name: "public payload",
      expectedCode: "payload_too_large",
      createInput: { payload: oversizedJsonObject(PUBLIC_RECORD_PAYLOAD_MAX_BYTES) },
      patchInput: { payload: oversizedJsonObject(PUBLIC_RECORD_PAYLOAD_MAX_BYTES) },
    },
    {
      name: "record metadata",
      expectedCode: "metadata_too_large",
      createInput: {
        payload: { text: "bounded" },
        metadata: oversizedJsonObject(RESOURCE_METADATA_MAX_BYTES),
      },
      patchInput: { metadata: oversizedJsonObject(RESOURCE_METADATA_MAX_BYTES) },
    },
    {
      name: "source metadata",
      expectedCode: "source_metadata_too_large",
      createInput: {
        payload: { text: "bounded" },
        source: sourceWithMetadata(oversizedJsonObject(RESOURCE_METADATA_MAX_BYTES)),
      },
      patchInput: {
        source: sourceWithMetadata(oversizedJsonObject(RESOURCE_METADATA_MAX_BYTES)),
      },
    },
  ];

  for (const entry of cases) {
    const createDatabase = new SizeGuardDatabase("public");
    await assert.rejects(
      new RecordService(createDatabase).create(
        principal,
        {
          deviceId,
          occurredAt: "2026-07-15T00:00:00Z",
          ...entry.createInput,
        },
        `create-${entry.expectedCode}`,
        "request-create",
      ),
      problemCode(entry.expectedCode, `${entry.name} create`),
    );
    assert.equal(createDatabase.resourceMutations, 0);

    const patchDatabase = new SizeGuardDatabase("public");
    await assert.rejects(
      new RecordService(patchDatabase).patch(
        principal,
        recordId,
        { visibility: "public", ...entry.patchInput },
        resourceEtag("record", recordId, 1),
        `patch-${entry.expectedCode}`,
        "request-patch",
      ),
      problemCode(entry.expectedCode, `${entry.name} patch`),
    );
    assert.equal(patchDatabase.resourceMutations, 0);
  }
});

test("record service validates decoded private ciphertext size on create and patch", async () => {
  const oversizedCiphertext = Buffer.alloc(PRIVATE_RECORD_CIPHERTEXT_MAX_BYTES + 1, 7)
    .toString("base64");
  const encryption = {
    algorithm: "A256GCM" as const,
    cryptoVersion: 1 as const,
    keyVersion: 1 as const,
    nonce: Buffer.alloc(12, 1).toString("base64"),
    ciphertext: oversizedCiphertext,
    contentType: "application/vnd.exeligmos.record+json" as const,
  };

  const createDatabase = new SizeGuardDatabase("private");
  await assert.rejects(
    new RecordService(createDatabase).create(
      principal,
      { id: recordId, deviceId, visibility: "private", encryption },
      "create-private-oversize",
      "request-create-private",
    ),
    problemCode("ciphertext_too_large", "private create"),
  );
  assert.equal(createDatabase.resourceMutations, 0);

  const patchDatabase = new SizeGuardDatabase("private");
  await assert.rejects(
    new RecordService(patchDatabase).patch(
      principal,
      recordId,
      { visibility: "private", encryption },
      resourceEtag("record", recordId, 1),
      "patch-private-oversize",
      "request-patch-private",
    ),
    problemCode("ciphertext_too_large", "private patch"),
  );
  assert.equal(patchDatabase.resourceMutations, 0);
});

test("event service rejects oversized metadata on create and merged patch", async () => {
  const metadata = oversizedJsonObject(RESOURCE_METADATA_MAX_BYTES);

  const createDatabase = new SizeGuardDatabase("event");
  await assert.rejects(
    new EventService(createDatabase).create(
      principal,
      {
        deviceId,
        startsAt: "2026-07-15T00:00:00Z",
        label: "Oversized metadata",
        type: 1,
        metadata,
      },
      "create-event-oversize",
      "request-create-event",
    ),
    problemCode("metadata_too_large", "event create"),
  );
  assert.equal(createDatabase.resourceMutations, 0);

  const patchDatabase = new SizeGuardDatabase("event");
  await assert.rejects(
    new EventService(patchDatabase).patch(
      principal,
      eventId,
      { metadata },
      resourceEtag("event", eventId, 1),
      "patch-event-oversize",
      "request-patch-event",
    ),
    problemCode("metadata_too_large", "event patch"),
  );
  assert.equal(patchDatabase.resourceMutations, 0);
});

class SizeGuardDatabase implements Database {
  resourceMutations = 0;

  constructor(private readonly currentKind: "public" | "private" | "event") {}

  async checkReadiness(): Promise<DatabaseReadiness> {
    return { ready: true, database: "up", pgvector: "up", latencyMs: 0 };
  }

  async query<Row extends QueryResultRow = QueryResultRow>(
    text: string,
    _values?: readonly unknown[],
  ): Promise<DatabaseResult<Row>> {
    if (text.includes("DELETE FROM idempotency_keys")) {
      return result([]);
    }
    if (text.includes("INSERT INTO idempotency_keys")) {
      return result([{} as Row]);
    }
    if (text.includes("FROM devices")) {
      return result([{} as Row]);
    }
    if (text.includes("FROM user_encryption_profiles")) {
      return result([{} as Row]);
    }
    if (text.includes("FROM records r") && text.includes("FOR UPDATE OF r")) {
      return result([this.recordRow() as Row]);
    }
    if (text.includes("FROM events") && text.includes("FOR UPDATE")) {
      return result([eventRow() as Row]);
    }
    if (/\b(?:INSERT INTO|UPDATE)\s+(?:records|events)\b/.test(text)) {
      this.resourceMutations += 1;
      throw new Error("A size-rejected mutation reached resource SQL");
    }
    throw new Error(`Unexpected size-guard query: ${text}`);
  }

  async transaction<Result>(work: (client: Queryable) => Promise<Result>): Promise<Result> {
    return work(this);
  }

  async close(): Promise<void> {}

  private recordRow(): QueryResultRow {
    const isPrivate = this.currentKind === "private";
    return {
      id: recordId,
      user_id: userId,
      device_id: deviceId,
      visibility: isPrivate ? "private" : "public",
      event_at: isPrivate ? null : "2026-07-15T00:00:00Z",
      end_at: null,
      public_payload: isPrivate ? null : { text: "existing" },
      metadata: {},
      template_id: null,
      template_version: null,
      source_kind: null,
      source_provider: null,
      source_external_id: null,
      source_url: null,
      source_metadata: {},
      cipher_algorithm: isPrivate ? "A256GCM" : null,
      crypto_version: isPrivate ? 1 : null,
      key_version: isPrivate ? 1 : null,
      nonce: isPrivate ? Buffer.alloc(12) : null,
      ciphertext: isPrivate ? Buffer.alloc(16) : null,
      encrypted_content_type: isPrivate
        ? "application/vnd.exeligmos.record+json"
        : null,
      revision: 1,
      created_at: "2026-07-15T00:00:00Z",
      updated_at: "2026-07-15T00:00:00Z",
      deleted_at: null,
      tag_ids: [],
      media: [],
    };
  }
}

function eventRow(): QueryResultRow {
  return {
    id: eventId,
    user_id: userId,
    device_id: deviceId,
    starts_at: "2026-07-15T00:00:00Z",
    ends_at: null,
    label: "Existing event",
    type: 1,
    metadata: {},
    revision: 1,
    created_at: "2026-07-15T00:00:00Z",
    updated_at: "2026-07-15T00:00:00Z",
    deleted_at: null,
  };
}

function oversizedJsonObject(maximumBytes: number): JsonObject {
  const empty = { value: "" };
  const overhead = Buffer.byteLength(JSON.stringify(empty), "utf8");
  const value = { value: "x".repeat(maximumBytes + 1 - overhead) };
  assert.equal(Buffer.byteLength(JSON.stringify(value), "utf8"), maximumBytes + 1);
  return value;
}

function sourceWithMetadata(metadata: JsonObject) {
  return { kind: "agent" as const, provider: "size-test", metadata };
}

function problemCode(code: string, label: string): (error: unknown) => boolean {
  return (error: unknown) => {
    assert.ok(error instanceof HttpProblem, label);
    assert.equal(error.status, 422, label);
    assert.equal(error.code, code, label);
    return true;
  };
}

function result<Row extends QueryResultRow>(rows: readonly Row[]): DatabaseResult<Row> {
  return { rows, rowCount: rows.length };
}
