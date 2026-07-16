# Exeligmos Sync Server

Exeligmos v2 is a multi-user PostgreSQL service for first-party clients and
user-authorized automation agents. Its public contract is OpenAPI 3.1, records
are public by default or may be stored as opaque client-encrypted ciphertext,
and PostgreSQL includes pgvector for later similarity search.

There is deliberately no v1 wire or storage compatibility in this design. The
legacy relay is a frozen migration source. The v2 server never reads it at
runtime and the repeatable importer treats it as read-only.

## Current implementation status

The running Phase 3 server implements the complete checked-in v2 contract:

- process liveness, PostgreSQL/pgvector readiness, and served API documentation;
- login/password registration, login, rotating refresh tokens, logout, and
  immediately revocable Ed25519 JWT access tokens;
- the current-user and create-once encryption-profile endpoints;
- logical devices, explicit current-session device binding, and device
  revocation;
- scoped, device-bound API-key issuance, inspection, and revocation;
- authenticated public/private record list, create, read, replace, patch, and
  soft-delete operations;
- unauthenticated public-record list and read projections;
- authenticated lightweight event list, create, read, patch, and soft-delete
  operations;
- user-owned tag CRUD and immutable, historical template versions with strict
  JSON Schema validation and Mustache rendering;
- reserved, streamed, SHA-256-verified public/private media upload sessions,
  immutable media objects, and owner/public downloads;
- an ordered, tenant-isolated change feed with tombstones, retention watermarks,
  opaque cursors, and cursor-expiry responses;
- bounded atomic or per-item synchronization batches for records, events, tags,
  and templates, including durable client-mutation receipts;
- shared PostgreSQL request limits for public record traffic and authenticated
  owner, security, record, event, catalog, media, and synchronization operations;
- tenant predicates, ETags, idempotency records, audit rows, revision history,
  and ordered change-log emission behind those handlers.

The checked-in [`openapi/openapi.yaml`](openapi/openapi.yaml) is both the complete
v2 contract and the implemented HTTP surface. It is safe to use for client
generation after reviewing the private-content crypto profile.

## Requirements

- Node.js 24 or newer and npm 11 or newer
- Docker with Compose v2 for the local PostgreSQL/pgvector database

## Local setup

From this directory:

```sh
cp .env.example .env
npm ci
```

Replace both occurrences of the example database password in `.env` with the
same long URL-safe random value (or percent-encode it in `DATABASE_URL`). Generate
the Ed25519 JWT key exactly once and place its base64 value in
`AUTH_JWT_PRIVATE_KEY_BASE64`:

```sh
openssl genpkey -algorithm ED25519 -outform DER | base64 | tr -d '\n'
```

Start PostgreSQL and apply every migration:

```sh
docker compose up -d postgres
npm run db:migrate
```

The migration runner serializes concurrent invocations with a PostgreSQL
advisory lock, runs each migration transactionally, and refuses to continue if
an applied file's SHA-256 checksum has changed.

For development, run the TypeScript process with watch mode:

```sh
npm run dev:v2
```

For the compiled v2 server, build first and then use the standard start command:

```sh
npm run build
npm start
```

`npm start` is equivalent to `npm run start:v2` and starts the PostgreSQL v2
server on port 8788 by default. The folder relay executable has been removed;
its frozen `data/` hierarchy is accepted only by the migration command.

Confirm both health states:

```sh
curl http://localhost:8788/health/live
curl http://localhost:8788/health/ready
```

Expected responses are:

```json
{"status":"ok"}
{"status":"ready","checks":{"database":"up","pgvector":"up"}}
```

## Served API documentation

The running server publishes documentation without requiring authentication:

- `GET /docs` is a packaged, same-origin Swagger UI explorer with **Try it out**
  support for JWTs and API keys;
- `GET /openapi.yaml` serves the exact checked-in OpenAPI 3.1 contract for API
  explorers and client generators;
