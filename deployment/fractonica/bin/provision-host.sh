#!/usr/bin/env bash
set -Eeuo pipefail

[[ "${1:-}" == --apply ]] || {
  echo "Usage: sudo $0 --apply [--activate-nginx]" >&2
  echo "Installs PostgreSQL 18/pgvector, creates the service account, secrets, and systemd units." >&2
  exit 2
}
activate_nginx=0
[[ "${2:-}" == --activate-nginx ]] && activate_nginx=1
[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }
base="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. /etc/os-release
[[ "$ID" == ubuntu && "$VERSION_CODENAME" == noble && "$(uname -m)" == x86_64 ]] \
  || { echo "Ubuntu 24.04 x86_64 is required" >&2; exit 1; }
free_kib="$(df -Pk / | awk 'NR==2 {print $4}')"
if [[ -e /etc/fractonica/api.env ]]; then default_min_free_kib=2097152; else default_min_free_kib=11534336; fi
min_free_kib="${MIN_FREE_KIB:-$default_min_free_kib}"
(( free_kib >= min_free_kib )) \
  || { echo "Insufficient disk: provisioning requires $min_free_kib KiB free" >&2; exit 1; }

# Establish swap before package installation on a 1-GiB host. The first-run
# disk gate leaves 8+ GiB free after swap and package installation.
if (( $(awk '/SwapTotal/ {print $2}' /proc/meminfo) < 1048576 )); then
  if [[ ! -e /swapfile-fractonica ]]; then
    fallocate -l "${SWAP_SIZE:-2G}" /swapfile-fractonica
    chmod 0600 /swapfile-fractonica
    mkswap /swapfile-fractonica
  fi
  swapon --show=NAME | grep -qx /swapfile-fractonica || swapon /swapfile-fractonica
  grep -q '^/swapfile-fractonica ' /etc/fstab \
    || printf '%s\n' '/swapfile-fractonica none swap sw 0 0' >> /etc/fstab
fi

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl gnupg locales nginx rsync xz-utils openssl
locale-gen en_US.UTF-8
install -d -m 0755 /usr/share/postgresql-common/pgdg
curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
  | gpg --dearmor --yes -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.gpg
printf '%s\n' \
  'deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.gpg] https://apt.postgresql.org/pub/repos/apt noble-pgdg main' \
  > /etc/apt/sources.list.d/pgdg.list
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  postgresql-18 postgresql-client-18 postgresql-18-pgvector
runuser -u postgres -- psql -v ON_ERROR_STOP=1 -c \
  "ALTER SYSTEM SET listen_addresses TO '127.0.0.1,::1'"
systemctl restart postgresql@18-main.service

getent group fractonica-release >/dev/null || groupadd --system fractonica-release
if ! id fractonica-api >/dev/null 2>&1; then
  useradd --system --user-group --groups fractonica-release \
    --home-dir /var/lib/fractonica --shell /usr/sbin/nologin fractonica-api
else
  usermod -a -G fractonica-release fractonica-api
fi
if ! id fractonica-web >/dev/null 2>&1; then
  useradd --system --user-group --groups fractonica-release \
    --home-dir /var/lib/fractonica-web --shell /usr/sbin/nologin fractonica-web
else
  usermod -a -G fractonica-release fractonica-web
fi
install -d -o root -g fractonica-release -m 0750 /opt/fractonica/{incoming,releases,shared}
install -d -o fractonica-api -g fractonica-api -m 0700 /var/lib/fractonica/media
install -d -o root -g root -m 0755 /etc/fractonica

new_api_env=0
if [[ -e /etc/fractonica/api.env ]]; then
  db_password="$(sed -n 's#^DATABASE_URL=postgresql://fractonica:\([^@]*\)@127\.0\.0\.1:5432/fractonica$#\1#p' /etc/fractonica/api.env)"
  [[ -n "$db_password" ]] || { echo "Cannot safely read the existing database password" >&2; exit 1; }
else
  db_password="$(openssl rand -hex 32)"
  new_api_env=1
fi
if ! runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='fractonica'" | grep -q 1; then
  runuser -u postgres -- createuser --no-createdb --no-createrole --no-superuser fractonica
  runuser -u postgres -- psql -v ON_ERROR_STOP=1 \
    -c "ALTER ROLE fractonica LOGIN PASSWORD '$db_password'"
elif (( new_api_env )); then
  runuser -u postgres -- psql -v ON_ERROR_STOP=1 \
    -c "ALTER ROLE fractonica LOGIN PASSWORD '$db_password'"
