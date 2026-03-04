#!/usr/bin/env bash
# Build KataGo for Android. Single ABI: ABI=arm64-v8a (default). All common ABIs: ABI=all (arm64-v8a + armeabi-v7a).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
NDK_VERSION="${NDK_VERSION:-28.2.13676358}"
NDK_ROOT="${ANDROID_NDK_ROOT:-$HOME/Library/Android/sdk/ndk/$NDK_VERSION}"
ABI_INPUT="${ABI:-arm64-v8a}"
ANDROID_PLATFORM="${ANDROID_PLATFORM:-24}"

# Common device ABIs: 64-bit (mainstream) + 32-bit (older devices)
COMMON_ABIS="arm64-v8a armeabi-v7a"

if [[ "$ABI_INPUT" == "all" ]]; then
  ABIS_TO_BUILD=$COMMON_ABIS
else
  ABIS_TO_BUILD=$ABI_INPUT
fi

KATAGO_SRC="$ROOT_DIR/third_party/KataGo"
EIGEN_SRC="$ROOT_DIR/third_party/eigen"
EIGEN_INSTALL="$ROOT_DIR/third_party/eigen-install"
EIGEN_BUILD="$ROOT_DIR/build/eigen-host"

if [[ ! -d "$KATAGO_SRC" ]]; then
  git clone https://github.com/lightvector/KataGo.git "$KATAGO_SRC"
fi

if [[ ! -d "$EIGEN_SRC" ]]; then
  git clone https://gitlab.com/libeigen/eigen.git "$EIGEN_SRC"
fi

cmake -S "$EIGEN_SRC" -B "$EIGEN_BUILD" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$EIGEN_INSTALL"
cmake --build "$EIGEN_BUILD" -j 8
cmake --install "$EIGEN_BUILD"

for ABI in $ABIS_TO_BUILD; do
  KATAGO_BUILD="$ROOT_DIR/build/katago-android-$ABI"
  OUTPUT_JNILIB="$ROOT_DIR/android/app/src/main/jniLibs/$ABI/libkatago.so"

  echo "==> Building ABI: $ABI"
  cmake -S "$KATAGO_SRC/cpp" -B "$KATAGO_BUILD" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_TOOLCHAIN_FILE="$NDK_ROOT/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI="$ABI" \
    -DANDROID_PLATFORM="android-$ANDROID_PLATFORM" \
    -DANDROID_STL=c++_static \
    -DUSE_BACKEND=EIGEN \
    -DEigen3_DIR="$EIGEN_INSTALL/share/eigen3/cmake" \
    -DEIGEN3_INCLUDE_DIRS="$EIGEN_INSTALL/include/eigen3" \
    -DNO_GIT_REVISION=1 \
    -DCMAKE_C_FLAGS="-DBYTE_ORDER=1234 -DLITTLE_ENDIAN=1234 -DBIG_ENDIAN=4321" \
    -DCMAKE_CXX_FLAGS="-DBYTE_ORDER=1234 -DLITTLE_ENDIAN=1234 -DBIG_ENDIAN=4321"

  cmake --build "$KATAGO_BUILD" -j 8
  "$NDK_ROOT/toolchains/llvm/prebuilt/darwin-x86_64/bin/llvm-strip" "$KATAGO_BUILD/katago" 2>/dev/null || true

  mkdir -p "$(dirname "$OUTPUT_JNILIB")"
  cp "$KATAGO_BUILD/katago" "$OUTPUT_JNILIB"
  echo "==> Done: $OUTPUT_JNILIB"
  ls -lh "$OUTPUT_JNILIB"
done

echo "==> All requested ABIs built. Supported: $ABIS_TO_BUILD"
