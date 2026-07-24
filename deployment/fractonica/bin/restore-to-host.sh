#!/usr/bin/env bash
set -Eeuo pipefail

[[ "${1:-}" == --apply && -n "${2:-}" ]] || {
  echo "Usage: $0 --apply BACKUP_DIRECTORY_OR_TAR_GZ" >&2
  exit 2
}
backup_input="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
extract_work=""
if [[ -d "$backup_input" ]]; then
  backup="$backup_input"
elif [[ -f "$backup_input" && "$backup_input" == *.tar.gz ]]; then
  if [[ -f "$backup_input.sha256" ]]; then
    expected_archive_sha="$(awk 'NR == 1 {print $1}' "$backup_input.sha256")"
    actual_archive_sha="$(shasum -a 256 "$backup_input" | awk '{print $1}')"
    [[ "$expected_archive_sha" =~ ^[0-9a-f]{64}$ \
      && "$actual_archive_sha" == "$expected_archive_sha" ]] || {
      echo "compressed backup checksum verification failed" >&2
      exit 1
    }
  fi
  while IFS= read -r entry; do
    [[ "$entry" == fractonica-backup || "$entry" == fractonica-backup/* ]] || {
      echo "compressed backup contains an unsafe path: $entry" >&2
      exit 1
    }
    [[ "$entry" != /* && "$entry" != *"/../"* && "$entry" != "../"* ]] || {
      echo "compressed backup contains a traversal path: $entry" >&2
      exit 1
    }
  done < <(tar -tzf "$backup_input")
  while IFS= read -r listing; do
    entry_type="${listing:0:1}"
    [[ "$entry_type" == "-" || "$entry_type" == "d" ]] || {
      echo "compressed backup contains a non-file entry" >&2
      exit 1
    }
  done < <(tar -tvzf "$backup_input")
  extract_work="$(mktemp -d "$(dirname "$backup_input")/.fractonica-restore.XXXXXX")"
  trap 'rm -rf "$extract_work"' EXIT
  tar -xzf "$backup_input" -C "$extract_work"
  backup="$extract_work/fractonica-backup"
else
  echo "backup input must be a directory or .tar.gz file: $backup_input" >&2
  exit 2
fi
remote="${REMOTE:-root@fractonica.com}"
. "$(dirname "${BASH_SOURCE[0]}")/../lib/maintenance-lock.sh"
fractonica_require_remote_provisioned "$remote"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
(cd "$backup" && shasum -a 256 -c BACKUP.sha256)
(cd "$backup" && shasum -a 256 -c database.dump.sha256)
[[ ! -s "$backup/media.sha256" ]] || (cd "$backup/media" && shasum -a 256 -c ../media.sha256)
IFS=$'\t' read -r expected_users expected_records expected_media < "$backup/database-counts.tsv"
for count_name in expected_users expected_records expected_media; do
  [[ "${!count_name}" =~ ^[0-9]+$ ]] || {
    echo "Invalid numeric count in backup metadata: $count_name" >&2; exit 1;
  }
done
IFS='|' read -r source_encoding source_provider source_collate source_ctype source_collversion \
  < "$backup/database-locale.txt"
[[ "$source_encoding" == UTF8 && "$source_provider" == libc \
  && "$source_collate" == en_US.utf8 && "$source_ctype" == en_US.utf8 ]] || {
  echo "Unsupported backup locale: $(<"$backup/database-locale.txt")" >&2; exit 1;
}
needed_kib="$(( $(du -sk "$backup/media" | awk '{print $1}') + 1048576 ))"
free_kib="$(ssh "$remote" "df -Pk /var/lib/fractonica | awk 'NR==2 {print \$4}'")"
(( free_kib >= needed_kib )) || {
  echo "target needs $needed_kib KiB free to stage this restore; found $free_kib" >&2; exit 1;
}
fractonica_acquire_remote_lock "$remote" restore
cleanup() {
  fractonica_release_remote_lock "$remote"
  [[ -z "$extract_work" ]] || rm -rf "$extract_work"
}
trap cleanup EXIT
incoming="/var/lib/fractonica/media.restore-$stamp"
remote_dump="/opt/fractonica/incoming/restore-$stamp.dump"
remote_manifest="/opt/fractonica/incoming/restore-$stamp.media.sha256"
ssh "$remote" "install -d -o fractonica-api -g fractonica-api -m 0700 '$incoming'"
rsync -a --checksum --partial --progress "$backup/media/" "$remote:$incoming/"
rsync -a "$backup/database.dump" "$remote:$remote_dump"
rsync -a "$backup/media.sha256" "$remote:$remote_manifest"
ssh "$remote" chown postgres:postgres "$remote_dump"
ssh "$remote" chmod 0600 "$remote_dump" "$remote_manifest"
dump_sha="$(awk '{print $1}' "$backup/database.dump.sha256")"
[[ "$dump_sha" =~ ^[0-9a-f]{64}$ ]] \
  || { echo "Invalid database checksum metadata" >&2; exit 1; }

ssh "$remote" bash -s -- "$remote_dump" "$incoming" "$stamp" "$remote_manifest" "$dump_sha" \
  "$expected_users" "$expected_records" "$expected_media" <<'REMOTE'
set -Eeuo pipefail
dump="$1"; incoming="$2"; stamp="$3"; manifest="$4"; expected_dump_sha="$5"
expected_users="$6"; expected_records="$7"; expected_media="$8"
suffix="${stamp//[^0-9]/}"
restore_db="fractonica_restore_$suffix"
old_db="fractonica_before_$suffix"
old_media="/var/lib/fractonica/media.before-$stamp"
old_db_moved=0; new_db_moved=0; old_media_moved=0; new_media_moved=0
recover() {
  status=$?
  trap - EXIT
  if (( status != 0 )); then
    systemctl stop fractonica-web.service fractonica-api.service 2>/dev/null || true
    if (( new_media_moved )); then mv /var/lib/fractonica/media "${incoming}.failed" || true; fi
    if (( old_media_moved )); then mv "$old_media" /var/lib/fractonica/media || true; fi
    if (( new_db_moved )); then
      runuser -u postgres -- psql -d postgres -c \
        "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'fractonica'" || true
      runuser -u postgres -- psql -d postgres -c \
        "ALTER DATABASE fractonica RENAME TO ${restore_db}_failed" || true
    fi
    if (( old_db_moved )); then
      runuser -u postgres -- psql -d postgres -c \
        "ALTER DATABASE $old_db RENAME TO fractonica" || true
    fi
    systemctl start fractonica-api.service fractonica-web.service || true
    echo "restore failed; rollback was attempted" >&2
  fi
  exit "$status"
}
trap recover EXIT
systemctl stop fractonica-web.service fractonica-api.service
[[ "$(sha256sum "$dump" | awk '{print $1}')" == "$expected_dump_sha" ]] \
  || { echo "transferred database checksum mismatch" >&2; exit 1; }
[[ ! -s "$manifest" ]] || (cd "$incoming" && sha256sum --quiet -c "$manifest")
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
dpkg --compare-versions "$vector_version" ge 0.8
runuser -u postgres -- psql -v ON_ERROR_STOP=1 -d "$restore_db" -c \
  "SELECT count(*) AS users FROM users;"
actual_counts="$(runuser -u postgres -- psql -At -F $'\t' -d "$restore_db" -c \
  "SELECT (SELECT count(*) FROM users), (SELECT count(*) FROM records), (SELECT count(*) FROM media_objects)")"
[[ "$actual_counts" == "$expected_users"$'\t'"$expected_records"$'\t'"$expected_media" ]] \
  || { echo "restored row counts differ from backup metadata" >&2; exit 1; }
runuser -u postgres -- "$pg_bin/vacuumdb" --analyze-in-stages --dbname="$restore_db"
runuser -u postgres -- psql -v ON_ERROR_STOP=1 -d postgres -c \
  "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'fractonica'"
runuser -u postgres -- psql -v ON_ERROR_STOP=1 -d postgres -c \
  "ALTER DATABASE fractonica RENAME TO $old_db"
old_db_moved=1
runuser -u postgres -- psql -v ON_ERROR_STOP=1 -d postgres -c \
  "ALTER DATABASE $restore_db RENAME TO fractonica"
new_db_moved=1
mv /var/lib/fractonica/media "$old_media"
old_media_moved=1
mv "$incoming" /var/lib/fractonica/media
new_media_moved=1
chown -R fractonica-api:fractonica-api /var/lib/fractonica/media
systemctl start fractonica-api.service fractonica-web.service

ready=0
for _ in {1..30}; do
  curl -fsS http://127.0.0.1:8788/health/ready >/dev/null \
    && curl -fsS 'http://127.0.0.1:8788/public/records?limit=1' >/dev/null \
    && curl -fsS http://127.0.0.1:3100/ >/dev/null && { ready=1; break; }
  sleep 1
done
(( ready )) || { echo "restore health check failed" >&2; exit 1; }
trap - EXIT
runuser -u postgres -- "$pg_bin/dropdb" --force "$old_db"
rm -rf "$old_media"
rm -f "$dump" "$restore_list" "$manifest"
echo "restore complete"
REMOTE
