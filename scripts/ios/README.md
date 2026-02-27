# iOS KataGo 构建（仅 Framework）

iOS 路径只允许通过 `KataGo.xcframework` 使用引擎，不再使用 `assets/native/ios` 中的可执行文件。

在项目根目录执行：

```bash
./scripts/ios/build_katago_xcframework.sh
```

脚本会同时构建并合并：

- `ios-arm64`（真机）
- `ios-arm64-simulator`（模拟器）

输出：

- `ios/Frameworks/KataGo.xcframework`

说明：

- Xcode 工程会嵌入该 XCFramework。
- App 运行时统一从 `KataGo.framework/KataGo` 启动，不再依赖 assets 可执行文件。
