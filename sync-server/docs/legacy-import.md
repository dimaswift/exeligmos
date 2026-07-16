# Legacy folder migration

The v2 server does not read the folder relay at runtime. `import:legacy` is the
one-way, repeatable cutover tool for the active `data/entries` and `data/tags`
layout. It treats the source as read-only and deliberately excludes
`data/animacy`, because animacy is not part of v2.

The importer preserves each entry's UUID, timestamps, complete JSON document,
tag relationships, media UUID/order/bytes, and legacy source-device details.
Legacy plaintext becomes a public v2 record. The source JSON is the record
`payload`, so the first-party client can decode it without a lossy intermediate
format. Import provenance and source hashes are stored in resource metadata.

Private v2 records require client-side encryption and therefore cannot be
created by a server-side plaintext migration. A client may explicitly create a
new private record after cutover if it needs to reclassify legacy content.

## 1. Prepare the destination

Apply all migrations, create or select the destination user, and register one
active v2 device for each legacy `sourceDeviceID`. The user and device UUIDs
must already exist in PostgreSQL. The importer will not silently create or
guess ownership.

Create a mapping file from
[`legacy-import-mapping.example.json`](legacy-import-mapping.example.json):

```json
{
  "schemaVersion": 1,
  "userId": "00000000-0000-4000-8000-000000000001",
  "devices": {
    "ABCDE": "00000000-0000-4000-8000-000000000101"
  }
}
```

Every legacy device reported by the scanner must appear exactly once. Add
`unattributedDeviceId` only when the scanner reports entries with no
`sourceDeviceID`.

## 2. Dry-run against the destination

From `sync-server/`, with `DATABASE_URL` configured:

```sh
npm run import:legacy -- \
  --source ./data \
  --mapping ./legacy-import-mapping.json \
  --dry-run \
  --report ./migration-reports/legacy-dry-run.json
```

The scan validates UUIDs, timestamps, compact tag references, media metadata,
path containment, file presence, payload limits, duplicate IDs, and exact
entry/media relationships. It streams every media file through SHA-256 and
produces one stable `sourceChecksum` over all imported JSON and bytes. It also
verifies that the mapped user and devices are active and reports which
resources would be created or recognized as a prior partial attempt.

An older `groups/`, `saros/`, or `threads/` journal layout is rejected rather
than silently skipped. Consolidate such data with a backed-up pre-v2 relay
release in an isolated copy, then repeat the dry run against its active layout.

## 3. Freeze and apply

Stop the old installation before the final dry run. Keep a separate backup of
the source hierarchy. Confirm the final checksum and counts, then apply to the
same source snapshot:

```sh
npm run import:legacy -- \
  --source ./data \
  --mapping ./legacy-import-mapping.json \
  --apply \
  --storage-root ./var/media \
  --report ./migration-reports/legacy-applied.json
```

`--storage-root` must be the same persistent media root used by the v2 server;
`MEDIA_STORAGE_ROOT` may be used instead. Media is copied with atomic,
length-and-SHA-256-verified writes. PostgreSQL triggers create revisions and
ordered sync changes for imported resources.

The database stores a `legacy_import_runs` audit row binding the source
checksum to its owner/device mapping checksum. A failed run can resume after
its lease expires. Each resumed attempt receives a monotonically increasing
fencing token, and heartbeats, failure updates, and completion all require that
exact token; a stale process therefore cannot overwrite the newer attempt's run
state. Active imports renew the lease between resources and verification
steps. Re-running a completed import does not create revisions:
it verifies every database relationship and re-hashes every stored media
object. A changed mapping for the same source checksum, conflicting UUID,
altered payload, missing attachment, or corrupt byte is a hard error.

## Mapping and report handling

- Keep mapping and report files outside images and source control; they expose
  user/device identifiers and local migration details.
- Reports are written atomically with owner-only file permissions.
- Do not delete the frozen source backup until the completed run has been
  re-run in verification mode and the v2 client has fetched the expected data.
- Animacy captures and model-training data are intentionally left in the
  backup and never copied into v2.
