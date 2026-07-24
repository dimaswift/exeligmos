#!/usr/bin/env bash
set -Eeuo pipefail

[[ "${1:-}" == --apply && "${2:-}" == --destination-is-encrypted && -n "${3:-}" \
  && ( "$#" == 3 || ( "$#" == 4 && "${4:-}" == --compress ) ) ]] || {
  echo "Usage: $0 --apply --destination-is-encrypted DESTINATION [--compress]" >&2
  echo "The destination must provide encryption at rest (for example FileVault or encrypted APFS)." >&2
  exit 2
}
remote="${REMOTE:-root@fractonica.com}"
. "$(dirname "${BASH_SOURCE[0]}")/../lib/maintenance-lock.sh"
fractonica_require_remote_provisioned "$remote"
requested_destination="$3"
compress=0
work=""
if [[ "${4:-}" == --compress ]]; then
  compress=1
  [[ "$requested_destination" == *.tar.gz ]] || {
    echo "compressed backup destination must end in .tar.gz: $requested_destination" >&2
    exit 2
  }
  [[ ! -e "$requested_destination" && ! -e "$requested_destination.sha256" ]] || {
    echo "backup destination already exists: $requested_destination" >&2
    exit 1
  }
  mkdir -p "$(dirname "$requested_destination")"
  work="$(mktemp -d "$(dirname "$requested_destination")/.fractonica-backup.XXXXXX")"
  destination="$work/fractonica-backup"
else
  destination="$requested_destination"
  if [[ -e "$destination" ]] && find "$destination" -mindepth 1 -print -quit | grep -q .; then
    echo "backup destination must be new or empty: $destination" >&2; exit 1
  fi
fi
mkdir -p "$destination/media"
chmod 0700 "$destination"
stopped=0
lock_acquired=0
cleanup() {
  if (( stopped )); then
    ssh "$remote" systemctl start fractonica-api.service >/dev/null 2>&1 \
      || echo "CRITICAL: fractonica-api did not restart; intervene on $remote" >&2
  fi
  (( lock_acquired == 0 )) || fractonica_release_remote_lock "$remote"
  [[ -z "$work" ]] || rm -rf "$work"
  (( compress == 0 )) || rm -f "$requested_destination.partial"
}
trap cleanup EXIT
fractonica_acquire_remote_lock "$remote" backup
lock_acquired=1

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
  > BACKUP.sha256)
if (( compress )); then
  tar -C "$work" -czf "$requested_destination.partial" fractonica-backup
  mv "$requested_destination.partial" "$requested_destination"
  artifact_sha="$(shasum -a 256 "$requested_destination" | awk '{print $1}')"
  printf '%s  %s\n' "$artifact_sha" "$(basename "$requested_destination")" \
    > "$requested_destination.sha256"
  echo "compressed backup complete: $requested_destination"
else
  echo "backup complete: $destination"
fi
