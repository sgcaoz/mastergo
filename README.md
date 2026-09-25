# MasterGo

Flutter Go (Weiqi) app for Android and iOS: local KataGo analysis, no cloud engine.

## Modules

- **打谱** — import / URL download / open-with SGF, variations, winrate, continue into AI play, built-in master games
- **AI 对弈** — 9/13/19, handicap, rule presets, difficulty from `ai_profiles.json`
- **拍照识谱** — camera/gallery, corner edit, OpenCV recognition, ownership endgame heuristic, continue play

名局 (master games) live inside 打谱, not as a separate bottom tab.

## Platforms

| Platform | Engine | Notes |
|---|---|---|
| Android | subprocess `libkatago.so` via jniLibs | Release requires both `arm64-v8a` and `armeabi-v7a` |
| iOS | in-process KataGo XCFramework (`kg_analysis_*`) | App Store–friendly; no posix_spawn |
| macOS / web / desktop | not supported | No `mastergo/katago` plugin |

Channel: `mastergo/katago` (`prepareModel`, `startEngine`, `analyzeOnce`, `shutdownEngine`). A single app-scoped adapter owns the engine; tabs keep state with `IndexedStack`.

## Engine assets

- Engine: KataGo **v1.18.1** (Eigen CPU). Pin/overlay: `scripts/katago/`
- Model: `assets/models/katago/standard.bin.gz` — `kata1-tf2-b10c384-s2941M-d5872M` (gitignored; `./scripts/katago/download_model.sh`)
- Metadata: `assets/config/katago_models.json`
- Android binary: `ABI=all ./scripts/android/build_katago_android.sh` (arm64-v8a + armeabi-v7a, 16KB-page ready)
- iOS framework: `ios/Frameworks/KataGo.xcframework` (gitignored; in-process static lib, App Store–friendly)

## 名局 seed

Catalog: `assets/config/master_games.json` (`category` / `tags`).

```
dart run tool/seed_master_db.dart
```

Bump `assets/config/master_seed_meta.json` `version` after changing the library so existing installs upsert new master games without overwriting user winrates.

## Config

| File | Used by |
|---|---|
| `assets/config/ai_profiles.json` | AI difficulty |
| `assets/config/rule_presets.json` | Loaded at startup; compiled fallback in `RulePresetCatalog` |
| `assets/config/katago_analysis.cfg` | Engine threads/cache |
| `assets/config/katago_models.json` | Bundled model id / sha256 |

## Release notes

- Android **release** needs `INTERNET` in the main manifest (URL SGF import is HTTPS-only, size-capped).
- Do not construct `PlatformKatagoAdapter` in feature pages; use `KatagoEngineScope`.
