import assert from "node:assert/strict";
import test from "node:test";

import Fastify, { type FastifyRequest } from "fastify";

import type { Principal } from "../src/auth/principal.js";
import { HttpProblem } from "../src/http/problem.js";
import { registerProblemHandlers } from "../src/http/problem.js";
import type { ResourceRequestLimiter } from "../src/resources/rate-limit.js";
import {
  tagEtag,
  validateTagDefinition,
} from "../src/resources/tags.js";
import {
  templateEtag,
  validateTemplateDefinition,
} from "../src/resources/templates.js";
import { registerTagRoutes } from "../src/routes/tags.js";
import { registerTemplateRoutes } from "../src/routes/templates.js";
import { FakeDatabase } from "./helpers.js";

const tagId = "61092377-f4d8-4678-b2fc-aa8892011880";
const templateId = "156bb03e-dd0b-48bb-a5c1-808948de59f0";
const principal: Principal = {
  kind: "api_key",
  userId: "e42b4fde-8baf-4b95-8bc8-5395b68d0dd2",
  actorId: "0ce129e6-cbf7-4731-8829-7592f69fb31e",
  deviceId: "2dca8eab-00a8-4e94-9bd2-2fcbfe17e890",
  scopes: new Set(["tags:read", "tags:write", "templates:read", "templates:write"]),
};

test("tag definitions preserve catalog fields and enforce domain limits", () => {
  assert.deepEqual(
    validateTagDefinition({
      name: "Space weather",
      color: "#6E56CFFF",
      emoji: "☀️",
      sortOrder: -20,
      metadata: { source: "agent" },
    }),
    {
      name: "Space weather",
      color: "#6E56CFFF",
      emoji: "☀️",
      sortOrder: -20,
      metadata: { source: "agent" },
    },
  );
  assert.equal(tagEtag(tagId, 7), `"tag-${tagId}-r7"`);
  assert.throws(
    () => validateTagDefinition({ name: " not-trimmed" }),
    isProblem("invalid_tag_name"),
  );
  assert.throws(
    () => validateTagDefinition({ name: "Solar", color: "orange" }),
    isProblem("invalid_color"),
  );
  assert.throws(
    () => validateTagDefinition({ name: "Solar", metadata: { data: "x".repeat(32_768) } }),
    isProblem("metadata_too_large"),
  );
});

test("template definitions compile JSON Schema 2020-12 and validate Mustache syntax", () => {
  const definition = validateTemplateDefinition({
    name: "Solar flare",
    description: "Journal entry for a detected flare.",
    engine: "mustache",
    body: {
      text: "Solar flare {{class}} peaked at {{peakAt}}.",
      context: { strength: "{{strength}}" },
    },
    variableSchema: {
      type: "object",
      required: ["class", "peakAt", "strength"],
      properties: {
        class: { type: "string" },
        peakAt: { type: "string", format: "date-time" },
        strength: { type: "integer" },
      },
      additionalProperties: false,
    },
    metadata: { provider: "noaa" },
  });

  assert.equal(definition.engine, "mustache");
  assert.deepEqual(definition.metadata, { provider: "noaa" });
  assert.equal(templateEtag(templateId, 3), `"template-${templateId}-r3"`);
  for (const valueType of ["string", "integer"] as const) {
    assert.doesNotThrow(() => validateTemplateDefinition({
      name: `Tenant-local schema ${valueType}`,
      engine: "mustache",
      body: { value: "{{value}}" },
      variableSchema: {
        $id: "https://schemas.example.test/shared-id",
        type: "object",
        properties: { value: { type: valueType } },
      },
    }));
  }
  assert.throws(
    () => validateTemplateDefinition({
      name: "Async schema",
      engine: "mustache",
      body: { value: "{{value}}" },
      variableSchema: { $async: true, type: "object" },
    }),
    isProblem("invalid_template_schema"),
  );
  assert.throws(
    () => validateTemplateDefinition({
      name: "Invalid schema",
      engine: "mustache",
      body: { text: "{{value}}" },
      variableSchema: { type: "not-a-json-schema-type" },
    }),
    isProblem("invalid_template_schema"),
  );
  assert.throws(
    () => validateTemplateDefinition({
      name: "Partial",
      engine: "mustache",
      body: { text: "{{> shared}}" },
      variableSchema: { type: "object" },
    }),
    isProblem("template_partial_unsupported"),
  );
  assert.throws(
    () => validateTemplateDefinition({
      name: "Alternate delimiter partial",
      engine: "mustache",
      body: { text: "{{=<% %>=}} <%> shared %>" },
      variableSchema: { type: "object" },
    }),
    isProblem("template_partial_unsupported"),
  );
  assert.throws(
    () => validateTemplateDefinition({
      name: "Malformed",
      engine: "mustache",
      body: { text: "{{#open}}" },
      variableSchema: { type: "object" },
    }),
    isProblem("invalid_template"),
  );
});

test("tag and template routes enforce scopes and shared request budgets", async (context) => {
  const limiter = new RejectingCatalogLimiter();
  const requiredScopes: string[][] = [];
  const authenticator = {
    async authenticate(_request: FastifyRequest, scopes: readonly string[] = []) {
      requiredScopes.push([...scopes]);
      return principal;
    },
  };
  const app = Fastify({ logger: false });
  registerProblemHandlers(app);
  await app.register(registerTagRoutes, {
    database: new FakeDatabase(),
    authenticator,
    requestLimiter: limiter,
  });
  await app.register(registerTemplateRoutes, {
    database: new FakeDatabase(),
    authenticator,
    requestLimiter: limiter,
  });
  await app.ready();
  context.after(() => app.close());

  const tagRead = await app.inject({ method: "GET", url: "/v1/tags" });
  assert.equal(tagRead.statusCode, 429);
  const tagWrite = await app.inject({
    method: "DELETE",
    url: `/v1/tags/${tagId}`,
    headers: { "if-match": '"tag-r1"', "idempotency-key": "delete-tag-1" },
  });
  assert.equal(tagWrite.statusCode, 429);
  const templateRead = await app.inject({ method: "GET", url: "/v1/templates" });
  assert.equal(templateRead.statusCode, 429);
  const templateWrite = await app.inject({
    method: "DELETE",
    url: `/v1/templates/${templateId}`,
    headers: { "if-match": '"template-r1"', "idempotency-key": "delete-template-1" },
  });
  assert.equal(templateWrite.statusCode, 429);

  assert.deepEqual(requiredScopes, [
    ["tags:read"],
    ["tags:write"],
    ["templates:read"],
    ["templates:write"],
  ]);
  assert.deepEqual(limiter.calls, ["read", "write", "read", "write"]);
});

function isProblem(code: string): (error: unknown) => boolean {
  return (error: unknown) => error instanceof HttpProblem && error.code === code;
}

class RejectingCatalogLimiter implements ResourceRequestLimiter {
  readonly calls: string[] = [];

  async checkPublicRecordRead(): Promise<void> {
    this.reject("public");
  }

  async checkAuthenticatedRead(): Promise<void> {
    this.reject("read");
  }

  async checkAuthenticatedWrite(): Promise<void> {
    this.reject("write");
  }

  private reject(kind: string): never {
    this.calls.push(kind);
    throw new HttpProblem({ status: 429, code: "test_limit", detail: "limited" });
  }
}
