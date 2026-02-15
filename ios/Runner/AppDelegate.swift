import Flutter
import UIKit
import CryptoKit
import Darwin

@main
@objc class AppDelegate: FlutterAppDelegate {
  private let katagoChannelName = "mastergo/katago"
  private var iosEngineStarted = false
  private var katagoPid: pid_t = 0
  private var katagoStdinFd: Int32 = -1
  private var katagoStdoutFd: Int32 = -1
  private var stdoutBuffer = Data()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    if let controller = window?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(
        name: katagoChannelName,
        binaryMessenger: controller.binaryMessenger
      )
      channel.setMethodCallHandler { [weak self] call, result in
        guard let self = self else {
          result(FlutterError(code: "INTERNAL", message: "AppDelegate deallocated", details: nil))
          return
        }
        switch call.method {
        case "prepareModel":
          self.prepareModel(call: call, result: result)
        case "startEngine":
          self.startEngine(call: call, result: result)
        case "analyzeOnce":
          self.analyzeOnce(call: call, result: result)
        case "shutdownEngine":
          self.shutdownEngine(result: result)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }

    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private func prepareModel(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard
      let args = call.arguments as? [String: Any],
      let modelAssetPath = args["modelAssetPath"] as? String
    else {
      result(FlutterError(code: "BAD_ARGS", message: "modelAssetPath is required", details: nil))
      return
    }

    let expectedSha = (args["modelSha256"] as? String)?.lowercased()
    let assetKey = FlutterDartProject.lookupKey(forAsset: modelAssetPath)
    guard let assetFilePath = Bundle.main.path(forResource: assetKey, ofType: nil) else {
      result(
        FlutterError(
          code: "MODEL_ASSET_NOT_FOUND",
          message: "Asset not found: \(modelAssetPath)",
          details: ["lookupKey": assetKey]
        )
      )
      return
    }

    do {
      let targetDir = try ensureDirectory(relativePath: "katago/models")
      let fileName = URL(fileURLWithPath: modelAssetPath).lastPathComponent
      let targetFile = targetDir.appendingPathComponent(fileName)

      try copyFileIfNeeded(from: URL(fileURLWithPath: assetFilePath), to: targetFile)
      let actualSha = try sha256Hex(of: targetFile)

      if let expectedSha = expectedSha, expectedSha != actualSha.lowercased() {
        result(
          FlutterError(
            code: "MODEL_HASH_MISMATCH",
            message: "Expected sha256 \(expectedSha) but got \(actualSha)",
            details: nil
          )
        )
        return
      }

      result([
        "modelPath": targetFile.path,
        "sha256": actualSha,
      ])
    } catch {
      result(FlutterError(code: "PREPARE_MODEL_FAILED", message: error.localizedDescription, details: nil))
    }
  }

  private func startEngine(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard
      let args = call.arguments as? [String: Any],
      let modelPath = args["modelPath"] as? String,
      let configAssetPath = args["configAssetPath"] as? String
    else {
      result(FlutterError(code: "BAD_ARGS", message: "modelPath and configAssetPath are required", details: nil))
      return
    }

    #if targetEnvironment(simulator)
    do {
      let configFile = try prepareRuntimeAssetFile(
        assetPath: configAssetPath,
        relativeDir: "katago/config"
      )
      let simulatorBinary = try prepareRuntimeAssetFile(
        assetPath: "assets/native/ios/simulator-arm64/katago",
        relativeDir: "katago/bin",
        forceExecutable: true
      )
      try startKatagoProcess(
        binaryPath: simulatorBinary.path,
        configPath: configFile.path,
        modelPath: modelPath
      )
      iosEngineStarted = true
      result(["started": true])
    } catch {
      iosEngineStarted = false
      result(
        FlutterError(
          code: "START_ENGINE_FAILED",
          message: error.localizedDescription,
          details: nil
        )
      )
    }
    #else
    iosEngineStarted = false
    result(
      FlutterError(
        code: "IOS_ENGINE_NOT_LINKED",
        message: "iOS devices require in-process linked KataGo framework; simulator process bridge is unsupported on real devices.",
        details: [
          "modelPath": modelPath,
          "nextStep": "Link KataGoKit.framework and implement Swift bridge."
        ]
      )
    )
    #endif
  }

  private func analyzeOnce(call: FlutterMethodCall, result: @escaping FlutterResult) {
    if !iosEngineStarted {
      result(
        FlutterError(
          code: "ENGINE_NOT_RUNNING",
          message: "KataGo iOS engine is not started.",
          details: "Call startEngine after integrating KataGoKit."
        )
      )
      return
    }

    guard let args = call.arguments as? [String: Any] else {
      result(FlutterError(code: "BAD_ARGS", message: "analyzeOnce args are required", details: nil))
      return
    }

    let queryId = (args["queryId"] as? String) ?? "query-default"
    let maxVisits = (args["maxVisits"] as? Int) ?? 120
    let thinkingTimeMs = (args["thinkingTimeMs"] as? Int) ?? 1200
    let timeoutOverrideMs = args["timeoutMs"] as? Int
    let boardSize = (args["boardSize"] as? Int) ?? 19
    let komi = (args["komi"] as? Double) ?? 7.5
    let ruleset = (args["ruleset"] as? String) ?? "chinese"
    let moves = (args["moves"] as? [String]) ?? []
    let initialStones = (args["initialStones"] as? [String]) ?? []

    let payload: [String: Any] = [
      "id": queryId,
      "rules": ruleset,
      "komi": komi,
      "boardXSize": boardSize,
      "boardYSize": boardSize,
      "maxVisits": maxVisits,
      "moves": parseTokenArray(tokens: moves),
      "initialStones": parseTokenArray(tokens: initialStones),
    ]

    do {
      let data = try JSONSerialization.data(withJSONObject: payload)
      try writeLineToEngine(data: data)

      let timeoutMs = timeoutOverrideMs ?? max(8000, thinkingTimeMs * 6)
      guard let response = readJsonResponse(queryId: queryId, timeoutMs: timeoutMs) else {
        if !isProcessAlive() {
          result(FlutterError(code: "ENGINE_DIED", message: "KataGo process exited during analysis", details: nil))
          return
        }
        result(
          FlutterError(
            code: "ENGINE_TIMEOUT",
            message: "No valid JSON response from engine within \(timeoutMs)ms",
            details: [
              "queryId": queryId,
              "timeoutMs": timeoutMs,
              "engineOutputTail": readAnyLinesWithin(timeoutMs: 1200)
            ]
          )
        )
        return
      }

      if let errorMsg = response["error"] as? String {
        result(
          FlutterError(
            code: "ENGINE_RESPONSE_ERROR",
            message: errorMsg,
            details: response
          )
        )
        return
      }

      let rootInfo = response["rootInfo"] as? [String: Any]
      let moveInfos = response["moveInfos"] as? [[String: Any]]
      let winrate = (rootInfo?["winrate"] as? NSNumber)?.doubleValue ?? 0.5
      let scoreLead = (rootInfo?["scoreLead"] as? NSNumber)?.doubleValue ?? 0.0
      let bestMove = (moveInfos?.first?["move"] as? String) ?? "pass"

      result([
        "queryId": queryId,
        "bestMove": bestMove,
        "winrate": winrate,
        "scoreLead": scoreLead,
        "rawResponse": response
      ])
    } catch {
      result(FlutterError(code: "ANALYZE_FAILED", message: error.localizedDescription, details: nil))
    }
  }

  private func shutdownEngine(result: @escaping FlutterResult) {
    stopKatagoProcess()
    iosEngineStarted = false
    result(nil)
  }

  private func ensureDirectory(relativePath: String) throws -> URL {
    let appSupport = try FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    let dir = appSupport.appendingPathComponent(relativePath, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private func copyFileIfNeeded(from source: URL, to target: URL) throws {
    if FileManager.default.fileExists(atPath: target.path) {
      return
    }
    try FileManager.default.copyItem(at: source, to: target)
  }

  private func sha256Hex(of fileURL: URL) throws -> String {
    let data = try Data(contentsOf: fileURL)
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  private func prepareRuntimeAssetFile(
    assetPath: String,
    relativeDir: String,
    forceExecutable: Bool = false
  ) throws -> URL {
    let assetKey = FlutterDartProject.lookupKey(forAsset: assetPath)
    guard let assetFilePath = Bundle.main.path(forResource: assetKey, ofType: nil) else {
      throw NSError(
        domain: "mastergo.katago",
        code: 2001,
        userInfo: [NSLocalizedDescriptionKey: "Asset not found: \(assetPath) (lookupKey=\(assetKey))"]
      )
    }

    let targetDir = try ensureDirectory(relativePath: relativeDir)
    let fileName = URL(fileURLWithPath: assetPath).lastPathComponent
    let targetFile = targetDir.appendingPathComponent(fileName)
    try copyFileReplacing(from: URL(fileURLWithPath: assetFilePath), to: targetFile)
    if forceExecutable {
      try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o755))],
        ofItemAtPath: targetFile.path
      )
    }
    return targetFile
  }

