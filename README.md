# Exeligmos

Exeligmos is a local-first temporal journal and analytics platform. The native
iOS app captures records, events, tags, templates, and media; the Fastify API
synchronizes those resources between users and devices; and the server-rendered
web app is the desktop surface for inspection, public profiles, references, and
future realtime feeds.

Automated publishers are ordinary accounts. For example, an account such as
`@sun` can publish solar records and events with a scoped API key, appear in the
global feed, be followed by other users, and be referenced from their records
or events.

## Project layout

- `SarosHarmonicJournal.xcodeproj` and `SarosHarmonicJournal/` — SwiftUI capture
  client, local persistence, sync, clock, glyph, and media features.
- `sync-server/` — PostgreSQL/pgvector Fastify API, migrations, authentication,
  OpenAPI contract, public profiles, subscriptions, typed references, and the
  durable public-activity cursor.
- `web/` — React Router Framework Mode SSR application and modular TypeScript
  packages for the API client, domain catalog, temporal engine, glyph core, and
  React/SVG UI.
- `domain-spec/` — language-neutral canonical catalog and conformance vectors
  shared by Swift and TypeScript implementations.
- `docs/architecture/` — cross-client architecture decisions.

The Fastify OpenAPI document is the application API authority. The web server
is a thin browser-session and rendering boundary; it does not query PostgreSQL
or duplicate domain behavior.

## Domain model

Records and events are user-owned, device-attributed resources with public or
private visibility. Public is the default. Private record payloads are encrypted
by the client and remain opaque to the server.

Typed, ordered references allow a record or event to point to a user, record,
or event. Cross-user resource targets must be public when the reference is
created. Following a user is private account state and never grants access to
private content.

Public record/event changes and user visibility controls append to a durable
PostgreSQL activity stream. Global and following feeds use opaque resumable
cursors; a later SSE or WebSocket adapter will provide low-latency notifications
without becoming the source of truth.

## Server development

Requirements: Docker, Node 24+, and npm 11+.

```sh
cd sync-server
cp .env.example .env
docker compose up -d
npm install
npm run db:migrate
npm run dev:v2
```

The API defaults to `http://127.0.0.1:8788`. Swagger UI is available at
`/docs`, and the source contract is `sync-server/openapi/openapi.yaml`.

Useful verification commands:

```sh
cd sync-server
npm run check
npm run build
npm run test:integration
```

See `sync-server/README.md` for environment, migration, authentication, API-key,
legacy-import, media, and deployment details.

## Web development

```sh
cd web
cp .env.example .env
npm install
npm run dev
```

`npm run check` validates the canonical domain catalog, regenerates the typed
OpenAPI client and catalog binding, then runs lint, type checking, tests, and a
production SSR build. See `web/README.md` for package boundaries and security
details.

## Domain catalog

`domain-spec/catalog.json` is the single source of truth for harmonic depths,
time-unit identities, rarity rules, event-type namespaces, semantic colors,
and glyph geometry. Validate it and its Swift-derived golden vectors with:

```sh
cd domain-spec
npm install
npm test
```

Consumers must generate bindings or pass the conformance vectors; they should
not maintain parallel production constants.

## iOS development

Open the project in Xcode:

```sh
open SarosHarmonicJournal.xcodeproj
```

The app uses SwiftData and targets iOS 17+. A compile-only simulator check can
be run without code signing:

```sh
xcodebuild build \
  -project SarosHarmonicJournal.xcodeproj \
  -scheme SarosHarmonicJournal \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO
```

## Implementation status

Phase 1 established the social/realtime-ready data model, canonical domain
contract, generated client, secure web session boundary, SSR route structure,
and package/test pipeline. Phase 2 adds conformance-complete temporal and rarity
calculations, catalog-driven immutable glyph geometry, the accessible SVG
renderer, and a deterministic desktop engine lab. Phase 3 adds authoritative
public/owner snapshot lanes, public profiles, newest-window activity snapshots,
generated-type hydration, independent URL cursors, and request-scoped auth
middleware. Live delivery, typed editing flows, subscription management, and
full CRUD analytics screens remain in the next implementation slices.
