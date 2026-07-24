#!/usr/bin/env bash
set -Eeuo pipefail

[[ "${1:-}" == --apply && "${2:-}" == --source-quiesced ]] || {
  echo "Usage: $0 --apply --source-quiesced" >&2
  echo "Stop the local API and all writers before acknowledging --source-quiesced." >&2
  exit 2
}
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
remote="${REMOTE:-root@fractonica.com}"
. "$(dirname "${BASH_SOURCE[0]}")/../lib/maintenance-lock.sh"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
work="$(mktemp -d)"
lock_acquired=0
cleanup() {
  (( lock_acquired == 0 )) || fractonica_release_remote_lock "$remote"
  rm -rf "$work"
}
trap cleanup EXIT
dump="$work/fractonica.dump"
expected_media="$work/media-expected.tsv"
media_manifest="$work/media.sha256"
database_locale="$work/database-locale.txt"
incoming="/var/lib/fractonica/media.incoming-$stamp"
remote_dump="/opt/fractonica/incoming/first-$stamp.dump"
remote_manifest="/opt/fractonica/incoming/first-$stamp.media.sha256"

"$(dirname "${BASH_SOURCE[0]}")/host-preflight.sh"
fractonica_require_remote_provisioned "$remote"
npm --prefix "$root/sync-server" run db:migrate
docker compose -f "$root/sync-server/compose.yaml" exec -T postgres sh -ec \
  'exec psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -At -F "|" -c "SELECT pg_encoding_to_char(encoding), CASE datlocprovider WHEN '\''c'\'' THEN '\''libc'\'' ELSE datlocprovider::text END, datcollate, datctype, coalesce(datcollversion, '\'''\'') FROM pg_database WHERE datname = current_database()"' \
  > "$database_locale"
IFS='|' read -r source_encoding source_provider source_collate source_ctype source_collversion < "$database_locale"
[[ "$source_encoding" == UTF8 && "$source_provider" == libc \
  && "$source_collate" == en_US.utf8 && "$source_ctype" == en_US.utf8 ]] || {
  echo "Unsupported source locale: $(<"$database_locale")" >&2; exit 1;
}
echo "source database locale=$(<"$database_locale") (indexes rebuild against target libc)"
docker compose -f "$root/sync-server/compose.yaml" exec -T postgres sh -ec \
  'exec psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -At -c "COPY (SELECT storage_key, byte_size, encode(sha256, '\''hex'\'') FROM media_objects WHERE status = '\''ready'\'' AND deleted_at IS NULL ORDER BY storage_key) TO STDOUT"' \
  > "$expected_media"
: > "$media_manifest"
checked=0; missing=0; size_bad=0; hash_bad=0
while IFS=$'\t' read -r storage_key expected_size expected_sha; do
  [[ -n "$storage_key" ]] || continue
  file="$root/sync-server/var/media/$storage_key"
  if [[ ! -f "$file" ]]; then
    echo "MISSING media: $storage_key" >&2; ((missing += 1)); continue
  fi
  if stat -f %z "$file" >/dev/null 2>&1; then actual_size="$(stat -f %z "$file")"; else actual_size="$(stat -c %s "$file")"; fi
  if [[ "$actual_size" != "$expected_size" ]]; then
    echo "SIZE media: $storage_key expected=$expected_size actual=$actual_size" >&2
    ((size_bad += 1)); continue
  fi
  actual_sha="$(shasum -a 256 "$file" | awk '{print $1}')"
  if [[ "$actual_sha" != "$expected_sha" ]]; then
    echo "HASH media: $storage_key" >&2; ((hash_bad += 1)); continue
  fi
  printf '%s  ./%s\n' "$expected_sha" "$storage_key" >> "$media_manifest"
  ((checked += 1))
done < "$expected_media"
printf 'media integrity: checked=%d missing=%d size_bad=%d hash_bad=%d\n' \
  "$checked" "$missing" "$size_bad" "$hash_bad"
(( missing == 0 && size_bad == 0 && hash_bad == 0 )) || {
  echo "Refusing first migration until every ready database media object is repaired." >&2; exit 1;
}
docker compose -f "$root/sync-server/compose.yaml" exec -T postgres sh -ec \
  'exec pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc --no-owner --no-acl' > "$dump"
[[ -s "$dump" ]] || { echo "source database dump is empty" >&2; exit 1; }

fractonica_acquire_remote_lock "$remote" first-migration
lock_acquired=1
ssh "$remote" "install -d -o fractonica-api -g fractonica-api -m 0700 '$incoming'"
rsync -a --checksum --partial --human-readable --progress \
  "$root/sync-server/var/media/" "$remote:$incoming/"
rsync -a "$dump" "$remote:$remote_dump"
rsync -a "$media_manifest" "$remote:$remote_manifest"
ssh "$remote" chown postgres:postgres "$remote_dump"
ssh "$remote" chmod 0600 "$remote_dump" "$remote_manifest"
dump_sha="$(shasum -a 256 "$dump" | awk '{print $1}')"

