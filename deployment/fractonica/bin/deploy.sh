#!/usr/bin/env bash
set -Eeuo pipefail

archive="${1:?usage: $0 RELEASE.tar.gz}"
remote="${REMOTE:-root@fractonica.com}"
. "$(dirname "${BASH_SOURCE[0]}")/../lib/maintenance-lock.sh"
fractonica_require_remote_provisioned "$remote"
[[ -f "$archive" && -f "$archive.sha256" ]] || { echo "release and .sha256 are required" >&2; exit 1; }
(cd "$(dirname "$archive")" && shasum -a 256 -c "$(basename "$archive").sha256")
name="$(basename "$archive")"
[[ "$name" =~ ^fractonica-[A-Za-z0-9._-]+-linux-amd64\.tar\.gz$ ]] \
  || { echo "invalid release archive name: $name" >&2; exit 1; }
remote_archive="/opt/fractonica/incoming/$name"
fractonica_acquire_remote_lock "$remote" deploy
trap 'fractonica_release_remote_lock "$remote"' EXIT
rsync -av --partial "$archive" "$remote:$remote_archive"
ssh "$remote" chmod 0600 "$remote_archive"
ssh "$remote" bash -s -- "$remote_archive" --lock-held \
  < "$(dirname "${BASH_SOURCE[0]}")/install-release.sh"
