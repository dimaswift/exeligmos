#!/usr/bin/env bash

FRACTONICA_REMOTE_LOCK=/run/lock/fractonica-maintenance.lock.d

fractonica_require_remote_provisioned() {
  local remote="$1"
  if ssh "$remote" 'set -eu
    id -u fractonica-api >/dev/null
    id -u fractonica-web >/dev/null
    getent group fractonica-release >/dev/null
    test -d /opt/fractonica/incoming
    test -d /var/lib/fractonica/media
    test -r /etc/fractonica/api.env
    test -r /etc/fractonica/web.env
    test -x /usr/lib/postgresql/18/bin/psql' >/dev/null 2>&1; then
    return 0
  fi
  cat >&2 <<EOF
The target $remote has not completed Fractonica provisioning.
Run these commands first, then retry this operation:

  rsync -av deployment/fractonica/ $remote:/root/fractonica-deployment/
  ssh $remote '/root/fractonica-deployment/bin/provision-host.sh --apply'
EOF
  return 1
}

fractonica_acquire_remote_lock() {
  local remote="$1" operation="$2"
  ssh "$remote" bash -s -- "$FRACTONICA_REMOTE_LOCK" "$operation" <<'REMOTE'
set -Eeuo pipefail
lock="$1"; operation="$2"
if ! mkdir "$lock" 2>/dev/null; then
  echo "Another Fractonica maintenance operation holds $lock:" >&2
  cat "$lock/owner" >&2 2>/dev/null || true
  exit 1
fi
printf 'operation=%s\npid=%s\nhost=%s\nstarted_at=%s\n' \
  "$operation" "$$" "$(hostname -f)" "$(date -u +%FT%TZ)" > "$lock/owner"
REMOTE
}

fractonica_release_remote_lock() {
  local remote="$1"
  ssh "$remote" "rm -f '$FRACTONICA_REMOTE_LOCK/owner' && rmdir '$FRACTONICA_REMOTE_LOCK'" \
    >/dev/null 2>&1 || true
}
