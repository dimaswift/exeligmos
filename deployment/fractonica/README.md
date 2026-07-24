# Fractonica production deployment

This directory is the production contract for the Ubuntu host. It separates the
database, media, immutable releases, secrets, and off-host backups:

| Asset | Production location |
| --- | --- |
| PostgreSQL 18 + pgvector | native PGDG cluster |
| Immutable media | `/var/lib/fractonica/media` (`fractonica-api` only) |
| Immutable releases | `/opt/fractonica/releases/<release-id>` |
| Active release | `/opt/fractonica/current` symlink |
| Secrets | `/etc/fractonica/{api,web}.env` |
| Public edge | existing nginx + Certbot |

The API binds only to `127.0.0.1:8788`; SSR web binds to
`127.0.0.1:3100`. Port 3000 and `/opt/saros-api` are intentionally untouched.
Nginx routes the API resource prefixes, health, OpenAPI, and Swagger to the API,
with other paths going to web. The template names only `fractonica.com` because
the current certificate has no `www` SAN. HSTS omits `includeSubDomains`
because not every existing subdomain is HTTPS-only.

## Production shape

The small 1-vCPU production target is deliberately not used for image builds or
a duplicate container stack. `build-release.sh` builds Linux/amd64 locally in pinned Node
24.18.0, then ships the Node binary, Linux-native dependencies, compiled API,
SSR build, canonical schema, OpenAPI, and a per-file SHA-256 manifest. Production
never runs `npm install` or a compiler.

PostgreSQL stays major-version aligned with the PostgreSQL 18 source. Never
restore this database into PostgreSQL 16; `pg_dump` is not a downgrade tool.
Provisioning installs `postgresql-18`, `postgresql-client-18`, and
`postgresql-18-pgvector` from PGDG and rejects pgvector older than 0.8.

## Safety prerequisites

1. Expand the root filesystem until at least 11 GiB is free before first
   provisioning. Provisioning allocates 2 GiB of swap before installing
   packages. Long-term, use at least 20 GiB; restore temporarily needs two media
   trees.
2. Keep SSH key-only. Never copy the private key into this repo or an env file.
3. Run the read-only audit:

   ```sh
   REMOTE=root@fractonica.com deployment/fractonica/bin/host-preflight.sh
   ```

4. Take a provider snapshot before replacing the existing site. Provisioning
   also backs up `/etc/nginx/sites-available/fractonica.com` before activation.

## One-time provisioning

Copy this directory to a fixed root-only host path, review it, and run:

```sh
rsync -av deployment/fractonica/ root@fractonica.com:/root/fractonica-deployment/
ssh root@fractonica.com '/root/fractonica-deployment/bin/provision-host.sh --apply'
```

It installs PGDG PostgreSQL 18/pgvector, creates isolated `fractonica-api` and
`fractonica-web` users plus a read-only release group, adds swap when required,
writes fresh DB/JWT/session secrets, and installs
hardened systemd units. Re-running it does not rotate existing secrets.

Provisioning must finish before restore, deploy, or backup. Those
commands now verify the service accounts, directories, secrets, and PostgreSQL
client first and print the provisioning command when the host is incomplete.
An older script reporting `install: invalid user 'fractonica-api'` means this
one-time provisioning step was skipped or interrupted; rerun it safely.

Registration defaults to `closed`. Change `/etc/fractonica/api.env` to invite
or open registration only when intended.

## Release pipeline

Build from a committed clean worktree:

```sh
deployment/fractonica/bin/build-release.sh
```

`ALLOW_DIRTY=1` is only for staging diagnostics. Deploy the emitted archive:

```sh
REMOTE=root@fractonica.com \
  deployment/fractonica/bin/deploy.sh output/releases/fractonica-<id>-linux-amd64.tar.gz
```

Deployment verifies outer and inner checksums, checks the canonical database
shape, atomically switches `current`, restarts the services, and requires API
readiness plus a web response. On the first deploy, `db/schema.sql` is applied
to the empty database; a nonempty database with a different shape is rejected.
A failed health gate restores the previous code symlink.

Verification:

```sh
ssh root@fractonica.com 'systemctl status fractonica-api fractonica-web --no-pager'
ssh root@fractonica.com 'journalctl -u fractonica-api -u fractonica-web -n 100 --no-pager'
ssh root@fractonica.com 'curl -fsS http://127.0.0.1:8788/health/ready && curl -fsS http://127.0.0.1:3100/'
```