  private func copyFileReplacing(from source: URL, to target: URL) throws {
    if FileManager.default.fileExists(atPath: target.path) {
      try FileManager.default.removeItem(at: target)
    }
    try FileManager.default.copyItem(at: source, to: target)
  }

  private func startKatagoProcess(binaryPath: String, configPath: String, modelPath: String) throws {
    if isProcessAlive() {
      return
    }
    stopKatagoProcess()

    var stdinPipe: [Int32] = [0, 0]
    var stdoutPipe: [Int32] = [0, 0]
    guard pipe(&stdinPipe) == 0 else {
      throw NSError(domain: "mastergo.katago", code: 2101, userInfo: [NSLocalizedDescriptionKey: "Failed to create stdin pipe"])
    }
    guard pipe(&stdoutPipe) == 0 else {
      close(stdinPipe[0]); close(stdinPipe[1])
      throw NSError(domain: "mastergo.katago", code: 2102, userInfo: [NSLocalizedDescriptionKey: "Failed to create stdout pipe"])
    }

    let currentFlags = fcntl(stdoutPipe[0], F_GETFL)
    _ = fcntl(stdoutPipe[0], F_SETFL, currentFlags | O_NONBLOCK)

    var fileActions: posix_spawn_file_actions_t? = nil
    posix_spawn_file_actions_init(&fileActions)
    posix_spawn_file_actions_adddup2(&fileActions, stdinPipe[0], STDIN_FILENO)
    posix_spawn_file_actions_adddup2(&fileActions, stdoutPipe[1], STDOUT_FILENO)
    posix_spawn_file_actions_adddup2(&fileActions, stdoutPipe[1], STDERR_FILENO)
    posix_spawn_file_actions_addclose(&fileActions, stdinPipe[1])
    posix_spawn_file_actions_addclose(&fileActions, stdoutPipe[0])

    let args = [binaryPath, "analysis", "-config", configPath, "-model", modelPath]
    var cArgs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
    cArgs.append(nil)
    defer {
      for ptr in cArgs where ptr != nil {
        free(ptr)
      }
      posix_spawn_file_actions_destroy(&fileActions)
    }

    var pid: pid_t = 0
    let spawnCode = binaryPath.withCString { binaryPtr in
      cArgs.withUnsafeMutableBufferPointer { argvPtr in
        posix_spawn(&pid, binaryPtr, &fileActions, nil, argvPtr.baseAddress, nil)
      }
    }

    close(stdinPipe[0])
    close(stdoutPipe[1])

    guard spawnCode == 0 else {
      close(stdinPipe[1])
      close(stdoutPipe[0])
      throw NSError(
        domain: "mastergo.katago",
        code: Int(spawnCode),
        userInfo: [NSLocalizedDescriptionKey: "posix_spawn failed: \(String(cString: strerror(spawnCode)))"]
      )
    }

    katagoPid = pid
    katagoStdinFd = stdinPipe[1]
    katagoStdoutFd = stdoutPipe[0]
    stdoutBuffer.removeAll(keepingCapacity: true)

    usleep(250_000)
    if !isProcessAlive() {
      let logs = readAnyLinesWithin(timeoutMs: 1200)
      stopKatagoProcess()
      throw NSError(
        domain: "mastergo.katago",
        code: 2103,
        userInfo: [NSLocalizedDescriptionKey: "KataGo process exited immediately. logs=\(logs)"]
      )
    }
  }

