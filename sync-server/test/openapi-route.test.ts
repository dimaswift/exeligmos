import assert from "node:assert/strict";
import test from "node:test";

import Fastify from "fastify";

import { registerOpenApiRoutes } from "../src/routes/openapi.js";

test("the checked-in OpenAPI contract and Swagger explorer are served", async () => {
  const app = Fastify({ logger: false });
  registerOpenApiRoutes(app);

  const [contract, docs, cryptoProfile, stylesheet, initializer, favicon] = await Promise.all([
    app.inject({ method: "GET", url: "/openapi.yaml" }),
    app.inject({ method: "GET", url: "/docs" }),
    app.inject({ method: "GET", url: "/docs/crypto-v1.md" }),
    app.inject({ method: "GET", url: "/docs/swagger-ui.css" }),
    app.inject({ method: "GET", url: "/docs/swagger-initializer.js" }),
    app.inject({ method: "GET", url: "/docs/favicon-32x32.png" }),
  ]);
  await app.close();

  assert.equal(contract.statusCode, 200);
  assert.match(contract.headers["content-type"] ?? "", /^application\/yaml/);
  assert.match(contract.body, /^openapi: 3\.1\.0/m);
  assert.match(contract.body, /\/v1\/records:/);
  assert.equal(docs.statusCode, 200);
  assert.match(docs.headers["content-type"] ?? "", /^text\/html/);
  assert.match(docs.body, /id="swagger-ui"/);
  assert.match(docs.body, /src="\/docs\/swagger-initializer\.js"/);
  assert.match(docs.headers["content-security-policy"] ?? "", /script-src 'self'/);
  assert.doesNotMatch(docs.headers["content-security-policy"] ?? "", /unsafe-eval/);
  assert.equal(cryptoProfile.statusCode, 200);
  assert.match(cryptoProfile.headers["content-type"] ?? "", /^text\/markdown/);
  assert.match(cryptoProfile.body, /AES-256-GCM/);
  assert.equal(stylesheet.statusCode, 200);
  assert.match(stylesheet.headers["content-type"] ?? "", /^text\/css/);
  assert.match(stylesheet.body, /\.swagger-ui/);
  assert.equal(initializer.statusCode, 200);
  assert.match(initializer.headers["content-type"] ?? "", /^text\/javascript/);
  assert.match(initializer.body, /url: "\/openapi\.yaml"/);
  assert.match(initializer.body, /persistAuthorization: false/);
  assert.equal(favicon.statusCode, 200);
  assert.match(favicon.headers["content-type"] ?? "", /^image\/png/);
  assert.ok(favicon.rawPayload.byteLength > 0);
});
