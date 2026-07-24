#!/usr/bin/env bash
set -Eeuo pipefail

[[ "${1:-}" == --apply && "${2:-}" == --destination-is-encrypted && -n "${3:-}" ]] || {
  echo "Usage: $0 --apply --destination-is-encrypted DESTINATION" >&2
  echo "The destination must provide encryption at rest (for example FileVault or encrypted APFS)." >&2
  exit 2
}
remote="${REMOTE:-root@fractonica.com}"
. "$(dirname "${BASH_SOURCE[0]}")/../lib/maintenance-lock.sh"
fractonica_require_remote_provisioned "$remote"
destination="$3"
if [[ -e "$destination" ]] && find "$destination" -mindepth 1 -print -quit | grep -q .; then
  echo "backup destination must be new or empty: $destination" >&2; exit 1
fi
mkdir -p "$destination/media"
chmod 0700 "$destination"
stopped=0
fractonica_acquire_remote_lock "$remote" backup
cleanup() {
  if (( stopped )); then
    ssh "$remote" systemctl start fractonica-api.service >/dev/null 2>&1 \
      || echo "CRITICAL: fractonica-api did not restart; intervene on $remote" >&2
  fi
  fractonica_release_remote_lock "$remote"
}
trap cleanup EXIT

# Warm copy while writes continue, then a short write freeze for the final delta.
rsync -a --checksum --partial "$remote:/var/lib/fractonica/media/" "$destination/media/"
ssh "$remote" systemctl stop fractonica-api.service
stopped=1
ssh "$remote" "runuser -u postgres -- /usr/lib/postgresql/18/bin/pg_dump -Fc --no-owner --no-acl fractonica" \
  > "$destination/database.dump.partial"
rsync -a --checksum --delete "$remote:/var/lib/fractonica/media/" "$destination/media/"
mv "$destination/database.dump.partial" "$destination/database.dump"
ssh "$remote" "runuser -u postgres -- psql -At -d fractonica -c \"SELECT json_build_object('users',(SELECT count(*) FROM users),'records',(SELECT count(*) FROM records),'media',(SELECT count(*) FROM media_objects));\"" \
  > "$destination/database-counts.json"
ssh "$remote" "runuser -u postgres -- psql -At -d fractonica -c \"COPY (SELECT (SELECT count(*) FROM users), (SELECT count(*) FROM records), (SELECT count(*) FROM media_objects)) TO STDOUT\"" \
  > "$destination/database-counts.tsv"
ssh "$remote" "runuser -u postgres -- psql -At -d fractonica -c \"COPY (SELECT storage_key, byte_size, encode(sha256, 'hex') FROM media_objects WHERE status = 'ready' AND deleted_at IS NULL ORDER BY storage_key) TO STDOUT\"" \
  > "$destination/database-media.tsv"
ssh "$remote" "runuser -u postgres -- psql -At -F '|' -d fractonica -c \"SELECT pg_encoding_to_char(encoding), CASE datlocprovider WHEN 'c' THEN 'libc' ELSE datlocprovider::text END, datcollate, datctype, coalesce(datcollversion, '') FROM pg_database WHERE datname = current_database()\"" \
  > "$destination/database-locale.txt"
ssh "$remote" cat /opt/fractonica/current/RELEASE_ID > "$destination/release-id.txt"
ssh "$remote" "runuser -u postgres -- psql -At -d fractonica -c \"SELECT coalesce(json_agg(json_build_object('version', version, 'checksum', checksum) ORDER BY version), '[]'::json) FROM schema_migrations\"" \
  > "$destination/schema-migrations.json"
ssh "$remote" systemctl start fractonica-api.service
stopped=0
for _ in {1..30}; do
  ssh "$remote" curl -fsS http://127.0.0.1:8788/health/ready >/dev/null && { ready=1; break; }
  sleep 1
done
[[ "${ready:-0}" == 1 ]] || { echo "API did not become ready after backup" >&2; exit 1; }

(cd "$destination" && shasum -a 256 database.dump > database.dump.sha256)
(cd "$destination/media" && {
  while IFS= read -r -d '' file; do shasum -a 256 "$file"; done < <(find . -type f -print0)
} | LC_ALL=C sort -k 2 > ../media.sha256)
checked=0; missing=0; size_bad=0; hash_bad=0
while IFS=$'\t' read -r storage_key expected_size expected_sha; do
  [[ -n "$storage_key" ]] || continue
  file="$destination/media/$storage_key"
  if [[ ! -f "$file" ]]; then ((missing += 1)); echo "MISSING backup media: $storage_key" >&2; continue; fi
  if stat -f %z "$file" >/dev/null 2>&1; then actual_size="$(stat -f %z "$file")"; else actual_size="$(stat -c %s "$file")"; fi
  [[ "$actual_size" == "$expected_size" ]] || { ((size_bad += 1)); echo "SIZE backup media: $storage_key" >&2; continue; }
  actual_sha="$(shasum -a 256 "$file" | awk '{print $1}')"
  [[ "$actual_sha" == "$expected_sha" ]] || { ((hash_bad += 1)); echo "HASH backup media: $storage_key" >&2; continue; }
  ((checked += 1))
done < "$destination/database-media.tsv"
printf 'backup media integrity: checked=%d missing=%d size_bad=%d hash_bad=%d\n' \
  "$checked" "$missing" "$size_bad" "$hash_bad"
(( missing == 0 && size_bad == 0 && hash_bad == 0 )) || { echo "backup integrity failed" >&2; exit 1; }
printf 'remote=%s\ncreated_at=%s\n' "$remote" "$(date -u +%FT%TZ)" > "$destination/BACKUP"
(cd "$destination" && shasum -a 256 \
  BACKUP database-counts.json database-counts.tsv database-locale.txt \
  database-media.tsv database.dump.sha256 media.sha256 release-id.txt \
  schema-migrations.json \
  > BACKUP.sha256)
echo "backup complete: $destination"
