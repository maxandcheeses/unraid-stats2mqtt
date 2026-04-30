#!/bin/bash
# =============================================================================
# build.sh - Package the unraid-stats2mqtt plugin for distribution
# Creates the .txz source package and updates the .plg file
# Run this on a build machine, not on Unraid itself
# =============================================================================

set -euo pipefail

PLUGIN="unraid-stats2mqtt"
BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_FILE="$BUILD_DIR/BUILD"
if [ -z "${VERSION:-}" ]; then
  BUILD=$(( $(cat "$BUILD_FILE" 2>/dev/null || echo 0) + 1 ))
  echo "$BUILD" > "$BUILD_FILE"
  VERSION="$(date '+%Y.%m').$BUILD"
fi
SOURCE_DIR="$BUILD_DIR/source"
OUT_DIR="$BUILD_DIR/dist"

echo "Building $PLUGIN v$VERSION..."

mkdir -p "$OUT_DIR"

# ── Write version file into source ───────────────────────────────────────────
echo "$VERSION" > "$SOURCE_DIR/usr/local/emhttp/plugins/${PLUGIN}/version"

# ── Create the .txz package from source/ ──────────────────────────────────────
TXZ_FILE="$OUT_DIR/${PLUGIN}-${VERSION}-x86_64-1.txz"
cd "$SOURCE_DIR"
tar -cJf "$TXZ_FILE" .
echo "Created: $TXZ_FILE"

# ── Compute MD5 ───────────────────────────────────────────────────────────────
MD5=$(md5sum "$TXZ_FILE" | cut -d' ' -f1)
echo "MD5: $MD5"

# ── Update .plg with version and MD5 ─────────────────────────────────────────
PLG_SRC="$BUILD_DIR/plugin/${PLUGIN}.plg"
PLG_DST="$OUT_DIR/${PLUGIN}.plg"
sed "s/&version;/$VERSION/g" "$PLG_SRC" > "$PLG_DST"
echo "PLG written: $PLG_DST"

echo ""
echo "Done. Upload these files to your GitHub release:"
echo "  $TXZ_FILE"
echo "  $PLG_DST"
echo ""
echo "Then install on Unraid via: Plugins > Install Plugin > paste raw .plg URL"
