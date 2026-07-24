#!/usr/bin/env bash
set -Eeuo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sync_server_directory="$(dirname "$script_directory")"

# Change this value to choose where complete readable archives are stored.
archive_parent_directory="/Volumes/T7 Shield/EXELIGMOS/archives"

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
destination="$archive_parent_directory/archive-$stamp"

mkdir -p "$archive_parent_directory"
cd "$sync_server_directory"
npm run archive -- --output "$destination"

echo
echo "Archive ready: $destination"
echo "Serve it with: python3 -m http.server 8000 --directory '$destination'"
