import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import path from "node:path";
import test from "node:test";

import { Client } from "pg";

import type { Principal } from "../../src/auth/principal.js";
import { createPostgresDatabase } from "../../src/db/database.js";
import { runMigrations } from "../../src/db/migrate.js";
import { HttpProblem } from "../../src/http/problem.js";
import {
  createTagInTransaction,
  deleteTagInTransaction,
  TagService,
  tagEtag,
} from "../../src/resources/tags.js";
import {
  createTemplateInTransaction,
  createTemplateVersionInTransaction,
  retireTemplateInTransaction,
  TemplateService,
  templateEtag,
} from "../../src/resources/templates.js";
import { testConfig } from "../helpers.js";

const databaseUrl = process.env.TEST_DATABASE_URL?.trim();

test(
  "tag and versioned-template services preserve tenant, revision, and tombstone semantics",
  { skip: databaseUrl === undefined || databaseUrl.length === 0 },
  async () => {
    assert.ok(databaseUrl);
    await runMigrations({
      databaseUrl,
      directory: path.resolve(process.cwd(), "db/migrations"),
    });
    const baseConfig = testConfig();
    const database = createPostgresDatabase({ ...baseConfig.database, url: databaseUrl });
    const sql = new Client({ connectionString: databaseUrl });
    await sql.connect();

    const userId = randomUUID();
    const otherUserId = randomUUID();
    const principal: Principal = {
      kind: "jwt",
      userId,
      actorId: randomUUID(),
      scopes: new Set(),
    };
    try {
      await sql.query(
        `INSERT INTO users (id, login, display_name, password_hash)
         VALUES ($1, $2, 'Catalog Owner', 'test'), ($3, $4, 'Other Owner', 'test')`,
        [
          userId,
          `catalog-${randomUUID()}`,
          otherUserId,
          `catalog-other-${randomUUID()}`,
        ],
      );

      const alpha = await database.transaction((queryable) =>
        createTagInTransaction(queryable, principal, {
          id: randomUUID(),
          name: "Alpha",
          sortOrder: 10,
          metadata: { nested: { keep: 1, remove: 2 } },
        }, "catalog-integration"),
      );
      const beta = await database.transaction((queryable) =>
        createTagInTransaction(queryable, principal, {
          id: randomUUID(),
          name: "Beta",
          sortOrder: 10,
        }, "catalog-integration"),
      );
      const tagService = new TagService(database);
      const firstPage = await tagService.list(principal, { limit: 1 });
      assert.deepEqual(firstPage.data.map((tag) => tag.id), [alpha.id]);
      assert.equal(firstPage.hasMore, true);
      assert.ok(firstPage.nextCursor);
      const secondPage = await tagService.list(principal, {
        limit: 1,
        cursor: firstPage.nextCursor,
      });
      assert.deepEqual(secondPage.data.map((tag) => tag.id), [beta.id]);
      await assert.rejects(
        tagService.get(otherUserId, alpha.id),
        isProblem("tag_not_found"),
      );

      const patched = await tagService.patch(
        principal,
        alpha.id,
        { color: "#6E56CF", metadata: { nested: { remove: null, add: 3 } } },
        tagEtag(alpha.id, alpha.revision),
        `tag-patch-${randomUUID()}`,
        "catalog-integration",
      );
      assert.equal(patched.body.revision, 2);
      assert.deepEqual(patched.body.metadata, { nested: { keep: 1, add: 3 } });

      const deviceId = randomUUID();
      const recordId = randomUUID();
      await sql.query(
        `INSERT INTO devices (id, user_id, name) VALUES ($1, $2, 'Catalog Device')`,
        [deviceId, userId],
      );
      await sql.query(
        `INSERT INTO records (id, user_id, device_id, visibility, event_at, public_payload)
         VALUES ($1, $2, $3, 'public', now(), '{"text":"tagged"}'::jsonb)`,
        [recordId, userId, deviceId],
      );
      await sql.query(
        `INSERT INTO record_tags (user_id, record_id, tag_id)
         VALUES ($1, $2, $3)`,
        [userId, recordId, alpha.id],
      );
      await assert.rejects(
        database.transaction((queryable) =>
          deleteTagInTransaction(
            queryable,
            principal,
            alpha.id,
            tagEtag(alpha.id, patched.body.revision),
            "catalog-integration",
          )),
        isProblem("tag_in_use"),
      );

      const template = await database.transaction((queryable) =>
        createTemplateInTransaction(queryable, principal, {
          id: randomUUID(),
          name: "Solar flare",
          engine: "mustache",
          body: { text: "Flare {{class}}", context: { keep: 1 } },
          variableSchema: {
            type: "object",
            required: ["class"],
            properties: { class: { type: "string" } },
            additionalProperties: false,
          },
          metadata: { nested: { keep: true, remove: true } },
        }, "catalog-integration"),
      );
      const version2 = await database.transaction((queryable) =>
        createTemplateVersionInTransaction(
          queryable,
          principal,
          template.id,
          {
            body: { text: "Solar flare {{class}}", context: { version: 2 } },
            metadata: { nested: { remove: null, added: true } },
          },
          templateEtag(template.id, template.revision),
          "catalog-integration",
        ));
      assert.equal(version2.version, 2);
      assert.equal(version2.revision, 2);
      assert.deepEqual(version2.metadata, { nested: { keep: true, added: true } });

      const templateService = new TemplateService(database);
      const historical = await templateService.get(userId, template.id, 1);
      assert.equal(historical.version, 1);
      assert.deepEqual(historical.body, { text: "Flare {{class}}", context: { keep: 1 } });
      assert.equal(historical.revision, 2);
      await database.transaction((queryable) =>
        retireTemplateInTransaction(
          queryable,
          principal,
          template.id,
          templateEtag(template.id, version2.revision),
          "catalog-integration",
        ));
      await assert.rejects(
        templateService.get(userId, template.id),
        isProblem("template_not_found"),
      );
      const retiredHistorical = await templateService.get(userId, template.id, 1);
      assert.ok(retiredHistorical.retiredAt);
      assert.equal(retiredHistorical.revision, 3);

      const changes = await sql.query<{ entity_type: string; operation: string; revision: string }>(
        `SELECT entity_type, operation, revision::text
         FROM change_log
         WHERE user_id = $1 AND entity_type IN ('tag', 'template')
         ORDER BY sequence`,
        [userId],
      );
      assert.ok(changes.rows.some((row) =>
        row.entity_type === "template" && row.operation === "delete" && row.revision === "3"
      ));
    } finally {
      try {
        await sql.query("DELETE FROM change_log WHERE user_id = ANY($1::uuid[])", [[userId, otherUserId]]);
        await sql.query("DELETE FROM users WHERE id = ANY($1::uuid[])", [[userId, otherUserId]]);
      } finally {
        await sql.end();
        await database.close();
      }
    }
  },
);

function isProblem(code: string): (error: unknown) => boolean {
  return (error: unknown) => error instanceof HttpProblem && error.code === code;
}
