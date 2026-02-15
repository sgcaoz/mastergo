# MasterGo

Flutter-based Go app scaffold with three core modules:
- `打谱` (record review + winrate trend placeholder)
- `AI 对弈` (board size / difficulty / handicap configuration)
- `名局欣赏` (built-in SGF index and preview)

## Current status

- KataGo standard model is bundled at:
  - `assets/models/katago/standard.bin.gz`
- KataGo Android binary (`arm64-v8a`) is bundled at:
  - `android/app/src/main/jniLibs/arm64-v8a/libkatago.so`
- Model metadata is config-driven:
  - `assets/config/katago_models.json`
- Android bridge channel is implemented:
  - `mastergo/katago`
  - methods: `prepareModel`, `startEngine`, `analyzeOnce`, `shutdownEngine`
- iOS bridge channel is also wired to the same method names:
  - `ios/Runner/AppDelegate.swift`
  - currently returns explicit `IOS_ENGINE_NOT_LINKED` until KataGoKit is linked

## Build (Way A)

Rebuild Android KataGo binary locally and bundle into jniLibs:

```bash
./scripts/android/build_katago_android.sh
```

Optional environment overrides:
- `ABI` (default `arm64-v8a`)
- `ANDROID_PLATFORM` (default `24`)
- `NDK_VERSION` (default `28.2.13676358`)

## Runtime behavior

At runtime, Android bridge starts directly from:
- `<nativeLibraryDir>/libkatago.so`

If the binary is absent for the current ABI, engine startup returns `BINARY_NOT_FOUND`.

iOS currently supports model asset preparation and integrity check, but does not launch KataGo yet.
To enable iOS playing/analysis, link an in-process native engine framework and implement bridge calls.

## Next integration step

1. Add additional ABI binaries (`armeabi-v7a`, `x86_64`) as needed.
2. Replace temporary analyze response parser with full JSON parsing (`moveInfos`, `rootInfo`).
