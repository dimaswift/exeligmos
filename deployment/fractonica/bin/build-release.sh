#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
out="${OUTPUT_DIR:-$root/output/releases}"
revision="$(git -C "$root" rev-parse HEAD)"
release_id="${RELEASE_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$(git -C "$root" rev-parse --short=12 HEAD)}"

command -v docker >/dev/null || { echo "docker is required" >&2; exit 1; }
command -v rsync >/dev/null || { echo "rsync is required" >&2; exit 1; }
if [[ "${ALLOW_DIRTY:-0}" != 1 ]] && [[ -n "$(git -C "$root" status --porcelain)" ]]; then
  echo "Refusing to release a dirty worktree. Commit it or set ALLOW_DIRTY=1 for a non-production build." >&2
  exit 1
fi

work="$(mktemp -d)"
image="fractonica-release:$release_id"
container=""
cleanup() {
  [[ -z "$container" ]] || docker rm -f "$container" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

mkdir -p "$work/context" "$work/release" "$out"
cp "$root/deployment/fractonica/release.Dockerfile.dockerignore" \
  "$work/context/.dockerignore"
rsync -a --exclude node_modules --exclude dist --exclude var --exclude data --exclude '.env*' \
  "$root/sync-server/" "$work/context/sync-server/"
rsync -a --exclude node_modules --exclude build --exclude .react-router --exclude '.env*' \
  "$root/web/" "$work/context/web/"
rsync -a --exclude node_modules "$root/domain-spec/" "$work/context/domain-spec/"
mkdir -p "$work/context/SarosHarmonicJournal/Resources"
rsync -a "$root/SarosHarmonicJournal/Resources/SolarData/" \
  "$work/context/SarosHarmonicJournal/Resources/SolarData/"
rsync -a "$root/SarosHarmonicJournal/Resources/SolarGeoData/" \
  "$work/context/SarosHarmonicJournal/Resources/SolarGeoData/"

docker build --platform linux/amd64 --pull \
  --build-arg "RELEASE_ID=$release_id" \
  --build-arg "SOURCE_REVISION=$revision" \
  -f "$root/deployment/fractonica/release.Dockerfile" \
  -t "$image" "$work/context"
container="$(docker create --platform linux/amd64 "$image")"
docker cp "$container:/release/." "$work/release/"
(cd "$work/release" && shasum -a 256 --status -c RELEASE.sha256)
echo "release manifest verified"

archive="$out/fractonica-$release_id-linux-amd64.tar.gz"
tar -C "$work/release" -czf "$archive" .
(cd "$out" && shasum -a 256 "$(basename "$archive")" > "$(basename "$archive").sha256")
printf '%s\n' "$archive"
