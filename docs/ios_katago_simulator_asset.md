# iOS KataGo：仅用 Framework（XCFramework），不用 assets

## 1. 方案说明

- **不再使用** `assets/native/ios/simulator-arm64/katago` 或任何 assets 里的 katago 可执行文件。
- **模拟器与真机统一**：都使用嵌入的 **KataGo.xcframework**，由 Xcode 在构建时选择对应 slice（ios-arm64 真机 / ios-arm64-simulator 模拟器）。
- **符合 App Store**：KataGo 以 .framework 形式作为合法 CFBundleExecutable 存在于 app bundle 内，不会触发 “Invalid bundle structure”。

## 2. 构建 KataGo.xcframework

在项目根目录执行：

```bash
./scripts/ios/build_katago_xcframework.sh
```

脚本会：

1. 用 `ios-device.toolchain.cmake` 编译 **iphoneos arm64**（真机），生成 `KataGo.framework`。
2. 用 `ios-simulator.toolchain.cmake` 编译 **iphonesimulator arm64**（Apple Silicon 模拟器），生成另一份 `KataGo.framework`。
3. 用 `xcodebuild -create-xcframework` 合并为 **KataGo.xcframework**。
4. 输出到 **`ios/Frameworks/KataGo.xcframework`**。

Xcode 工程已配置为引用该路径并嵌入此 XCFramework（Embed Frameworks），无需再在 pubspec 里声明 katago 资源。

## 3. 运行时行为

- **AppDelegate** 只走一条路径：从 `Bundle.main.privateFrameworksURL` 下取 `KataGo.framework/KataGo` 作为可执行文件路径，再调用已有的 `startKatagoProcess(binaryPath:configPath:modelPath:)`。
- 若未找到可执行文件（例如未执行上述构建脚本或未把 XCFramework 加入工程），会返回错误码 `KATAGO_FRAMEWORK_NOT_FOUND`，并提示运行 `scripts/ios/build_katago_xcframework.sh` 并将 `ios/Frameworks/KataGo.xcframework` 加入 Xcode 项目。

## 4. 如何测试

### 4.1 本地构建 XCFramework

```bash
./scripts/ios/build_katago_xcframework.sh
```

确认生成 `ios/Frameworks/KataGo.xcframework`，且 Xcode 中 Frameworks 组下已包含 KataGo.xcframework（已配置好则可直接编译运行）。

### 4.2 模拟器

```bash
flutter run
```

选择 iOS 模拟器（如 iPhone 16）。AI 对弈、局势分析、提示等应正常，引擎来自 XCFramework 的 simulator slice。

### 4.3 真机

用数据线或无线连接真机，`flutter run` 或 Xcode 选择真机运行。引擎来自 XCFramework 的 device slice。

### 4.4 Release / 上架

- 不再需要从 assets 里“剥离” katago 的 Run Script（已移除）。
- 直接 `flutter build ipa` 或 Xcode Archive；包内仅包含嵌入的 KataGo.framework（对应架构），符合 App Store 要求。

## 5. 总结

| 项目 | 说明 |
|------|------|
| 资源 | 不再使用 assets 中的 katago；pubspec 已移除 `assets/native/ios/simulator-arm64/katago`。 |
| 引擎来源 | 仅来自 `ios/Frameworks/KataGo.xcframework`，由构建脚本生成并嵌入 App。 |
| 模拟器 / 真机 | 同一套代码路径，Xcode 自动选 slice；模拟器与真机均可本地测试。 |
| App Store | 以 .framework 形式提供可执行文件，符合 Apple 对 bundle 结构的要求。 |