- `GET /docs/crypto-v1.md` serves the normative mnemonic, key derivation, record,
  and media encryption profile, including deterministic test vectors.

For local development, open `http://localhost:8788/docs`, select **Authorize**,
and paste either the JWT or API-key bearer value. Authorization is never
persisted across a reload. Swagger assets are packaged with the server rather
than loaded from a CDN, and the page uses a restrictive content-security
policy. The OpenAPI document uses same-origin server URLs, so importing
`http://localhost:8788/openapi.yaml` into another explorer also targets the
running server.

## Configuration and security controls

All configuration is read from the environment. `.env` is loaded by the
provided npm scripts and is excluded from Git and Docker build contexts.

> **Production transport requirement:** expose this API only through HTTPS/TLS
> (normally a trusted reverse proxy or load balancer) and reject plain HTTP at
> the edge. Passwords, refresh/access tokens, API keys, private ciphertext, and
> media all travel in HTTP requests; bearer credentials have no protection on
> an unencrypted connection. Plain HTTP is suitable only for loopback local
> development. Configure HSTS at the TLS terminator and set `TRUST_PROXY_HOPS`
> to the exact proxy count.

| Variable | Default | Meaning |
| --- | --- | --- |
| `NODE_ENV` | `development` | `development`, `test`, or `production`. |
| `HOST` / `PORT` | `0.0.0.0` / `8788` | v2 listen address. |
| `LOG_LEVEL` | `info` | Structured Fastify log level; credential fields are redacted. |
| `TRUST_PROXY_HOPS` | `0` | Exact number of trusted reverse-proxy hops. `0` uses the direct peer address. |
| `SHUTDOWN_TIMEOUT_MS` | `10000` | Graceful shutdown deadline. |
| `DATABASE_URL` | required | PostgreSQL connection URL used by the app and migration runner. |
| `MIGRATIONS_DIR` | `db/migrations` | Migration directory, resolved from the migration runner's working directory. |
| `DB_POOL_MAX` | `10` | Maximum PostgreSQL connections per server process. |
| `DB_CONNECTION_TIMEOUT_MS` | `5000` | Pool connection timeout. |
| `DB_IDLE_TIMEOUT_MS` | `30000` | Pool idle-connection timeout. |
| `DB_READINESS_TIMEOUT_MS` | `2000` | Readiness query timeout. |
| `DB_STATEMENT_TIMEOUT_MS` | `15000` | Maximum PostgreSQL statement runtime for application connections. |
| `DB_LOCK_TIMEOUT_MS` | `5000` | Maximum time an application statement may wait for a PostgreSQL lock. |
| `DB_IDLE_IN_TRANSACTION_TIMEOUT_MS` | `15000` | Maximum idle time allowed inside an application transaction. |
| `MEDIA_STORAGE_ROOT` | `var/media` | Persistent root for v2 media bytes. Keep it outside the read-only legacy `data/` source. |
| `MEDIA_MAX_BYTE_LENGTH` | `5368709120` | Maximum declared media upload size, constrained to 1 byte through 5 GiB. |
| `MEDIA_UPLOAD_TTL_SECONDS` | `86400` | Reservation lifetime before incomplete media uploads expire. |
| `AUTH_REGISTRATION_MODE` | `open` | `open`, `invite`, or `closed`. Use `invite` or `closed` for a private deployment. |
| `AUTH_REGISTRATION_INVITE_CODE` | none | Required only in `invite` mode. Keep it out of logs and source control. |
| `AUTH_JWT_ISSUER` | `exeligmos-sync-server` | Exact JWT `iss` value. Use a deployment-specific value in production. |
| `AUTH_JWT_AUDIENCE` | `exeligmos-clients` | Exact JWT `aud` value. |
| `AUTH_JWT_KEY_ID` | `primary` | `kid` placed in access tokens. |
| `AUTH_JWT_PRIVATE_KEY_BASE64` | required | Base64 PKCS#8 DER Ed25519 signing key. Every replica must receive the same key. |
| `AUTH_ACCESS_TOKEN_TTL_SECONDS` | `900` | Access-token lifetime, constrained to 60-3600 seconds. |
| `AUTH_REFRESH_TOKEN_TTL_SECONDS` | `2592000` | Rotating refresh-token lifetime. |
| `AUTH_ARGON2_MAX_CONCURRENCY` | `2` | Maximum simultaneous Argon2 operations per process, constrained to 1-16. |

