import { readFile } from "node:fs/promises";

import type { FastifyInstance, FastifyReply } from "fastify";

const openApiUrl = new URL("../../openapi/openapi.yaml", import.meta.url);
const cryptoProfileUrl = new URL("../../docs/crypto-v1.md", import.meta.url);
const swaggerUiCssUrl = new URL(
  "../../node_modules/swagger-ui-dist/swagger-ui.css",
  import.meta.url,
);
const swaggerUiBundleUrl = new URL(
  "../../node_modules/swagger-ui-dist/swagger-ui-bundle.js",
  import.meta.url,
);
const swaggerUiStandalonePresetUrl = new URL(
  "../../node_modules/swagger-ui-dist/swagger-ui-standalone-preset.js",
  import.meta.url,
);
const swaggerUiFaviconUrl = new URL(
  "../../node_modules/swagger-ui-dist/favicon-32x32.png",
  import.meta.url,
);

/** Exposes the exact checked-in contract so agents never need a copied schema. */
export function registerOpenApiRoutes(app: FastifyInstance): void {
  let document: Promise<string> | undefined;
  let cryptoProfile: Promise<string> | undefined;
  const swaggerAssets = new Map<string, Promise<Buffer>>();

  app.get("/openapi.yaml", async (_request, reply) => {
    document ??= readFile(openApiUrl, "utf8");
    return reply
      .header("cache-control", "public, max-age=300")
      .type("application/yaml; charset=utf-8")
      .send(await document);
  });

  app.get("/docs", async (_request, reply) =>
    reply
      .header("cache-control", "public, max-age=60")
      .header(
        "content-security-policy",
        "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; " +
          "img-src 'self' data:; font-src 'self' data:; connect-src 'self'; base-uri 'none';",
      )
      .type("text/html; charset=utf-8")
      .send(SWAGGER_UI_PAGE),
  );

  app.get("/docs/swagger-ui.css", async (_request, reply) =>
    sendSwaggerAsset(reply, swaggerAssets, swaggerUiCssUrl, "text/css; charset=utf-8"),
  );
  app.get("/docs/swagger-ui-bundle.js", async (_request, reply) =>
    sendSwaggerAsset(
      reply,
      swaggerAssets,
      swaggerUiBundleUrl,
      "text/javascript; charset=utf-8",
    ),
  );
  app.get("/docs/swagger-ui-standalone-preset.js", async (_request, reply) =>
    sendSwaggerAsset(
      reply,
      swaggerAssets,
      swaggerUiStandalonePresetUrl,
      "text/javascript; charset=utf-8",
    ),
  );
  app.get("/docs/swagger-initializer.js", async (_request, reply) =>
    reply
      .header("cache-control", "public, max-age=60")
      .type("text/javascript; charset=utf-8")
      .send(SWAGGER_INITIALIZER),
  );
  app.get("/docs/favicon-32x32.png", async (_request, reply) =>
    sendSwaggerAsset(reply, swaggerAssets, swaggerUiFaviconUrl, "image/png"),
  );

  app.get("/docs/crypto-v1.md", async (_request, reply) => {
    cryptoProfile ??= readFile(cryptoProfileUrl, "utf8");
    return reply
      .header("cache-control", "public, max-age=300")
      .type("text/markdown; charset=utf-8")
      .send(await cryptoProfile);
  });
}

function sendSwaggerAsset(
  reply: FastifyReply,
  cache: Map<string, Promise<Buffer>>,
  assetUrl: URL,
  contentType: string,
) {
  const key = assetUrl.href;
  let asset = cache.get(key);
  if (asset === undefined) {
    asset = readFile(assetUrl);
    cache.set(key, asset);
  }
  return asset.then((body) =>
    reply
      .header("cache-control", "public, max-age=3600")
      .type(contentType)
      .send(body)
  );
}

const SWAGGER_UI_PAGE = `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>Exeligmos API Explorer</title>
  <link rel="icon" type="image/png" href="/docs/favicon-32x32.png">
  <link rel="stylesheet" href="/docs/swagger-ui.css">
</head>
<body>
  <div id="swagger-ui"></div>
  <script src="/docs/swagger-ui-bundle.js"></script>
  <script src="/docs/swagger-ui-standalone-preset.js"></script>
  <script src="/docs/swagger-initializer.js"></script>
</body>
</html>`;

const SWAGGER_INITIALIZER = `window.addEventListener("load", () => {
  window.ui = SwaggerUIBundle({
    url: "/openapi.yaml",
    dom_id: "#swagger-ui",
    deepLinking: true,
    displayRequestDuration: true,
    filter: true,
    tryItOutEnabled: true,
    requestSnippetsEnabled: true,
    validatorUrl: null,
    persistAuthorization: false,
    presets: [SwaggerUIBundle.presets.apis, SwaggerUIStandalonePreset],
    layout: "StandaloneLayout"
  });
});`;
