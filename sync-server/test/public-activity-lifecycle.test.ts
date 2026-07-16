import assert from "node:assert/strict";
import test from "node:test";

import type { QueryResultRow } from "pg";

import type {
  Database,
  DatabaseReadiness,
  DatabaseResult,
  Queryable,
} from "../src/db/database.js";
import { PublicActivityService } from "../src/resources/social.js";

const userId = "e42b4fde-8baf-4b95-8bc8-5395b68d0dd2";

test("record-filtered activity includes identifier-only user lifecycle controls", async () => {
  const database = new ScriptedDatabase([
    { rows: [], rowCount: 0 },
    { rows: [{ high_water: "18" }], rowCount: 1 },
    {
      rows: [{
        sequence: "18",
        published_at: "2026-07-15T12:00:00Z",
        actor_user_id: userId,
        actor_login: "sun",
        actor_display_name: "Sun",
        resource_type: "user",
        resource_id: userId,
        operation: "delete",
        revision: "4",
      }],
      rowCount: 1,
    },
  ]);

  const page = await new PublicActivityService(database).listPublic({
    limit: 10,
    resourceTypes: ["record"],
  });

  assert.deepEqual(database.queries[2]?.values?.[1], ["user", "record"]);
  assert.match(
    database.queries[2]?.text ?? "",
    /activity\.operation = 'delete' OR actor\.status = 'active'/,
  );
  assert.deepEqual(page.data, [{
    sequence: 18,
    publishedAt: "2026-07-15T12:00:00.000Z",
    actor: { id: userId, login: "sun", displayName: "Sun" },
    resourceType: "user",
    resourceId: userId,
    operation: "delete",
    revision: 4,
    resourceUrl: "/v1/public/users/sun",
  }]);
  assert.equal("payload" in (page.data[0] ?? {}), false);
});

class ScriptedDatabase implements Database {
  readonly queries: Array<{ readonly text: string; readonly values?: readonly unknown[] }> = [];

  constructor(private readonly results: DatabaseResult<QueryResultRow>[]) {}

  async checkReadiness(): Promise<DatabaseReadiness> {
    return { ready: true, database: "up", pgvector: "up", latencyMs: 0 };
  }

  async query<Row extends QueryResultRow = QueryResultRow>(
    text: string,
    values?: readonly unknown[],
  ): Promise<DatabaseResult<Row>> {
    this.queries.push({ text, ...(values === undefined ? {} : { values }) });
    const result = this.results.shift();
    if (result === undefined) {
      throw new Error(`Unexpected query: ${text}`);
    }
    return result as DatabaseResult<Row>;
  }

  async transaction<Result>(work: (client: Queryable) => Promise<Result>): Promise<Result> {
    return work(this);
  }

  async close(): Promise<void> {}
}
