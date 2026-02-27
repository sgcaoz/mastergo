#!/usr/bin/env bash
# Build KataGo as in-process STATIC library XCFramework (ios-arm64 + ios-arm64-simulator).
# Single binary (Runner.app only); no embedded framework to sign; App Store compliant.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
KATAGO_SRC="$ROOT_DIR/third_party/KataGo"
EIGEN_SRC="$ROOT_DIR/third_party/eigen"
EIGEN_INSTALL="$ROOT_DIR/third_party/eigen-install"
TOOLCHAIN_DEVICE="$ROOT_DIR/scripts/ios/ios-device.toolchain.cmake"
TOOLCHAIN_SIM="$ROOT_DIR/scripts/ios/ios-simulator.toolchain.cmake"
BUILD_DEVICE="$ROOT_DIR/build/katago-ios-device-arm64"
BUILD_SIM="$ROOT_DIR/build/katago-ios-simulator-arm64"
HEADERS_DIR="$ROOT_DIR/ios/KataGoLib"
XCFRAMEWORK_OUT="$ROOT_DIR/ios/Frameworks/KataGo.xcframework"

echo "==> Root: $ROOT_DIR"

if [[ ! -d "$KATAGO_SRC" ]]; then
  git clone https://github.com/lightvector/KataGo.git "$KATAGO_SRC"
fi
if [[ ! -d "$EIGEN_SRC" ]]; then
  git clone https://gitlab.com/libeigen/eigen.git "$EIGEN_SRC"
fi
if [[ ! -f "$TOOLCHAIN_DEVICE" ]] || [[ ! -f "$TOOLCHAIN_SIM" ]]; then
  echo "error: toolchains not found"
  exit 1
fi
if [[ ! -d "$HEADERS_DIR" ]] || [[ ! -f "$HEADERS_DIR/kg_analysis.h" ]]; then
  echo "error: headers not found at $HEADERS_DIR (kg_analysis.h)"
  exit 1
fi

EIGEN_ARGS=()
EIGEN_INCLUDE_FLAG=()
if [[ -d "$EIGEN_INSTALL" ]] && [[ -f "$EIGEN_INSTALL/share/eigen3/cmake/Eigen3Config.cmake" ]]; then
  EIGEN_ARGS=(-DEigen3_DIR="$EIGEN_INSTALL/share/eigen3/cmake")
  EIGEN_INCLUDE_FLAG=(-DCMAKE_CXX_FLAGS="-isystem $EIGEN_INSTALL/include/eigen3")
else
  EIGEN_ARGS=(-DEIGEN3_INCLUDE_DIRS="$EIGEN_SRC")
fi

# ---- Build device: static library only ----
echo "==> Building KataGo static library for ios-arm64 (device)"
rm -rf "$BUILD_DEVICE"
mkdir -p "$BUILD_DEVICE"
cmake -S "$KATAGO_SRC/cpp" -B "$BUILD_DEVICE" \
  -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_DEVICE" \
  -DCMAKE_BUILD_TYPE=Release \
  -DUSE_BACKEND=EIGEN \
  -DBUILD_ANALYSIS_LIB=ON \
  -DKATAGO_ANALYSIS_STATIC=ON \
  -DNO_GIT_REVISION=1 \
  "${EIGEN_ARGS[@]}" \
  "${EIGEN_INCLUDE_FLAG[@]}"
cmake --build "$BUILD_DEVICE" -j 8

if [[ ! -f "$BUILD_DEVICE/libkatago_analysis.a" ]]; then
  echo "error: device static library not found: $BUILD_DEVICE/libkatago_analysis.a"
  exit 1
fi
LIB_DEVICE="$BUILD_DEVICE/libkatago_analysis.a"

# ---- Build simulator: static library only ----
echo "==> Building KataGo static library for ios-arm64-simulator"
rm -rf "$BUILD_SIM"
mkdir -p "$BUILD_SIM"
cmake -S "$KATAGO_SRC/cpp" -B "$BUILD_SIM" \
  -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_SIM" \
  -DCMAKE_BUILD_TYPE=Release \
  -DUSE_BACKEND=EIGEN \
  -DBUILD_ANALYSIS_LIB=ON \
  -DKATAGO_ANALYSIS_STATIC=ON \
  -DNO_GIT_REVISION=1 \
  "${EIGEN_ARGS[@]}" \
  "${EIGEN_INCLUDE_FLAG[@]}"
cmake --build "$BUILD_SIM" -j 8

if [[ ! -f "$BUILD_SIM/libkatago_analysis.a" ]]; then
  echo "error: simulator static library not found: $BUILD_SIM/libkatago_analysis.a"
  exit 1
fi
LIB_SIM="$BUILD_SIM/libkatago_analysis.a"

# ---- Create XCFramework from static libs (link-only; no embed, no code signing of framework) ----
echo "==> Creating KataGo.xcframework (static)"
rm -rf "$XCFRAMEWORK_OUT"
mkdir -p "$(dirname "$XCFRAMEWORK_OUT")"
xcodebuild -create-xcframework \
  -library "$LIB_DEVICE" -headers "$HEADERS_DIR" \
  -library "$LIB_SIM"   -headers "$HEADERS_DIR" \
  -output "$XCFRAMEWORK_OUT"

echo "==> Done: $XCFRAMEWORK_OUT"
ls -la "$XCFRAMEWORK_OUT"
