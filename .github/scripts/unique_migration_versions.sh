#!/usr/bin/env bash
# Bilimbi refuses a mounted graph in which two migrations share a version
# (MixDiscovery.validate_unique_migration_versions!). Check Finance's modules
# against each other here, without a Bilimbi checkout, so a collision between
# modules fails fast with the files that clash.
set -euo pipefail

cd "$(dirname "$0")/../.."

migrations=$(find . -mindepth 5 -maxdepth 5 -path './*/priv/repo/migrations/*.exs' | sort)
duplicates=$(printf '%s\n' "$migrations" | sed -n 's#^.*/\([0-9]\{1,\}\)_[^/]*$#\1#p' | sort | uniq -d)

if [ -n "$duplicates" ]; then
  echo "Duplicate migration versions across Finance modules:" >&2
  for version in $duplicates; do
    printf '%s\n' "$migrations" | grep "/${version}_" | sed 's#^\./#  #' >&2
  done
  exit 1
fi

echo "Migration versions are unique across Finance modules."
