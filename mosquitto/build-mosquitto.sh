#!/usr/bin/env bash
# Build static mosquitto_pub and mosquitto_sub binaries for Linux x86_64.
# Requires Docker. Outputs binaries to ../source/usr/local/bin/.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VERSION_FILE="$SCRIPT_DIR/MOSQUITTO_VERSION"
OUT_DIR="$SCRIPT_DIR/../source/usr/local/bin"

VERSION="${MOSQUITTO_VERSION:-$(cat "$VERSION_FILE" | tr -d '[:space:]')}"

echo "Building static mosquitto ${VERSION} for linux/amd64..."

docker build \
  --platform linux/amd64 \
  --build-arg "MOSQUITTO_VERSION=${VERSION}" \
  --tag "mosquitto-static-builder:${VERSION}" \
  "$SCRIPT_DIR"

mkdir -p "$OUT_DIR"

CONTAINER=$(docker create --platform linux/amd64 "mosquitto-static-builder:${VERSION}")
docker cp "${CONTAINER}:/usr/local/bin/mosquitto_pub" "$OUT_DIR/mosquitto_pub"
docker cp "${CONTAINER}:/usr/local/bin/mosquitto_sub" "$OUT_DIR/mosquitto_sub"
docker rm "$CONTAINER"

chmod +x "$OUT_DIR/mosquitto_pub" "$OUT_DIR/mosquitto_sub"

echo "Done:"
ls -lh "$OUT_DIR/mosquitto_pub" "$OUT_DIR/mosquitto_sub"
