#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

if ! command -v bun >/dev/null 2>&1; then
  echo "bun not found on PATH — install from https://bun.sh" >&2
  exit 1
fi

bun install --frozen-lockfile || bun install

mkdir -p dist

bun build src/index.ts --compile --outfile=dist/muesli-agent
echo "Built muesli-agent at dist/muesli-agent ($(uname -m))"
# v1 ships arm64 only; the embedded libsql native addon is platform-specific
# and Bun's --compile flow does not yet bundle a cross-arch addon cleanly.
# Intel Mac support will require producing a separate binary on an x64 host
# (or with an x64-installed @libsql/darwin-x64) and lipo-merging.
