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

# Bun --compile cannot bundle .node native addons — they must ship on disk.
# Copy the libsql arm64 addon to a sibling directory the dlopen shim looks at
# (path.dirname(process.execPath)/native_modules/@libsql/<target>/index.node).
NATIVE_MOD_DIR="dist/native_modules/@libsql/darwin-arm64"
mkdir -p "$NATIVE_MOD_DIR"
cp node_modules/@libsql/darwin-arm64/index.node "$NATIVE_MOD_DIR/index.node"

echo "Built muesli-agent at dist/muesli-agent ($(uname -m))"
echo "  Sideloaded native addon at $NATIVE_MOD_DIR/index.node"
# v1 ships arm64 only; the libsql native addon is platform-specific and Bun's
# --compile flow does not yet bundle a cross-arch addon. Intel Mac support
# will require producing a separate binary on an x64 host with the matching
# @libsql/darwin-x64 addon installed, then lipo-merging.