`TRUST_PROXY_HOPS` directly affects `request.ip`, which is part of authentication
rate-limit identity. Set it to the exact number of proxies between the public
client and this process. Leaving it at `0` behind a proxy groups all traffic under
the proxy address; setting too many trusted hops permits caller-controlled
forwarding headers to influence the address.

Authentication has two layers of throttling. A cheap in-process limiter rejects
registration after 5 attempts per IP per hour, login after 10 attempts per IP per
15 minutes, and refresh after 30 attempts per IP per minute. PostgreSQL-backed
buckets survive restarts and apply across replicas: registration and login share
a global password-work budget of 120 attempts per minute; registration is also
limited to 5 per IP per hour; login is also limited to 30 per IP and 10 per
normalized account per 15 minutes; refresh is limited to 30 per IP per minute.
These thresholds are currently code-level policy, not environment variables.
`AUTH_ARGON2_MAX_CONCURRENCY` separately bounds memory-hard password work inside
each server process.

Resource routes use a separate PostgreSQL fixed-window limiter. Every replica
atomically advances the same SHA-256-hashed buckets; raw IP addresses, user IDs,
session IDs, and API-key IDs are not stored in the limiter table. The fixed
code-level policy is:

| Resource traffic | 60-second limit |
| --- | ---: |
| Anonymous public-record reads, cluster-wide | 3000 |
| Anonymous public-record reads, per source IP | 120 |
| Authenticated reads, aggregate per user | 1200 |
| Authenticated reads, per JWT session or API key | 600 |
| Authenticated writes, aggregate per user | 240 |
| Authenticated writes, per JWT session or API key | 120 |

Authenticated budgets cover current-user, encryption-profile, device, API-key,
record, event, tag, template, media, and synchronization routes. Public record
and public media reads consume both the global and per-IP buckets. A rejected
request returns an RFC 9457 `429` response and a `Retry-After` header. Because
public limits also use `request.ip`, configure `TRUST_PROXY_HOPS` exactly for
the deployment topology.

Records have deliberately small cursor pages: the default is 10 and the maximum
is 25. Lightweight event, device, and API-key pages retain their default of 50
and maximum of 200. Regular JSON requests use a 1 MiB body limit; sync batches
are capped at 16 MiB, and declared media bytes stream directly into verified
storage rather than buffering in memory. Storage amplification is also bounded:

- a public record payload may serialize to at most 262144 UTF-8 bytes;
- record metadata, source metadata, and event metadata may each serialize to at
  most 32768 UTF-8 bytes;
- a private-record ciphertext may contain at most 524288 decoded bytes,
  including its GCM tag (at most 699052 canonical base64 characters).
- one media object may contain at most `MEDIA_MAX_BYTE_LENGTH` bytes (5 GiB by
  default), and both `Content-Length` and SHA-256 must match its reservation.

The services validate final values, including rendered template payloads and
merged patches, before writing. Migration constraints apply the same numeric
bounds to PostgreSQL JSONB/ciphertext storage so direct SQL and future handlers
cannot bypass them.

The server generates API-key secrets itself with 256 bits of randomness. There
is no API-key master-secret environment variable: only SHA-256 hashes and
non-secret display prefixes are persisted.

## Authentication and device binding

Registration and login return a short-lived access JWT and a rotating refresh
token. Every authenticated JWT request checks live session, user, and optional
device state in PostgreSQL, so logout, refresh-token reuse detection, user
disablement, and bound-device revocation take effect immediately.