Only after both services pass their loopback health gates, review and activate
the public nginx route. Activating it earlier would replace the existing site
with a 502 response:

```sh
ssh root@fractonica.com 'diff -u /etc/nginx/sites-available/fractonica.com /root/fractonica-deployment/nginx/fractonica.conf || true'
ssh root@fractonica.com '/root/fractonica-deployment/bin/provision-host.sh --apply --activate-nginx'
curl -fsS https://fractonica.com/health/ready
curl -fsS https://fractonica.com/openapi.yaml >/dev/null
curl -fsS https://fractonica.com/ >/dev/null
```

## Backups and restore drills

Backups are pulled off-host. They contain account hashes, metadata, and media,
so the script requires an explicit encrypted-at-rest destination (for example a
FileVault-protected disk or encrypted APFS volume). It performs a live warm media
copy, briefly stops API writes, streams a custom DB dump, then performs a final
checksummed media delta before restarting:

```sh
REMOTE=root@fractonica.com \
  deployment/fractonica/bin/backup-to-local.sh --apply \
    --destination-is-encrypted /Volumes/EncryptedBackup/fractonica/$(date +%F)
```

To package the same restorable snapshot as one compressed artifact, add
`--compress` and use a new `.tar.gz` path:

```sh
REMOTE=root@fractonica.com \
  deployment/fractonica/bin/backup-to-local.sh --apply \
    --destination-is-encrypted \
    /Volumes/EncryptedBackup/fractonica/fractonica-$(date +%F).tar.gz \
    --compress
```

Copy each backup to a second independent encrypted location. Test restores regularly:

```sh
REMOTE=root@fractonica.com \
  deployment/fractonica/bin/restore-to-host.sh --apply /path/to/verified/backup
```

The restore command accepts either the unpacked backup directory or the
compressed `.tar.gz`. Restore verifies outer and inner manifests, stages
database and media, swaps both, then runs health checks. A failed health gate
swaps the previous DB and media back. It requires enough free disk for both
media trees.

### Human-readable archives

A readable archive has the opposite purpose from a backup: it is not
restorable, contains no SQL dump, and omits credentials and operational state.
Its records, events, catalogs, and media are plain folders and JSON, plus a
dependency-free static explorer at the unpacked root:

```sh
REMOTE=root@fractonica.com \
  deployment/fractonica/bin/archive-to-local.sh --apply \
    --destination-is-encrypted \
    /Volumes/EncryptedBackup/fractonica/fractonica-readable-$(date +%F).tar.gz
```

After unpacking, open `index.html` directly or run any static server in the
archive root, such as `python3 -m http.server 8000`. The production archive
command uses the maintenance lock, stops API writes during its database/media
snapshot, verifies media bytes and checksums, restarts and health-checks the API,
then transfers the `.tar.gz` and a matching `.sha256` sidecar. Private content
remains ciphertext because the server does not hold user decryption keys.

Deploy, backup, readable archive, and restore share the atomic
lock directory `/run/lock/fractonica-maintenance.lock.d`; they cannot overlap.
The lock normally clears through a trap and also disappears on reboot because
`/run` is volatile. If a killed workstation leaves it stale, first verify that
no maintenance process or transfer is active, inspect its `owner` file, then
remove only that directory before retrying:

```sh
ssh root@fractonica.com 'cat /run/lock/fractonica-maintenance.lock.d/owner'
ssh root@fractonica.com 'rm /run/lock/fractonica-maintenance.lock.d/owner && rmdir /run/lock/fractonica-maintenance.lock.d'
```

## Operational policy

- Never commit env files, dumps, media, JWT keys, or session secrets.
- Back up JWT and session secrets in a password manager. Changing them
  invalidates tokens or browser sessions respectively.
- Keep `TRUST_PROXY_HOPS=1` while nginx is the only proxy.
- Expose only 22/80/443. PostgreSQL and application ports stay on loopback.
- Monitor disk, swap, PostgreSQL, systemd restart counts, `/health/ready`, and
  off-host backup age. Pause large media uploads at 80% disk utilization.
- Treat `sync-server/db/schema.sql` as the single database definition. Create a
  fresh database whenever that definition changes.
