#!/usr/bin/env bash
set -Eeuo pipefail

[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }
archive="${1:?release archive path required}"
[[ -f "$archive" ]] || { echo "missing archive: $archive" >&2; exit 1; }
lock=/run/lock/fractonica-maintenance.lock.d
owns_lock=0
if [[ "${2:-}" != --lock-held ]]; then
  mkdir "$lock" 2>/dev/null || { cat "$lock/owner" >&2 2>/dev/null || true; exit 1; }
  printf 'operation=install-release\npid=%s\nhost=%s\nstarted_at=%s\n' \
    "$$" "$(hostname -f)" "$(date -u +%FT%TZ)" > "$lock/owner"
  owns_lock=1
fi
release_lock() {
  (( owns_lock == 0 )) || { rm -f "$lock/owner"; rmdir "$lock"; }
}
trap release_lock EXIT
work="$(mktemp -d /opt/fractonica/incoming/release.XXXXXX)"
cleanup_work() { rm -rf "$work"; release_lock; }
trap cleanup_work EXIT
tar -C "$work" -xzf "$archive"
(cd "$work" && sha256sum --quiet -c RELEASE.sha256)
echo "release manifest verified"
release_id="$(<"$work/RELEASE_ID")"
[[ "$release_id" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "invalid release id" >&2; exit 1; }
destination="/opt/fractonica/releases/$release_id"
[[ ! -e "$destination" ]] || { echo "release already installed: $release_id" >&2; exit 1; }
mv "$work" "$destination"
trap release_lock EXIT
chown -R root:fractonica-release "$destination"
find "$destination" -type d -exec chmod 0750 {} +
find "$destination" -type f -exec chmod 0640 {} +
chmod 0750 "$destination/runtime/node"

api_was_active=0
web_was_active=0
systemctl is-active --quiet fractonica-api.service && api_was_active=1
if systemctl is-active --quiet fractonica-web.service; then
  web_was_active=1
fi
cutover_pending=0
previous=""
finish_install() {
  status=$?
  trap - EXIT
  if (( status != 0 && cutover_pending )); then
    if [[ -n "$previous" ]]; then
      if ! ln -sfn "$previous" /opt/fractonica/current.rollback \
        || ! mv -Tf /opt/fractonica/current.rollback /opt/fractonica/current; then
        echo "CRITICAL: failed to restore the previous release symlink" >&2
      fi
    else
      rm -f /opt/fractonica/current \
        || echo "CRITICAL: failed to remove the unverified first-release symlink" >&2
    fi
    if (( api_was_active )); then
      systemctl restart fractonica-api.service \
        || echo "CRITICAL: failed to restart the previous API release" >&2
    else
      systemctl stop fractonica-api.service 2>/dev/null || true
    fi
    if (( web_was_active )); then
      systemctl restart fractonica-web.service \
        || echo "CRITICAL: failed to restart the previous web release" >&2
    else
      systemctl stop fractonica-web.service 2>/dev/null || true
    fi
    echo "release cutover exited before health acceptance; previous service state was restored" >&2
  fi
  release_lock
  exit "$status"
}
trap finish_install EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

previous="$(readlink -f /opt/fractonica/current 2>/dev/null || true)"
runuser -u fractonica-api -- bash -c '
  set -Eeuo pipefail
  set -a
  . /etc/fractonica/api.env
  set +a
  exec "$1" --enable-source-maps "$2"
' -- "$destination/runtime/node" "$destination/api/dist/db/setup.js"
systemctl stop fractonica-api.service fractonica-web.service
ln -sfn "$destination" /opt/fractonica/current.next
cutover_pending=1
mv -Tf /opt/fractonica/current.next /opt/fractonica/current
systemctl restart fractonica-api.service fractonica-web.service

ready=0
for _ in {1..30}; do
  if curl -fsS http://127.0.0.1:8788/health/ready >/dev/null \
    && curl -fsS 'http://127.0.0.1:8788/public/records?limit=1' >/dev/null \
    && curl -fsS http://127.0.0.1:3100/ >/dev/null; then
    ready=1; break
  fi
  sleep 1
done
if (( ! ready )); then
  echo "release failed health checks; the EXIT guard will roll back the code symlink" >&2
  exit 1
fi
cutover_pending=0
rm -f "$archive"
mapfile -t installed_releases < <(find /opt/fractonica/releases -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' | sort -nr | cut -d' ' -f2-)
for ((index = 3; index < ${#installed_releases[@]}; index += 1)); do
  [[ "$(readlink -f /opt/fractonica/current)" == "${installed_releases[index]}" ]] \
    || rm -rf -- "${installed_releases[index]}"
done
echo "installed release $release_id"