Login sessions begin without a device binding because a new client may need to
register its logical device first. A first-party client should:

1. authenticate with `POST /v1/auth/register` or `POST /v1/auth/login`;
2. register or locate its device through `/v1/devices`;
3. call `PUT /v1/devices/{deviceId}/current-session` with its JWT.

The `PUT` is JWT-only and idempotently sets or replaces the binding for the
current refresh-token family. Revoking that device then revokes its active API
keys and every JWT session bound to it. Registering an automation device does
not bind the human operator's session automatically; do not call the binding
endpoint for an agent device unless the current login session actually belongs
to that device.

## External-agent quickstart

The operator uses a JWT to create the logical agent and its API key. The agent
then uses only the API key; it never receives the user's password or refresh
token.

Set the server URL and copy an `accessToken` returned by login:

```sh
BASE_URL=http://localhost:8788
JWT='<login accessToken>'
DEVICE_ID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
```

Register the automation device. Keep the idempotency key stable if this request
must be retried:

```sh
curl --fail-with-body -sS \
  -X POST "$BASE_URL/v1/devices" \
  -H "Authorization: Bearer $JWT" \
  -H 'Content-Type: application/json' \
  -H "Idempotency-Key: device-$DEVICE_ID" \
  -d "{\"id\":\"$DEVICE_ID\",\"name\":\"Solar flare watcher\",\"kind\":\"agent\",\"platform\":\"python\",\"metadata\":{\"provider\":\"noaa-swpc\"}}"
```

Issue the agent key with only the scopes it needs:

```sh
KEY_REQUEST_ID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
curl --fail-with-body -sS \
  -X POST "$BASE_URL/v1/api-keys" \
  -H "Authorization: Bearer $JWT" \
  -H 'Content-Type: application/json' \
  -H "Idempotency-Key: api-key-$KEY_REQUEST_ID" \
  -d "{\"name\":\"Solar flare watcher\",\"deviceId\":\"$DEVICE_ID\",\"scopes\":[\"records:read\",\"records:write\",\"events:read\",\"events:write\"]}"
```

Copy the `secret` from the 201 response into the agent's secret store immediately:

```sh
API_KEY='<exk_ secret returned by creation>'
RECORD_REQUEST_ID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
```

The agent can now create a public record. Public is the default visibility, so
`visibility` may be omitted:

```sh
curl --fail-with-body -sS \
  -X POST "$BASE_URL/v1/records" \
  -H "Authorization: Bearer $API_KEY" \
  -H 'Content-Type: application/json' \
  -H "Idempotency-Key: record-$RECORD_REQUEST_ID" \
  -d "{\"deviceId\":\"$DEVICE_ID\",\"occurredAt\":\"2026-07-14T18:00:00Z\",\"payload\":{\"label\":\"X-class solar flare\",\"class\":\"X1.2\"},\"source\":{\"kind\":\"agent\",\"provider\":\"noaa-swpc\",\"externalId\":\"example-flare-2026-07-14\"}}"
```

Fetch the user's records with the same key:

```sh
curl --fail-with-body -sS \
  -H "Authorization: Bearer $API_KEY" \
  "$BASE_URL/v1/records?limit=25&sourceProvider=noaa-swpc"
```

An API key may assert only its bound `deviceId`; using another owned device ID
returns a device-binding error. Use the analogous `/v1/events` operations for
lightweight intervals that need no media, templates, encryption, or embeddings.

## Public profiles, subscriptions, and activity cursors

Public profiles resolve by stable login at `GET /v1/public/users/{login}`.
Authenticated users can follow another user with `PUT
/v1/subscriptions/{targetUserId}` and consume either the global `GET
/v1/public/activity` cursor or the subscription-filtered `GET /v1/activity`
cursor. Activity entries are identifier-only notifications; record and event
payloads remain behind their own public resource URLs.

