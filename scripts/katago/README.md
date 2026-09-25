# KataGo engine pin and overlay

The app ships a local Eigen (CPU) KataGo build:

- Android: `libkatago.so` subprocess via jniLibs (both `arm64-v8a` and `armeabi-v7a` for Play)
- iOS: in-process static XCFramework (`kg_analysis_*`), no `posix_spawn` (App Store)

`third_party/KataGo` is gitignored. These scripts pin and patch it.

## Pin

- Engine: `v1.18.1` (`scripts/katago/VERSION`) — required for transformer nets
- Network: `kata1-tf2-b10c384-s2941M-d5872M` as `assets/models/katago/standard.bin.gz`

```bash
# Fetch/checkout v1.18.1 and apply iOS analysis-lib overlay
./scripts/katago/apply_engine.sh

# Download the bundled small transformer (gitignored)
./scripts/katago/download_model.sh

# Native engines (needed before store builds)
ABI=all ./scripts/android/build_katago_android.sh
./scripts/ios/build_katago_xcframework.sh
```
