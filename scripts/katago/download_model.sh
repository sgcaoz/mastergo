#!/usr/bin/env bash
# Download the bundled KataGo network into assets/models/katago/standard.bin.gz
# and print sha256. Required at app build time (the file is gitignored).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
DEST_DIR="$ROOT_DIR/assets/models/katago"
DEST_FILE="$DEST_DIR/standard.bin.gz"
# Small transformer (tf2-b10c384). Requires KataGo >= 1.17.
SOURCE_URL="${KATAGO_MODEL_URL:-https://media.katagotraining.org/uploaded/networks/models/kata1/kata1-tf2-b10c384-s2941M-d5872M.bin.gz}"

mkdir -p "$DEST_DIR"
echo "==> Downloading $SOURCE_URL"
curl -L --fail --retry 3 -o "$DEST_FILE" "$SOURCE_URL"
echo "==> Saved $DEST_FILE ($(du -h "$DEST_FILE" | awk '{print $1}'))"
shasum -a 256 "$DEST_FILE"
