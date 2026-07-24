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
Nginx routes `/v1`, health, OpenAPI, and Swagger to the API, with other paths
going to web. The template names only `fractonica.com` because the current
certificate has no `www` SAN. HSTS omits `includeSubDomains` because not every
existing subdomain is HTTPS-only.

## Production shape

The small 1-vCPU production target is deliberately not used for image builds or
a duplicate container stack. `build-release.sh` builds Linux/amd64 locally in pinned Node
24.18.0, then ships the Node binary, Linux-native dependencies, compiled API,
SSR build, migrations, OpenAPI, and a per-file SHA-256 manifest. Production
never runs `npm install` or a compiler.

PostgreSQL stays major-version aligned with the PostgreSQL 18 source. Never
restore this database into PostgreSQL 16; `pg_dump` is not a downgrade tool.
Provisioning installs `postgresql-18`, `postgresql-client-18`, and
`postgresql-18-pgvector` from PGDG and rejects pgvector older than 0.8.

## Safety prerequisites

1. Expand the root filesystem until at least 11 GiB is free before first
   provisioning. Provisioning allocates 2 GiB of swap before installing
   packages, leaving the 8-GiB post-provision migration gate intact. Long-term,
   use at least 20 GiB. Migration and rollback temporarily need two media trees.
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

Provisioning must finish before migration, restore, deploy, or backup. Those
commands now verify the service accounts, directories, secrets, and PostgreSQL
client first and print the provisioning command when the host is incomplete.
An older script reporting `install: invalid user 'fractonica-api'` means this
one-time provisioning step was skipped or interrupted; rerun it safely.

Registration defaults to `closed`. Change `/etc/fractonica/api.env` to invite
or open registration only when intended.

## First Mac-to-Linux migration

1. Stop the local API and every client/agent that can write.
2. Confirm the local PostgreSQL 18 Compose service is healthy.
3. Provision the target, but do not deploy/start Fractonica yet.
4. Run:

   ```sh
   REMOTE=root@fractonica.com \
     deployment/fractonica/bin/migrate-first.sh --apply --source-quiesced
   ```

The script creates a PostgreSQL custom dump, checks the target is empty,
restores into a temporary DB, validates pgvector, and swaps the DB and staged
media into place. It never deletes source data. A non-empty target is refused;
use the restore workflow in that case.

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

Deployment verifies outer and inner checksums, runs checksum-protected SQL
migrations under the advisory lock, atomically switches `current`, restarts the
services, and requires API readiness plus a web response. A failed gate restores
the previous code symlink. SQL is forward-only, so migrations must use
expand/contract sequencing and remain compatible with the previous release.

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

Copy each backup to a second independent encrypted location. Test restores regularly:

```sh
REMOTE=root@fractonica.com \
  deployment/fractonica/bin/restore-to-host.sh --apply /path/to/verified/backup
```

Restore verifies manifests, stages database and media, swaps both, then runs
health checks. A failed health gate swaps the previous DB and media back. It
requires enough free disk for both media trees.

Deploy, first migration, backup, and restore share the atomic lock directory
`/run/lock/fractonica-maintenance.lock.d`; they cannot overlap. The lock normally
clears through a trap and also disappears on reboot because `/run` is volatile.
If a killed workstation leaves it stale, first verify that no maintenance
process or transfer is active, inspect its `owner` file, then remove only that
directory before retrying:

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
- Never modify an applied SQL migration. Add a new numbered migration; the
  runner rejects changed or missing history.