fi
if ! runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_database WHERE datname='fractonica'" | grep -q 1; then
  runuser -u postgres -- createdb --owner=fractonica --encoding=UTF8 \
    --locale-provider=libc --lc-collate=en_US.utf8 --lc-ctype=en_US.utf8 \
    --template=template0 fractonica
fi
runuser -u postgres -- psql -v ON_ERROR_STOP=1 -d fractonica \
  -c 'CREATE EXTENSION IF NOT EXISTS vector'
vector_version="$(runuser -u postgres -- psql -At -d fractonica -c "SELECT extversion FROM pg_extension WHERE extname='vector'")"
dpkg --compare-versions "$vector_version" ge 0.8 \
  || { echo "pgvector >= 0.8 is required; found $vector_version" >&2; exit 1; }

if (( new_api_env )); then
  jwt_key="$(openssl genpkey -algorithm ED25519 -outform DER | base64 -w 0)"
  umask 077
  {
    echo "DATABASE_URL=postgresql://fractonica:$db_password@127.0.0.1:5432/fractonica"
    echo "AUTH_JWT_PRIVATE_KEY_BASE64=$jwt_key"
    echo 'AUTH_JWT_ISSUER=fractonica-api'
    echo 'AUTH_JWT_AUDIENCE=fractonica-clients'
    echo 'AUTH_JWT_KEY_ID=primary'
    echo 'AUTH_REGISTRATION_MODE=closed'
    echo 'AUTH_ARGON2_MAX_CONCURRENCY=1'
    echo 'TRUST_PROXY_HOPS=1'
    echo 'DB_POOL_MAX=5'
    echo 'LOG_LEVEL=info'
  } > /etc/fractonica/api.env
fi
if [[ ! -e /etc/fractonica/web.env ]]; then
  umask 077
  {
    echo 'API_BASE_URL=http://127.0.0.1:8788'
    echo "SESSION_SECRET=$(openssl rand -hex 48)"
  } > /etc/fractonica/web.env
fi
chown root:fractonica-api /etc/fractonica/api.env
chown root:fractonica-web /etc/fractonica/web.env
chmod 0640 /etc/fractonica/*.env
export PGPASSWORD="$db_password"
runuser --preserve-environment -u fractonica-api -- \
  /usr/lib/postgresql/18/bin/psql -h 127.0.0.1 -U fractonica -d fractonica \
  -Atqc 'SELECT 1' | grep -qx 1 \
  || { unset PGPASSWORD; echo "generated DATABASE_URL password failed authentication" >&2; exit 1; }
unset PGPASSWORD
if ss -ltnH | awk '$4 ~ /:5432$/ {print $4}' \
  | grep -Ev '^(127\.0\.0\.1|\[::1\]):5432$' | grep -q .; then
  echo "PostgreSQL is listening beyond loopback" >&2; exit 1
fi

install -o root -g root -m 0644 "$base/systemd/fractonica-api.service" /etc/systemd/system/
install -o root -g root -m 0644 "$base/systemd/fractonica-web.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable fractonica-api.service fractonica-web.service

if (( activate_nginx )); then
  available=/etc/nginx/sites-available/fractonica.com
  enabled=/etc/nginx/sites-enabled/fractonica.com
  candidate="${available}.candidate"
  backup="${available}.before-$(date -u +%Y%m%dT%H%M%SZ)"
  previous_target="$(readlink "$enabled" 2>/dev/null || true)"
  install -o root -g root -m 0644 "$base/nginx/fractonica.conf" "$candidate"
  ln -sfn "$candidate" "$enabled"
  if ! nginx -t; then
    if [[ -n "$previous_target" ]]; then ln -sfn "$previous_target" "$enabled"; else rm -f "$enabled"; fi
    rm -f "$candidate"
    echo "nginx candidate failed validation; the active link was restored" >&2
    exit 1
  fi
  [[ ! -e "$available" ]] || cp -a "$available" "$backup"
  mv "$candidate" "$available"
  ln -sfn "$available" "$enabled"
  if ! nginx -t; then
    [[ ! -e "$backup" ]] || cp -a "$backup" "$available"
    if [[ -n "$previous_target" ]]; then ln -sfn "$previous_target" "$enabled"; else rm -f "$enabled"; fi
    echo "nginx validation failed after install; the prior config was restored" >&2
    exit 1
  fi
  systemctl reload nginx
else
  echo "nginx config was not activated; review $base/nginx/fractonica.conf first"
fi
echo "provisioning complete; secrets are in /etc/fractonica and were not printed"
