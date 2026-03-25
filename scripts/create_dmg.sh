#!/usr/bin/env bash
set -euo pipefail

# Creates a signed DMG from the installed app bundle.
# Usage: ./scripts/create_dmg.sh [app_path] [output_dir]

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${1:-/Applications/Muesli.app}"
OUTPUT_DIR="${2:-$ROOT/dist-release}"
SIGN_IDENTITY="${MUESLI_SIGN_IDENTITY:-Developer ID Application: Lyon Cubs, LLC (PBHS7U4BMU)}"

if [[ ! -d "$APP_PATH" ]]; then
  echo "App not found: $APP_PATH" >&2
  exit 1
fi

# Extract version from Info.plist
VERSION=$(defaults read "$APP_PATH/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "0.0.0")
APP_NAME=$(defaults read "$APP_PATH/Contents/Info" CFBundleDisplayName 2>/dev/null || echo "Muesli")
DMG_NAME="${APP_NAME}-${VERSION}.dmg"

mkdir -p "$OUTPUT_DIR"
DMG_PATH="$OUTPUT_DIR/$DMG_NAME"
TEMP_DMG="$OUTPUT_DIR/_temp_${DMG_NAME}"

# Clean up any previous DMG
rm -f "$DMG_PATH" "$TEMP_DMG"

echo "Creating DMG: $DMG_NAME"

# Create temp directory for DMG contents
STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT

cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

# Create writable DMG
hdiutil create -volname "$APP_NAME" \
  -srcfolder "$STAGING" \
  -ov -format UDRW \
  "$TEMP_DMG"

# Convert to compressed read-only DMG
hdiutil convert "$TEMP_DMG" -format UDZO -o "$DMG_PATH"
rm -f "$TEMP_DMG"

# Sign the DMG
codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH"

echo "DMG created: $DMG_PATH ($(du -sh "$DMG_PATH" | cut -f1))"
echo "Signed with: $SIGN_IDENTITY"
