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

## 名局数据（Seed 库）

名局在**构建阶段**一次性灌入 SQLite，产出 `assets/master_games/mastergo_seed.db`。App 首次使用时会将该文件复制到应用数据目录，不再在运行时从 Dart 列表或 SGF 灌库。

- 元数据与 SGF 路径：`lib/infra/config/master_games_data.dart`
- 生成 seed 库：在项目根目录执行  
  `dart run tool/seed_master_db.dart`  
  发版或增删名局后需重新运行并提交新的 `mastergo_seed.db`。

## Android KataGo（测试与上线统一）

**唯一方式**：引擎只来自 **jniLibs** → 运行时即 `nativeLibraryDir/libkatago.so`。无兜底、无 assets 引擎资源。

1. **构建前**（本地或 CI/Play 打包前）必须执行：
   - 仅 64 位：`./scripts/android/build_katago_android.sh`（默认 `arm64-v8a`）
   - **常见芯片兼容（推荐）**：`ABI=all ./scripts/android/build_katago_android.sh`，会构建 `arm64-v8a` 与 `armeabi-v7a`
2. **Release 构建**：Gradle 会检查 jniLibs 中是否**同时存在** `arm64-v8a` 与 `armeabi-v7a` 的 `libkatago.so`，缺一则构建失败。

可选环境变量：`ABI`（`arm64-v8a` / `armeabi-v7a` / `all`）、`ANDROID_PLATFORM`（默认 `24`）、`NDK_VERSION`。

## Runtime behavior

At runtime, Android uses only `<nativeLibraryDir>/libkatago.so` (from jniLibs). Build both ABIs with `ABI=all ./scripts/android/build_katago_android.sh`; release build requires `arm64-v8a` and `armeabi-v7a`. If the .so is missing, engine startup returns `BINARY_NOT_FOUND`.

iOS currently supports model asset preparation and integrity check, but does not launch KataGo yet.
To enable iOS playing/analysis, link an in-process native engine framework and implement bridge calls.

## Next integration step

1. Add additional ABI binaries (`armeabi-v7a`, `x86_64`) as needed.
2. Replace temporary analyze response parser with full JSON parsing (`moveInfos`, `rootInfo`).
