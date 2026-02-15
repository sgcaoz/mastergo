#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
KATAGO_SRC="$ROOT_DIR/third_party/KataGo"
EIGEN_SRC="$ROOT_DIR/third_party/eigen"
KATAGO_BUILD="$ROOT_DIR/build/katago-ios-simulator-arm64"
OUTPUT_ASSET="$ROOT_DIR/assets/native/ios/simulator-arm64/katago"

echo "==> Root: $ROOT_DIR"

if [[ ! -d "$KATAGO_SRC" ]]; then
  git clone https://github.com/lightvector/KataGo.git "$KATAGO_SRC"
fi

if [[ ! -d "$EIGEN_SRC" ]]; then
  git clone https://gitlab.com/libeigen/eigen.git "$EIGEN_SRC"
fi

rm -rf "$KATAGO_BUILD"

cmake -S "$KATAGO_SRC/cpp" -B "$KATAGO_BUILD" \
  -DCMAKE_BUILD_TYPE=Release \
  -DUSE_BACKEND=EIGEN \
  -DEIGEN3_INCLUDE_DIRS="$EIGEN_SRC" \
  -DNO_GIT_REVISION=1 \
  -DCMAKE_OSX_ARCHITECTURES=arm64

cmake --build "$KATAGO_BUILD" -j 8
strip "$KATAGO_BUILD/katago"

mkdir -p "$(dirname "$OUTPUT_ASSET")"
cp "$KATAGO_BUILD/katago" "$OUTPUT_ASSET"
chmod +x "$OUTPUT_ASSET"

echo "==> Done: $OUTPUT_ASSET"
ls -lh "$OUTPUT_ASSET"
