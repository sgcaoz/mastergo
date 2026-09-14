#!/usr/bin/env bash
# Cloud Agent environment bootstrap for the MasterGo Flutter app.
# Idempotent: safe to run repeatedly and against a cached/partially-prepared
# filesystem. Installs the Flutter SDK plus the Linux desktop toolchain, then
# resolves project dependencies. No long-running process is started here.
set -euo pipefail

# Flutter version is pinned to match the revision recorded in .metadata so the
# bundled Dart SDK satisfies the pubspec constraint (Dart 3.10.7).
FLUTTER_VERSION="3.38.6"
FLUTTER_HOME="/opt/flutter"

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> Installing system packages (Linux desktop + native plugin toolchain)"
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -qq
# - clang/lld/llvm + build-essential + libstdc++-14-dev: opencv_dart native build
# - cmake/ninja/pkg-config/libgtk-3-dev: Flutter Linux desktop shell
# - gstreamer dev libs: audioplayers_linux plugin
# - liblzma-dev/mesa-utils/libglu1-mesa: misc runtime/build support
sudo apt-get install -y --no-install-recommends \
  curl xz-utils git unzip \
  build-essential g++ libstdc++-14-dev \
  clang lld llvm-18 \
  cmake ninja-build pkg-config \
  libgtk-3-dev liblzma-dev \
  libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
  gstreamer1.0-plugins-base gstreamer1.0-plugins-good \
  mesa-utils libglu1-mesa

echo "==> Installing Flutter ${FLUTTER_VERSION} into ${FLUTTER_HOME}"
INSTALLED_VERSION=""
if [ -x "${FLUTTER_HOME}/bin/flutter" ]; then
  INSTALLED_VERSION="$(cat "${FLUTTER_HOME}/version" 2>/dev/null || true)"
fi
if [ "${INSTALLED_VERSION}" != "${FLUTTER_VERSION}" ]; then
  TARBALL="/tmp/flutter_${FLUTTER_VERSION}.tar.xz"
  URL="https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz"
  curl -fSL "${URL}" -o "${TARBALL}"
  sudo rm -rf "${FLUTTER_HOME}"
  sudo mkdir -p /opt
  sudo tar -xf "${TARBALL}" -C /opt
  sudo chown -R "$(id -u):$(id -g)" "${FLUTTER_HOME}"
  rm -f "${TARBALL}"
fi

# Make flutter/dart available on PATH for interactive shells and non-login shells.
sudo ln -sf "${FLUTTER_HOME}/bin/flutter" /usr/local/bin/flutter
sudo ln -sf "${FLUTTER_HOME}/bin/dart" /usr/local/bin/dart
if ! grep -q '/opt/flutter/bin' "${HOME}/.bashrc" 2>/dev/null; then
  echo 'export PATH="/opt/flutter/bin:$PATH"' >> "${HOME}/.bashrc"
fi
export PATH="${FLUTTER_HOME}/bin:${PATH}"

# Flutter invokes git inside its own checkout; whitelist the directory.
git config --global --add safe.directory "${FLUTTER_HOME}" || true

flutter --disable-analytics >/dev/null 2>&1 || true
flutter config --enable-linux-desktop --no-enable-web >/dev/null 2>&1 || true

echo "==> Resolving project dependencies"
cd "${PROJECT_DIR}"
# The KataGo model directory is git-ignored (large binary) but declared in
# pubspec assets; create a placeholder so asset bundling succeeds without it.
mkdir -p assets/models/katago
touch assets/models/katago/.gitkeep
flutter pub get

echo "==> Environment ready. Build with: flutter build linux --debug"
