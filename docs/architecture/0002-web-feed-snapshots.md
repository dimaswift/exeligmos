# ADR 0002: Web feed snapshots and request-scoped authentication

- Status: accepted for Phase 3
- Date: 2026-07-15

## Context

The web application needs server-rendered public profiles, owner data, and global/following feeds
before realtime delivery is added. The backend exposes two deliberately different read models:

- record and event collection endpoints are authoritative current projections with independent
  sort orders and cursors;
- public activity is a durable, monotonically ordered identifier outbox used for invalidation and
  reconnect, not a copy of resource payloads.

Refresh tokens are rotating and single use. React Router executes matched loaders in parallel, so a
protected parent loader and child data loader cannot both own refresh independently.

## Decisions

### Current-state lanes

Public Explore, public profiles, and the owner's feed read record and event collections directly.
The two lanes keep independent `recordsCursor` and `eventsCursor` URL parameters. The client does
not invent a combined order or cursor because record and event endpoints use different canonical
sort keys.

Private owner records remain their generated encrypted projection. The web server and React tree do
not decrypt them or render ciphertext, nonce, or key material as content.

### Initial activity snapshot

Both activity endpoints accept `snapshot=latest` only when `cursor` is absent. In one repeatable-read
transaction, the server selects the newest bounded matching window, returns that window in
canonical sequence-ascending order, and returns an ordinary cursor anchored at the transaction's
high-water sequence. A subsequent request without `snapshot` can resume from that cursor.

Default activity reads remain oldest-forward historical reads. A cursor response with `hasMore`
does not represent a live resume anchor until the reader reaches a page where `hasMore` is false.

### Typed hydration

Activity payloads are never treated as embedded resources. The BFF dispatches upserts by generated
resource type and ID to the explicit public record, event, or profile endpoint. It never follows the
server-provided `resourceUrl`. Hydration is bounded to 200 items and 16 workers. Deletes remain
tombstones, and a 404 during upsert hydration is a normal visibility/deletion race represented as
an unavailable projection rather than a failed page.

### Authentication middleware

The protected pathless layout owns server middleware that calls `requireAuth` exactly once per
request and places the access-only authentication boundary in React Router's request context.
Nested loaders consume that context and cannot access or rotate the refresh token. If rotation
occurs, the middleware appends the new session cookie to the final document or data response.

Concurrent requests carrying the same nearly expired session share a short-lived refresh flight so
the backend's single-use token is not replayed.

### Realtime boundary

The SSR activity component stores a high-water opaque cursor only when the page is caught up. A
future SSE or WebSocket adapter may use it to resume, but live delivery remains a wake-up/latency
optimization over the durable HTTP activity contract. Current resource collections remain the
resnapshot authority.

## Consequences

- URL state is deterministic and browser back/forward preserves independent lanes.
- Following and global activity can start near the present without replaying the entire outbox.
- Hydration is intentionally bounded N+1 until a batch public-projection endpoint is justified.
- Follow management, record/event mutation, and live transport remain later feature slices.
