# ADR 0001: Web, social, and realtime-ready foundation

- Status: accepted for Phase 1
- Date: 2026-07-15

## Context

The web application is a desktop analytics surface for records, events, tags,
templates, media, and temporal data. It also needs public account pages and a
future global/following feed. Automated publishers such as `@sun` are ordinary
accounts that authenticate with scoped API keys and publish through the same
record and event contracts as interactive users.

The existing Fastify service and OpenAPI document remain the authoritative
application API. The web server must not become a second domain backend.

## Decisions

### Web runtime

Use React Router Framework Mode, React, strict TypeScript, Vite, and server-side
rendering. Deploy the web and API services behind one origin. The web server is
a thin backend-for-frontend: it owns browser sessions, forwards typed API
requests, and renders public routes. It does not query PostgreSQL directly.

Access and refresh tokens are held in server-managed secure, HTTP-only cookies.
They are never persisted in browser JavaScript storage.

### Stable public identity

An active account has a case-insensitively unique login and can be addressed as
`@login`. Human and automated publishers use the same account model. Automation
is represented by API-key/device provenance, not by a separate content model.

Public profile responses are explicit projections. They must never reuse an
owner/admin row wholesale or expose password, session, device, encryption, or
API-key state.

### Subscriptions

Subscriptions are private owner-scoped state. A subscription identifies a
publisher and can independently opt into that publisher's public records and
public events. The schema may gain additional filters later without changing
publisher identity or activity cursors. A disabled target remains visible to
the subscriber as disabled private state so the subscription can still be
synced or removed; it contributes no public feed content.

### Typed references

References are first-class, typed links. A source is a record or event owned by
the actor. A target is a user, record, or event. The relation is an explicit,
bounded identifier rather than an unstructured URL hidden inside payload JSON.

Cross-user record/event targets must be active and public when the reference is
created. Owner-only references may be returned with owner resources; anonymous
responses only expose references whose source and target are both publicly
resolvable. If a public target is later deleted, the historical link may remain
as an identifier-only tombstone, but it must not expose the former payload. A
reference must never make a private payload, private event, or owner-only
metadata discoverable.

### Ordered public activity

PostgreSQL stores a durable, monotonically ordered public-activity stream for
public record/event changes and user visibility controls. A row identifies the
publisher, resource type, resource ID, operation, revision, and change time. It
is an outbox, not a copy of the resource payload. User delete/upsert controls
tell consumers to purge an actor or refetch that actor's public projection;
record/event filters include these controls automatically.

Outbox writers are initially deferred constraint triggers. They take the global
publisher lock only after ordinary resource statements have completed, then
allocate sequences while holding it through commit. This keeps sequence order
safe for cursor advancement without introducing an early row-lock inversion.

Historical reads and reconnects use an opaque cursor over that durable stream.
Future SSE or WebSocket delivery is only a low-latency notification transport;
clients resume from the durable cursor after disconnects. PostgreSQL
`LISTEN/NOTIFY`, if introduced, is a wake-up signal and never the source of
truth. Phase 1 keeps this stream unpruned; a later retention policy must preserve
an explicit reset/re-snapshot path for cursors older than retained history.
Normal user lifecycle is soft disable/re-enable. There is no hard-delete API;
administrative hard deletion is destructive erasure and requires all activity
consumers to discard cursors and rebuild.

### Analytics client

Feed and analytics filters are serializable query models, normally reflected in
the URL. Transport, filtering, temporal calculation, and rendering remain
separate modules. Screens may compose tables, timelines, inspectors, and charts,
but none of them reimplement rarity, time-unit, or glyph rules.

### Temporal and glyph authority

A versioned language-neutral domain catalog defines supported harmonic depths,
time-unit identities, rarity semantics, event-type identities, glyph constants,
and semantic style roles. TypeScript and Swift bindings are generated or checked
against the catalog. Golden conformance vectors preserve the current Swift
behavior during the web port.

The temporal and glyph core packages are deterministic and independent of
React, CSS, browser APIs, network calls, locale, and wall-clock globals. The
primary web glyph adapter renders accessible SVG from normalized geometry.

## Security invariants

- Public feeds contain projections, never owner resources.
- Private record ciphertext is never decrypted by the API or web server.
- Following an account grants no additional read permission.
- A public reference does not grant access to its target.
- Realtime delivery applies the same authorization and projection rules as
  historical HTTP reads.
- API-key provenance and device binding remain visible to the owner but are not
  disclosed on public profiles.

## Phase 1 non-goals

- No recommendation/ranking algorithm.
- No fan-out-on-write delivery table per subscriber.
- No websocket-only state or presence system.
- No universal graph or causal-signature model.
- No duplication of the Fastify domain API inside the web server.
