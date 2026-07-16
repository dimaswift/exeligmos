# Exeligmos web

Server-rendered React Router workspace for desktop temporal analytics and public activity. This is a
new frontend; it does not share UI state or view models with the legacy viewer.

Phase 1 provides the application and package boundaries, generated API contract, encrypted browser
session, protected shell, public routes, and test/build pipeline. Phase 2 adds the
conformance-complete temporal/rarity engine, immutable catalog-driven glyph geometry, accessible SSR
renderer, and the protected engine inspection lab. Phase 3 adds typed SSR public/owner snapshots,
public profiles, global/following activity windows, independent cursor URL state, and a
request-scoped authentication boundary. CRUD mutations and live delivery are intentionally not
implemented yet.

## Architecture

```text
web/
  app/
    components/             desktop shell and inspector surface
    features/
      activity-feed/        generated-type cards, lanes, and activity presentation
      activity-stream/      typed HTTP snapshots + protocol-neutral ordered stream port
      engine-lab/           executable generated conformance boundary
      references/           typed entity-reference navigation
    lib/                    server-only API and session boundary
    routes/                 SSR route composition
  packages/
    api-client/             generated OpenAPI types + openapi-fetch factory
    domain-catalog/         generated view of ../domain-spec/catalog.json
    temporal-core/          pure, timezone-independent calculations
    glyph-core/             pure validated geometry primitives
    ui/                     React/SVG adapters only
```

Feature code may import packages; packages must not import `app/`. Temporal and glyph core packages
must remain free of React, the DOM, networking, locale formatting, and the wall clock.

### Canonical domain catalog

`../domain-spec/catalog.json` is the sole authority for time units, rarity semantics, glyph
geometry, semantic tokens, and numeric event types. `npm run catalog:generate` deterministically
creates `packages/domain-catalog/src/catalog.generated.ts`,
`packages/domain-catalog/src/conformance.generated.ts`, and their SHA-256 diagnostic fingerprints.
Never add parallel production constants to the web package.

`npm run check` first executes the domain-spec schema, invariant, and conformance-vector validator.

### API contract

`npm run api:generate` creates `packages/api-client/src/schema.ts` directly from
`../sync-server/openapi/openapi.yaml`. Feature loaders should use the typed client factory rather
than handwritten response interfaces. The current contract includes public users, public
records/events, activity projections, and typed references; Phase 1 only establishes their frontend
boundaries.

### Authentication boundary

The browser submits credentials to a React Router action. The BFF exchanges them with Fastify and
keeps access and rotating refresh credentials inside an AES-256-GCM sealed, signed, `HttpOnly`,
`SameSite=Lax` cookie. Browser JavaScript never receives either token. Production cookies also use
`Secure` and the `__Host-` prefix.

`SESSION_SECRET` is mandatory in production and must have at least 32 characters. Changing it
invalidates existing browser sessions. The encrypted cookie is intentionally small enough for the
current auth payload; if session state grows, replace it with a durable shared server-side store and
retain only an opaque identifier in the cookie.

The app-layout server middleware is the single refresh-rotation owner for each request. It shares an
access-only boundary through React Router request context and attaches any rotated cookie to the
final response. Nested loaders consume that context; they must not independently rotate the same
single-use refresh token. Concurrent near-expiry requests also share a short-lived refresh flight.

### Analytics and live activity

The shell is analytics-first: navigation on the left, dense working surface in the center,
persistent entity inspector on the right. Records, events, users, and references share the inspector
boundary so an analytical query does not lose context when a related entity is opened.

`ActivityStreamTransport` deliberately assumes no SSE, WebSocket, or polling implementation. It
accepts global, following, and user scopes and yields items in canonical server order with an opaque
cursor. The HTTP activity endpoint's explicit `snapshot=latest` mode returns a bounded newest window
in ascending sequence order plus a high-water cursor; ordinary cursor reads then resume forward. The
SSR component exposes that anchor only after it is caught up. Phase 3 does not fake realtime
behavior.

Current-state screens do not misuse the outbox as a database projection: Explore, public profiles,
and My feed read authoritative record/event collections with independent `recordsCursor` and
`eventsCursor` URL state. Global/following activity hydrates typed upserts through explicit public
routes, ignores `resourceUrl`, and preserves deletes or 404 visibility races as lifecycle notices.

### Temporal and glyph engine lab

The protected `/lab/engines` route is a backend-independent inspection surface for the production
engines. Its address, presentation depth, supplied interval, instant, and clock depth are serialized
in the query string; it never reads the wall clock. The lab renders every supported depth and arm
digit, every rarity header/subrarity/alias, malformed input fixtures, split semantic paint, all time
unit durations, and the exact generated conformance results.

`@exeligmos/temporal-core` strictly separates calculation depth from presentation depth and retains
the native address/rarity boundary behavior. `@exeligmos/glyph-core` emits deeply frozen, fill-only
geometry cached by `geometryVersion:depth`. Glyph creation requires exactly one explicit rarity or
catalog-backed style because the catalog does not define a generic default paint. See the package
READMEs for the public APIs and compatibility rules.

## Local development

Requirements: Node 24+, npm 11+, and the sync server running on port `8788` by default.

```sh
cd web
cp .env.example .env
npm install
npm run dev
```

Set a strong local `SESSION_SECRET` if login continuity matters. The development fallback exists
only to make first boot possible.

## Verification

```sh
npm run lint
npm run typecheck
npm test
npm run build

# Full gate, including canonical domain validation
npm run check
```

Generated OpenAPI and catalog files are checked into the workspace so editors and tests work after a
clone. The scripts regenerate them before typecheck/build to make drift fail visibly.

## Next implementation slice

1. Build record, event, and tag management surfaces on the generated API client.
2. Add subscription management and typed reference creation/inspection flows.
3. Add the live activity transport adapter over the existing high-water cursor boundary.
4. Add desktop temporal filters, timelines, and aggregate analytics over the snapshot lanes.
