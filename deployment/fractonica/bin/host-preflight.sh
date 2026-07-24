#!/usr/bin/env bash
set -Eeuo pipefail

remote="${REMOTE:-root@fractonica.com}"
min_free_kib="${MIN_FREE_KIB:-8388608}"
min_swap_kib="${MIN_SWAP_KIB:-1048576}"

ssh -o BatchMode=yes -o ConnectTimeout=10 "$remote" bash -s -- "$min_free_kib" "$min_swap_kib" <<'REMOTE'
set -Eeuo pipefail
min_free_kib="$1"
min_swap_kib="$2"
[[ "$(uname -m)" == x86_64 ]] || { echo "ERROR: x86_64 host required"; exit 1; }
. /etc/os-release
[[ "$ID" == ubuntu && "$VERSION_CODENAME" == noble ]] || {
  echo "ERROR: this target profile requires Ubuntu 24.04 noble"; exit 1;
}
free_kib="$(df -Pk / | awk 'NR==2 {print $4}')"
swap_kib="$(awk '/SwapTotal/ {print $2}' /proc/meminfo)"
memory_kib="$(awk '/MemTotal/ {print $2}' /proc/meminfo)"
printf 'host=%s os=%s arch=%s memory_kib=%s swap_kib=%s free_kib=%s\n' \
  "$(hostname -f)" "$PRETTY_NAME" "$(uname -m)" "$memory_kib" "$swap_kib" "$free_kib"
if [[ ! -e /etc/fractonica/api.env ]] && (( min_free_kib < 11534336 )); then
  min_free_kib=11534336
fi
(( free_kib >= min_free_kib )) || {
  echo "ERROR: at least $min_free_kib KiB free is required before deployment"; exit 1;
}
if (( swap_kib < min_swap_kib )); then
  if [[ -e /etc/fractonica/api.env ]]; then
    echo "ERROR: at least $min_swap_kib KiB swap is required on this small host"; exit 1
  fi
  echo "WARNING: provisioning must create at least $min_swap_kib KiB swap"
fi
for port in 8788 3100; do
  if ss -ltnH "sport = :$port" | grep -q .; then
    echo "ERROR: loopback port $port is already in use"; exit 1
  fi
done
test -r /etc/letsencrypt/live/fractonica.com/fullchain.pem \
  || echo "WARNING: fractonica.com TLS certificate is not installed"
command -v nginx >/dev/null && nginx -v 2>&1 || true
command -v psql >/dev/null && psql --version || true
echo "preflight=ok"
REMOTE