The activity stream also carries user lifecycle controls. `resourceType: user`
with `operation: delete` means that the profile is disabled and a client must
hide or purge every cached public record/event from that actor. `operation:
upsert` means that the profile is public again; clients should refetch its
`resourceUrl` and then the public record and event lists filtered by the actor's
user ID. Selecting only record or event activity still includes these user
controls, so advancing a filtered cursor cannot skip a required invalidation.

Public lifecycle is status-based: production code must disable and re-enable
users rather than hard-delete them. There is no hard-delete API. A direct
administrative `DELETE FROM users` is a destructive data-erasure operation
that cascades the actor's activity history, so every public-activity consumer
must discard its cursor and rebuild after such maintenance.

## One-time API-key secrets and retries

API-key creation intentionally differs from ordinary replayable mutations:

- the first successful `POST /v1/api-keys` returns 201 with `key` metadata and
  the plaintext `secret`;
- the server stores only the secret hash and cannot retrieve the plaintext;
- replaying the same `Idempotency-Key` with the same body returns 409 with code
  `api_key_secret_already_returned` and the created `apiKeyId` extension;
- reusing the idempotency key with a different body returns 409 with code
  `idempotency_conflict`.

For example, a replay after a lost 201 response includes:

```json
{
  "status": 409,
  "code": "api_key_secret_already_returned",
  "apiKeyId": "a8ec5fdc-e6cf-4bc6-b00b-3db4ca240f12"
}
```

API-key inspection and revocation are JWT-only. If the original secret was not
saved, use `apiKeyId` with `GET /v1/api-keys/{apiKeyId}` to inspect the orphaned
credential or `DELETE /v1/api-keys/{apiKeyId}` to revoke it, then create a
replacement with a new idempotency key. The secret is never returned again.

## Catalog, media, and synchronization

Synchronization emits privacy-safe structured diagnostics at `info`/`warn`:

- `sync_batch_received` records the account/device, client headers, mutation
  kinds, IDs, ID lengths, and tag/media counts;
- `sync_batch_completed` records each acknowledgement or stable problem code;
- `sync_batch_rejected` records schema paths before authentication/processing.

Record payloads, event labels, tag names, encryption envelopes, credentials,
media bytes, and authorization/idempotency headers are never included in these
diagnostic summaries. Filter the JSON server output by the `event` field while
reproducing an upload.

Tags are ordinary revisioned resources. Templates retain immutable historical
versions: `PATCH /v1/templates/{templateId}` creates the next version, while a
version query retrieves the exact earlier definition. Template variables are
validated against JSON Schema 2020-12 before Mustache renders a public record.
Partials and asynchronous/custom execution are intentionally unavailable.

Media uses a four-step, retry-safe lifecycle:

1. reserve metadata with `POST /v1/media-upload-sessions`;
2. stream the exact bytes as `application/octet-stream` to the returned
   `uploadUrl`, including `Content-Length` and `X-Content-SHA256`;
3. finalize with `POST /v1/media-upload-sessions/{uploadId}/complete`;
4. attach the returned `mediaId` in a public or private record mutation.

Bytes are atomically written only after length and SHA-256 validation. Completed
media is immutable. Anonymous download is available only while public media is
attached to an active public record; owner downloads always require
`media:read`. Private media carries only its ciphertext envelope metadata.

The sync API is a relay for offline-first clients, not an authority over their
local stores. Clients persist local CRUD first, then submit those operations to
`POST /v1/sync/batches`. The server stores accepted state and exposes the
resulting commands to the owner's other devices and, where public/subscribed,
feed consumers. Missing rows in a collection snapshot never imply deletion;
clients remove local data only after receiving an explicit delete tombstone.

