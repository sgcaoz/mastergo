#!/usr/bin/env bash
# Pin third_party/KataGo to the version in scripts/katago/VERSION and apply
# MasterGo overlays (iOS in-process analysis lib). Safe to re-run.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
KATAGO_SRC="$ROOT_DIR/third_party/KataGo"
OVERLAY_DIR="$(cd "$(dirname "$0")" && pwd)"
KATAGO_TAG="$(tr -d '[:space:]' < "$OVERLAY_DIR/VERSION")"

if [[ -z "$KATAGO_TAG" ]]; then
  echo "error: scripts/katago/VERSION is empty" >&2
  exit 1
fi

mkdir -p "$(dirname "$KATAGO_SRC")"
if [[ ! -d "$KATAGO_SRC/.git" ]]; then
  git clone https://github.com/lightvector/KataGo.git "$KATAGO_SRC"
fi

echo "==> Pinning KataGo to $KATAGO_TAG"
git -C "$KATAGO_SRC" fetch --tags --force origin
git -C "$KATAGO_SRC" checkout --force --detach "$KATAGO_TAG"
git -C "$KATAGO_SRC" clean -fd -- cpp >/dev/null

echo "==> Applying MasterGo analysis-lib overlay"
cp "$OVERLAY_DIR/overlay/katago_analysis_lib.cpp" "$KATAGO_SRC/cpp/katago_analysis_lib.cpp"
cp "$OVERLAY_DIR/overlay/katago_analysis_version_stub.cpp" "$KATAGO_SRC/cpp/katago_analysis_version_stub.cpp"
cp "$OVERLAY_DIR/overlay/katago_analysis_lib.cmake" "$KATAGO_SRC/cpp/katago_analysis_lib.cmake"

if ! grep -q 'katago_analysis_lib.cmake' "$KATAGO_SRC/cpp/CMakeLists.txt"; then
  printf '\ninclude(${CMAKE_CURRENT_LIST_DIR}/katago_analysis_lib.cmake)\n' >> "$KATAGO_SRC/cpp/CMakeLists.txt"
fi

# Patches are generated against the pinned tag; skip if already applied.
if grep -q 'MasterGo: library-mode stdin/stdout callbacks' "$KATAGO_SRC/cpp/command/analysis.cpp"; then
  echo "==> analysis.cpp already patched"
else
  git -C "$KATAGO_SRC" apply --whitespace=nowarn "$OVERLAY_DIR/patches/analysis_libmode.patch"
fi

if grep -q 'When getLine/writeLine are null' "$KATAGO_SRC/cpp/main.h"; then
  echo "==> main.h already patched"
else
  git -C "$KATAGO_SRC" apply --whitespace=nowarn "$OVERLAY_DIR/patches/main_h_libmode.patch"
fi

echo "==> KataGo $KATAGO_TAG ready at $KATAGO_SRC"
git -C "$KATAGO_SRC" describe --tags --always
