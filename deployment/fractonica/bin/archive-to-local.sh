#!/usr/bin/env bash
set -Eeuo pipefail

[[ "${1:-}" == --apply && "${2:-}" == --destination-is-encrypted && -n "${3:-}" ]] || {
  echo "Usage: $0 --apply --destination-is-encrypted DESTINATION.tar.gz" >&2
  echo "The destination must provide encryption at rest (for example FileVault or encrypted APFS)." >&2
  exit 2
}
destination="$3"
[[ "$destination" == *.tar.gz ]] || {
  echo "archive destination must end in .tar.gz: $destination" >&2
  exit 2
}
[[ ! -e "$destination" && ! -e "$destination.sha256" ]] || {
  echo "archive destination already exists: $destination" >&2
  exit 1
}
mkdir -p "$(dirname "$destination")"

remote="${REMOTE:-root@fractonica.com}"
. "$(dirname "${BASH_SOURCE[0]}")/../lib/maintenance-lock.sh"
fractonica_require_remote_provisioned "$remote"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
archive_name="fractonica-readable-archive-$stamp"
remote_work="/var/lib/fractonica/archive-work-$stamp"
remote_directory="$remote_work/$archive_name"
remote_archive="/opt/fractonica/incoming/$archive_name.tar.gz"
partial="$destination.partial"
stopped=0
lock_acquired=0

cleanup() {
  rm -f "$partial"
  ssh "$remote" "rm -rf '$remote_work' '$remote_archive'" >/dev/null 2>&1 || true
  if (( stopped )); then
    ssh "$remote" systemctl start fractonica-api.service >/dev/null 2>&1 \
      || echo "CRITICAL: fractonica-api did not restart; intervene on $remote" >&2
  fi
  (( lock_acquired == 0 )) || fractonica_release_remote_lock "$remote"
}
trap cleanup EXIT

fractonica_acquire_remote_lock "$remote" archive
lock_acquired=1
ssh "$remote" systemctl stop fractonica-api.service
stopped=1
ssh "$remote" "install -d -o fractonica-api -g fractonica-api -m 0700 '$remote_work'"
ssh "$remote" runuser -u fractonica-api -- bash -s -- "$remote_directory" <<'REMOTE'
set -Eeuo pipefail
destination="$1"
set -a
. /etc/fractonica/api.env
set +a
export NODE_ENV=production
export MEDIA_STORAGE_ROOT=/var/lib/fractonica/media
cd /opt/fractonica/current/api
exec /opt/fractonica/current/runtime/node --enable-source-maps \
  /opt/fractonica/current/api/dist/archive/cli.js --output "$destination"
REMOTE
ssh "$remote" systemctl start fractonica-api.service
stopped=0
ready=0
for _ in {1..30}; do
  ssh "$remote" curl -fsS http://127.0.0.1:8788/health/ready >/dev/null \
    && { ready=1; break; }
  sleep 1
done
(( ready )) || { echo "API did not become ready after archive" >&2; exit 1; }

ssh "$remote" "tar -C '$remote_work' -czf '$remote_archive' '$archive_name'"
expected_sha="$(ssh "$remote" "sha256sum '$remote_archive' | awk '{print \$1}'")"
[[ "$expected_sha" =~ ^[0-9a-f]{64}$ ]] || {
  echo "remote archive checksum is invalid" >&2
  exit 1
}
rsync -a --partial --progress "$remote:$remote_archive" "$partial"
actual_sha="$(shasum -a 256 "$partial" | awk '{print $1}')"
[[ "$actual_sha" == "$expected_sha" ]] || {
  echo "archive checksum changed during transfer" >&2
  exit 1
}
mv "$partial" "$destination"
printf '%s  %s\n' "$expected_sha" "$(basename "$destination")" > "$destination.sha256"
echo "readable archive complete: $destination"