`GET /v1/sync/stats` returns owner-scoped record, event, tag, template, and media
totals plus a command-feed cursor captured at the same starting boundary. A
restoring client captures these statistics first, merges the bounded owner
collection pages into local storage, and then requests `GET /v1/sync/changes`
from that cursor. This makes the totals usable for progress while the command
feed catches every write committed during the snapshot without replaying the
entire retained history.

`GET /v1/sync/changes` returns that commit-ordered, cursor-based owner command
feed with full current resources for upserts and minimal tombstones for deletes.
A cursor older than a retained high-water mark returns `410 cursor_expired`;
the client must capture fresh statistics, repeat the same merge-only owner
snapshot, and resume from the fresh cursor. `POST
/v1/sync/batches` accepts at most 20 record/event/tag/template mutations and
supports either all-or-nothing atomic execution or ordered per-item results.
`clientMutationId` receipts last 30 days, so a retry cannot silently apply a
different mutation body. Record upserts are deliberately client-authoritative:
when the same record ID already exists (including a relay tombstone), the
submitted local record replaces it and succeeds without requiring an ETag.
Events, tags, and templates retain conditional replacement semantics.

## Legacy migration

The repeatable migration tool is documented in
[`docs/legacy-import.md`](docs/legacy-import.md). It provides:

- a read-only dry run over the folder source;
- exact counts and a stable SHA-256 over every imported JSON document and media
  byte;
- explicit destination user and device mapping;
- atomic, verified media copies and provenance-preserving public records;
- persisted run state, safe resume, and a completed-run verification mode that
  re-hashes stored media without creating new revisions.

Run `npm run import:legacy -- --help` for the command synopsis. Animacy data is
explicitly excluded from migration and remains only in the frozen source
backup.

## Record privacy and lightweight events

Password authentication and private-record encryption are separate. On first
setup, a client offers a machine-generated 12-word BIP-39 recovery mnemonic,
keeps it off the server, and uploads only a non-secret key-check value. A new
device needs both a valid login and those words to decrypt private content. The
exact byte-level interoperability rules are in [`docs/crypto-v1.md`](docs/crypto-v1.md).

Public record payloads can reference tags, media, versioned templates, metadata,
and future embeddings. A private record exposes operational identity, an
AES-256-GCM ciphertext envelope, and opaque encrypted-media attachment IDs;
occurrence time, payload, tags, source, media descriptions, and semantic
metadata stay inside ciphertext. Database constraints prevent private tags or
embeddings and keep record visibility immutable after creation.

Events are intentionally independent and lightweight: start and optional end
timestamps, label, numeric type, JSON metadata, user, and device. They have
revision and synchronization history but no media, templates, encryption
envelope, or embeddings.

The schema includes pgvector and model-versioned public-record embedding rows.
No embedding generation or similarity-search HTTP endpoint is implemented yet;
model-specific indexes wait until model and dimensionality are selected.

## Validation and production build

Run the TypeScript, unit, HTTP, and OpenAPI checks:

```sh
npm run check
```

Run live PostgreSQL integration tests against a disposable or dedicated test
database after applying migrations:

```sh
TEST_DATABASE_URL=postgresql://user:password@localhost:5432/test_database \
  npm run test:integration
```

Build the production JavaScript and container image with:

```sh
npm run build
docker build -t exeligmos-sync-server:v2 .
```

The image runs as the unprivileged `node` user. Migrations are an explicit
deployment step; the server never mutates its schema at startup. Run
`npm run db:migrate:prod` in a one-off container before starting a new release.

Stop and remove the local database, including its volume, with:

```sh
docker compose down -v
```

## Cutover and future similarity search

Before production cutover, freeze writes to the old installation, take a
filesystem backup, run the final importer dry run and apply with the same source
checksum, then run it once more in verification mode. Keep the backup until a
v2 client has completed a fresh snapshot and media spot-check.

Similarity search remains deliberately deferred. The schema and pgvector
extension are ready, but model selection, dimensions, generation jobs, and
model-specific indexes must be chosen before exposing a similarity endpoint.