ssh "$remote" bash -s -- "$remote_dump" "$incoming" "$stamp" "$remote_manifest" "$dump_sha" <<'REMOTE'
set -Eeuo pipefail
dump="$1"; incoming="$2"; stamp="$3"; manifest="$4"; expected_dump_sha="$5"
restore_db="fractonica_restore_${stamp//[^0-9]/}"
empty_db="fractonica_empty_${stamp//[^0-9]/}"
old_media="/var/lib/fractonica/media.empty-$stamp"
restart=0
if [[ -e /opt/fractonica/current ]]; then restart=1; fi
systemctl stop fractonica-web.service fractonica-api.service 2>/dev/null || true
old_db_moved=0; new_db_moved=0; old_media_moved=0; new_media_moved=0
recover() {
  status=$?; trap - EXIT
  if (( status != 0 )); then
    if (( new_media_moved )); then mv /var/lib/fractonica/media "${incoming}.failed" || true; fi
    if (( old_media_moved )); then mv "$old_media" /var/lib/fractonica/media || true; fi
    if (( new_db_moved )); then
      runuser -u postgres -- psql -d postgres -c \
        "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='fractonica'" || true
      runuser -u postgres -- psql -d postgres -c \
        "ALTER DATABASE fractonica RENAME TO ${restore_db}_failed" || true
    fi
    if (( old_db_moved )); then
      runuser -u postgres -- psql -d postgres -c \
        "ALTER DATABASE $empty_db RENAME TO fractonica" || true
    fi
  fi
  (( restart == 0 )) || systemctl start fractonica-api.service fractonica-web.service || true
  exit "$status"
}
trap recover EXIT
[[ "$(sha256sum "$dump" | awk '{print $1}')" == "$expected_dump_sha" ]] \
  || { echo "transferred database checksum mismatch" >&2; exit 1; }
[[ ! -s "$manifest" ]] || (cd "$incoming" && sha256sum --quiet -c "$manifest")

if [[ "$(runuser -u postgres -- psql -At -d fractonica -c "SELECT to_regclass('public.users') IS NOT NULL")" == t ]]; then
  existing_users="$(runuser -u postgres -- psql -At -d fractonica -c 'SELECT count(*) FROM users')"
else
  existing_users=0
fi
[[ "$existing_users" == 0 ]] || { echo "target database is not empty; use restore-to-host.sh" >&2; exit 1; }
find /var/lib/fractonica/media -mindepth 1 -print -quit | grep -q . \
  && { echo "target media directory is not empty" >&2; exit 1; }

pg_bin=/usr/lib/postgresql/18/bin
runuser -u postgres -- "$pg_bin/dropdb" --if-exists --force "$restore_db"
runuser -u postgres -- "$pg_bin/createdb" --owner=fractonica --encoding=UTF8 \
  --locale-provider=libc --lc-collate=en_US.utf8 --lc-ctype=en_US.utf8 \
  --template=template0 "$restore_db"
runuser -u postgres -- psql -v ON_ERROR_STOP=1 -d "$restore_db" \
  -c 'CREATE EXTENSION IF NOT EXISTS vector'
restore_list="${dump}.list"
runuser -u postgres -- "$pg_bin/pg_restore" --list "$dump" > "$restore_list"
sed -i -E '/ EXTENSION - vector[[:space:]]*$/s/^/;/; / COMMENT - EXTENSION vector[[:space:]]*$/s/^/;/' "$restore_list"
restore_common=(--exit-on-error --no-owner --no-acl --no-comments --role=fractonica \
  --use-list="$restore_list" --dbname="$restore_db")
runuser -u postgres -- "$pg_bin/pg_restore" "${restore_common[@]}" --section=pre-data "$dump"
if [[ "$(runuser -u postgres -- psql -At -d "$restore_db" -c \
  "SELECT to_regprocedure('public.exeligmos_jsonb_compact_octet_length(jsonb)') IS NOT NULL")" == t ]]; then
  runuser -u postgres -- psql -v ON_ERROR_STOP=1 -d "$restore_db" -c \
    'ALTER FUNCTION public.exeligmos_jsonb_compact_octet_length(jsonb) SET search_path = pg_catalog, public'
fi
runuser -u postgres -- "$pg_bin/pg_restore" "${restore_common[@]}" --section=data "$dump"
runuser -u postgres -- "$pg_bin/pg_restore" "${restore_common[@]}" --section=post-data "$dump"
vector_version="$(runuser -u postgres -- psql -At -d "$restore_db" -c \
  "SELECT extversion FROM pg_extension WHERE extname='vector'")"
dpkg --compare-versions "$vector_version" ge 0.8 \
  || { echo "restored pgvector is older than 0.8" >&2; exit 1; }
runuser -u postgres -- "$pg_bin/vacuumdb" --analyze-in-stages --dbname="$restore_db"

runuser -u postgres -- psql -v ON_ERROR_STOP=1 -d postgres \
  -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='fractonica'"
runuser -u postgres -- psql -v ON_ERROR_STOP=1 -d postgres \
  -c "ALTER DATABASE fractonica RENAME TO $empty_db"
old_db_moved=1
runuser -u postgres -- psql -v ON_ERROR_STOP=1 -d postgres \
  -c "ALTER DATABASE $restore_db RENAME TO fractonica"
new_db_moved=1
mv /var/lib/fractonica/media "$old_media"
old_media_moved=1
mv "$incoming" /var/lib/fractonica/media
new_media_moved=1
chown -R fractonica-api:fractonica-api /var/lib/fractonica/media
trap - EXIT
runuser -u postgres -- "$pg_bin/dropdb" --force "$empty_db"
rm -rf "$old_media"
rm -f "$dump" "$restore_list" "$manifest"
(( restart == 0 )) || systemctl start fractonica-api.service fractonica-web.service
echo "first migration complete"
REMOTE
