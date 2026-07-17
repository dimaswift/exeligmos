# Exeligmos web

Server-rendered React Router workspace for desktop temporal analytics and public activity. This is a
new frontend; it does not share UI state or view models with the legacy viewer.

The current frontend provides the generated API boundary, encrypted browser session, public and
owner feeds, profiles, analytics, record and tag CRUD, API-backed media attachments, and a realtime
System Lab. The activity transport remains protocol-neutral so WebSocket or SSE delivery can be
added without changing snapshot ownership or cursor semantics.

## Architecture

```text
web/
  app/
    components/             desktop shell and inspector surface
    features/
      activity-feed/        generated-type cards, lanes, and activity presentation
      activity-stream/      typed HTTP snapshots + protocol-neutral ordered stream port
      engine-lab/           realtime Saros Grid, waveform, and period inspection
      management/           record/tag mutations and media upload lifecycle
      references/           typed entity-reference navigation
      temporal/             generated native solar data adapter
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
`../sync-server/openapi/openapi.yaml`. Feature loaders and actions use the typed client factory
rather than handwritten request or response interfaces. The current contract includes
authentication, public and owner resources, activity projections, references, CRUD mutations, and
streaming media upload sessions.

### Record management and attachments

The protected Records and Tags routes perform mutations through the generated client and preserve
the backend's revision/ETag and idempotency contracts. New record attachments follow the API's
three-step lifecycle: reserve an upload, PUT the raw bytes with their exact length and SHA-256, then
complete the upload and attach the returned media IDs to the record. Failed record creation performs
best-effort cleanup of already-completed media objects. The web form accepts at most 20 attachments,
64 MiB per file, and 128 MiB total per record submission. The management list uses server-side UTC
date filtering and compact rows with the stored phase plus four contextual Saros spikes; record
start/end fields use native datetime pickers and recalculate that context on save.

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

The shell is analytics-first: navigation on the left, a dense working surface in the center, and a
persistent realtime Saros window on the right. The temporal window stays mounted while navigating
authenticated routes, so its zoom, rarity threshold, playhead, and audio state are not reset by a
workspace transition. Its expand control promotes the same live instance to a full-screen view.

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

### Temporal engine and System Lab

The protected `/lab/engines` route is a realtime inspection surface for the same solar intervals and
temporal rules used when the web client creates records. Its clock and countdown advance every
second, while the 40-series Saros Grid, closest phase, four contextual spike glyphs, Saros pulse,
waveform, repdigit cadences, and exact-versus-average octal periods refresh on the native
five-second engine cadence.

The authenticated shell owns the global sliding window. It preloads the previous, current, and next
epoch-aligned segment and can step from Mili (average Saros divided by `8^8`) through Saros, Kilo,
Mega, Giga, and Tera. A reusable threshold control selects Triplex, Duplex, Simplex, or Nihil as the
lowest visible rarity. Wide segments retain exact event counts while bucketing SVG markers and
sampling waveform brackets, avoiding full materialization of every Triplex in a Tera. The panel
exposes the next event as an MSB-first/LSB-second 5+5 phase and lists eight past plus four future
global spikes. Optional Web Audio clicks are scheduled at fractional crossing timestamps without
replaying events missed while the page was hidden. Presentation depth remains reproducible through
the `depth` query parameter; record context remains on its independent canonical depth-eight
contract.

`npm run solar:generate` deterministically decodes the native app's bundled `eclipse_times.db`,
`eclipse_info.db`, `saros.db`, and available `SolarGeoData/*.bin` files into the compact server-only
solar artifact. Generation validates canonical lengths and indices and fully decodes every bundled
geometry record. `npm run solar:check` performs the same work without writing and fails when the
checked-in artifact is missing or stale.

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

Generated OpenAPI, catalog, and solar files are checked into the workspace so editors and tests work
after a clone. Typecheck, tests, development, and builds regenerate their required bindings;
`npm run check` runs the non-mutating solar drift check before any regeneration so an outdated
artifact fails visibly.

## Next implementation slice

1. Add event and subscription management plus typed reference creation/inspection flows.
2. Add the live activity transport adapter over the existing high-water cursor boundary.
3. Add desktop temporal filters, timelines, and aggregate analytics over the snapshot lanes.
4. Extend attachment management to existing records without weakening revision safety.