  private func stopKatagoProcess() {
    if katagoStdinFd >= 0 {
      close(katagoStdinFd)
      katagoStdinFd = -1
    }
    if katagoStdoutFd >= 0 {
      close(katagoStdoutFd)
      katagoStdoutFd = -1
    }
    if katagoPid > 0 {
      _ = kill(katagoPid, SIGTERM)
      var status: Int32 = 0
      _ = waitpid(katagoPid, &status, WNOHANG)
      katagoPid = 0
    }
    stdoutBuffer.removeAll(keepingCapacity: true)
  }

  private func isProcessAlive() -> Bool {
    guard katagoPid > 0 else { return false }
    return kill(katagoPid, 0) == 0
  }

  private func writeLineToEngine(data: Data) throws {
    guard katagoStdinFd >= 0 else {
      throw NSError(domain: "mastergo.katago", code: 2201, userInfo: [NSLocalizedDescriptionKey: "Engine stdin not ready"])
    }
    var payload = data
    payload.append(0x0A)
    try payload.withUnsafeBytes { rawBuffer in
      guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
        throw NSError(domain: "mastergo.katago", code: 2202, userInfo: [NSLocalizedDescriptionKey: "Invalid payload buffer"])
      }
      var total = 0
      while total < payload.count {
        let written = write(katagoStdinFd, base.advanced(by: total), payload.count - total)
        if written <= 0 {
          throw NSError(
            domain: "mastergo.katago",
            code: 2203,
            userInfo: [NSLocalizedDescriptionKey: "Failed writing to engine stdin"]
          )
        }
        total += written
      }
    }
  }

  private func readJsonResponse(queryId: String, timeoutMs: Int) -> [String: Any]? {
    let start = currentTimeMs()
    while currentTimeMs() - start < Int64(timeoutMs) {
      guard let line = readLineWithTimeout(timeoutMs: 300) else {
        continue
      }
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      guard trimmed.first == "{" else { continue }
      guard
        let data = trimmed.data(using: .utf8),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else {
        continue
      }
      let id = json["id"].map { String(describing: $0) } ?? ""
      let hasError = json["error"] != nil
      let hasRootInfo = json["rootInfo"] != nil
      if hasError && (id.isEmpty || id == queryId) {
        return json
      }
      if hasRootInfo && (id.isEmpty || id == queryId) {
        return json
      }
    }
    return nil
  }

  private func readAnyLinesWithin(timeoutMs: Int) -> String {
    let start = currentTimeMs()
    var lines: [String] = []
    while currentTimeMs() - start < Int64(timeoutMs) {
      if let line = readLineWithTimeout(timeoutMs: 120), !line.isEmpty {
        lines.append(line)
        if lines.count >= 8 {
          break
        }
      }
    }
    return lines.isEmpty ? "<no output>" : lines.joined(separator: "\n")
  }

  private func readLineWithTimeout(timeoutMs: Int) -> String? {
    let start = currentTimeMs()
    while currentTimeMs() - start < Int64(timeoutMs) {
      if let line = popBufferedLine() {
        return line
      }
      guard katagoStdoutFd >= 0 else { return nil }
      var chunk = [UInt8](repeating: 0, count: 4096)
      let readCount = read(katagoStdoutFd, &chunk, chunk.count)
      if readCount > 0 {
        stdoutBuffer.append(chunk, count: readCount)
        if let line = popBufferedLine() {
          return line
        }
        continue
      }
      if readCount == 0 {
        return popBufferedLine()
      }
      if errno != EAGAIN && errno != EWOULDBLOCK {
        return nil
      }
      usleep(20_000)
    }
    return nil
  }

  private func popBufferedLine() -> String? {
    guard !stdoutBuffer.isEmpty else { return nil }
    if let range = stdoutBuffer.firstRange(of: Data([0x0A])) {
      let lineData = stdoutBuffer.subdata(in: 0 ..< range.lowerBound)
      stdoutBuffer.removeSubrange(0 ... range.lowerBound)
      return String(data: lineData, encoding: .utf8)
    }
    return nil
  }

  private func parseTokenArray(tokens: [String]) -> [[String]] {
    var pairs: [[String]] = []
    for token in tokens {
      let parts = token.split(separator: ":", maxSplits: 1).map(String.init)
      if parts.count == 2 {
        pairs.append(parts)
      }
    }
    return pairs
  }

  private func currentTimeMs() -> Int64 {
    return Int64(Date().timeIntervalSince1970 * 1000.0)
  }
}
