import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import path from "node:path";
import test from "node:test";

import Fastify from "fastify";
import { Client } from "pg";

import type { Principal } from "../../src/auth/principal.js";
import { createPostgresDatabase } from "../../src/db/database.js";
import { runMigrations } from "../../src/db/migrate.js";
import { registerProblemHandlers } from "../../src/http/problem.js";
import { NOOP_RESOURCE_REQUEST_LIMITER } from "../../src/resources/rate-limit.js";
import { registerTagRoutes } from "../../src/routes/tags.js";
import { registerTemplateRoutes } from "../../src/routes/templates.js";
import { testConfig } from "../helpers.js";

const databaseUrl = process.env.TEST_DATABASE_URL?.trim();

test(
  "tag and template HTTP endpoints replay writes and expose immutable template versions",
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
    const principal: Principal = {
      kind: "jwt",
      userId,
      actorId: randomUUID(),
      scopes: new Set(),
    };
    const app = Fastify({ logger: false });
    registerProblemHandlers(app);
    await app.register(registerTagRoutes, {
      database,
      authenticator: { async authenticate() { return principal; } },
      requestLimiter: NOOP_RESOURCE_REQUEST_LIMITER,
    });
    await app.register(registerTemplateRoutes, {
      database,
      authenticator: { async authenticate() { return principal; } },
      requestLimiter: NOOP_RESOURCE_REQUEST_LIMITER,
    });
    await app.ready();

    try {
      await sql.query(
        `INSERT INTO users (id, login, display_name, password_hash)
         VALUES ($1, $2, 'Catalog HTTP', 'test')`,
        [userId, `catalog-http-${randomUUID()}`],
      );

      const tagId = randomUUID();
      const tagRequest = {
        method: "POST" as const,
        url: "/v1/tags",
        headers: { "idempotency-key": `tag-create-${randomUUID()}` },
        payload: {
          id: tagId,
          name: "Space weather",
          emoji: "☀️",
          metadata: { nested: { keep: 1, remove: 2 } },
        },
      };
      const tagCreated = await app.inject(tagRequest);
      const tagReplayed = await app.inject(tagRequest);
      assert.equal(tagCreated.statusCode, 201, tagCreated.body);
      assert.equal(tagReplayed.statusCode, 201, tagReplayed.body);
      assert.deepEqual(tagReplayed.json(), tagCreated.json());
      assert.equal(tagCreated.headers.location, `/v1/tags/${tagId}`);
      const tagPatched = await app.inject({
        method: "PATCH",
        url: `/v1/tags/${tagId}`,
        headers: {
          "content-type": "application/merge-patch+json",
          "idempotency-key": `tag-patch-${randomUUID()}`,
          "if-match": requiredHeader(tagCreated.headers.etag),
        },
        payload: { color: "#6E56CF", metadata: { nested: { remove: null, add: 3 } } },
      });
      assert.equal(tagPatched.statusCode, 200, tagPatched.body);
      assert.deepEqual(tagPatched.json().metadata, { nested: { keep: 1, add: 3 } });

      const templateId = randomUUID();
      const templateCreated = await app.inject({
        method: "POST",
        url: "/v1/templates",
        headers: { "idempotency-key": `template-create-${randomUUID()}` },
        payload: {
          id: templateId,
          name: "Solar flare",
          engine: "mustache",
          body: { text: "Flare {{class}}" },
          variableSchema: {
            type: "object",
            required: ["class"],
            properties: { class: { type: "string" } },
            additionalProperties: false,
          },
        },
      });
      assert.equal(templateCreated.statusCode, 201, templateCreated.body);
      assert.equal(templateCreated.json().version, 1);
      const templateUpdated = await app.inject({
        method: "PATCH",
        url: `/v1/templates/${templateId}`,
        headers: {
          "content-type": "application/merge-patch+json",
          "idempotency-key": `template-version-${randomUUID()}`,
          "if-match": requiredHeader(templateCreated.headers.etag),
        },
        payload: { body: { text: "Solar flare {{class}}" } },
      });
      assert.equal(templateUpdated.statusCode, 200, templateUpdated.body);
      assert.equal(templateUpdated.json().version, 2);
      const historical = await app.inject({
        method: "GET",
        url: `/v1/templates/${templateId}?version=1`,
      });
      assert.equal(historical.statusCode, 200, historical.body);
      assert.deepEqual(historical.json().body, { text: "Flare {{class}}" });

      const retired = await app.inject({
        method: "DELETE",
        url: `/v1/templates/${templateId}`,
        headers: {
          "idempotency-key": `template-retire-${randomUUID()}`,
          "if-match": requiredHeader(templateUpdated.headers.etag),
        },
      });
      assert.equal(retired.statusCode, 204, retired.body);
      assert.equal((await app.inject({
        method: "GET",
        url: `/v1/templates/${templateId}`,
      })).statusCode, 404);
      const retiredHistory = await app.inject({
        method: "GET",
        url: `/v1/templates/${templateId}?version=1`,
      });
      assert.equal(retiredHistory.statusCode, 200, retiredHistory.body);
      assert.ok(retiredHistory.json().retiredAt);
    } finally {
      try {
        await sql.query("DELETE FROM change_log WHERE user_id = $1", [userId]);
        await sql.query("DELETE FROM users WHERE id = $1", [userId]);
      } finally {
        await app.close();
        await sql.end();
        await database.close();
      }
    }
  },
);

function requiredHeader(value: string | string[] | undefined): string {
  if (typeof value !== "string") {
    throw new Error("Expected a scalar response header");
  }
  return value;
}
