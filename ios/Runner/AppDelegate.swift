import Flutter
import UIKit
import CryptoKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private let katagoChannelName = "mastergo/katago"
  private let fileOpenerChannelName = "mastergo/file_opener"
  private let katagoQueue = DispatchQueue(label: "mastergo.katago.engine")
  private var iosEngineStarted = false
  private var pendingOpenSgfUrl: URL?
  /// In-process KataGo analysis handle (no subprocess; App Store compliant).
  private var katagoHandle: OpaquePointer?

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
          DispatchQueue.main.async {
            result(FlutterError(code: "INTERNAL", message: "AppDelegate deallocated", details: nil))
          }
          return
        }
        let safeResult: FlutterResult = { value in
          DispatchQueue.main.async {
            result(value)
          }
        }
        self.katagoQueue.async {
          switch call.method {
          case "prepareModel":
            self.prepareModel(call: call, result: safeResult)
          case "startEngine":
            self.startEngine(call: call, result: safeResult)
          case "analyzeOnce":
            self.analyzeOnce(call: call, result: safeResult)
          case "shutdownEngine":
            self.shutdownEngine(result: safeResult)
          default:
            safeResult(FlutterMethodNotImplemented)
          }
        }
      }
    }

    if let controller = window?.rootViewController as? FlutterViewController {
      let fileOpenerChannel = FlutterMethodChannel(
        name: fileOpenerChannelName,
        binaryMessenger: controller.binaryMessenger
      )
      fileOpenerChannel.setMethodCallHandler { [weak self] call, result in
        if call.method == "getInitialOpenedSgf" {
          self?.getInitialOpenedSgf(result: result)
        } else {
          result(FlutterMethodNotImplemented)
        }
      }
    }

    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    if url.pathExtension.lowercased() == "sgf" {
      pendingOpenSgfUrl = url
    }
    return true
  }

  private func getInitialOpenedSgf(result: @escaping FlutterResult) {
    guard let url = pendingOpenSgfUrl else {
      result(nil)
      return
    }
    pendingOpenSgfUrl = nil
    let fileName = url.lastPathComponent
    var didStartAccessing = false
    if url.startAccessingSecurityScopedResource() {
      didStartAccessing = true
    }
    defer {
      if didStartAccessing {
        url.stopAccessingSecurityScopedResource()
      }
    }
    do {
      let content = try String(contentsOf: url, encoding: .utf8)
      result(["content": content, "fileName": fileName])
    } catch {
      result(FlutterError(
        code: "READ_FAILED",
        message: error.localizedDescription,
        details: nil
      ))
    }
  }

  /// Resolve Flutter asset to a real file path. Assets live under App.framework/flutter_assets/ (release) or in bundle (debug).
  private func pathForFlutterAsset(assetPath: String) -> String? {
    let key = FlutterDartProject.lookupKey(forAsset: assetPath)
    if let p = Bundle.main.path(forResource: key, ofType: nil) {
      return p
    }
    let bundlePath = Bundle.main.bundlePath
    let fs = bundlePath as NSString
    let candidates = [
      fs.appendingPathComponent("Frameworks/App.framework/flutter_assets").appending("/").appending(assetPath),
      (fs.appendingPathComponent("flutter_assets") as NSString).appendingPathComponent(assetPath),
    ]
    for fullPath in candidates {
      if FileManager.default.fileExists(atPath: fullPath) {
        return fullPath
      }
    }
    return nil
  }

  private func prepareModel(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard
      let args = call.arguments as? [String: Any],
      let modelAssetPath = args["modelAssetPath"] as? String
    else {
      print("[KataGo] prepareModel bad args: need modelAssetPath")
      result(FlutterError(code: "BAD_ARGS", message: "modelAssetPath is required", details: nil))
      return
    }
    print("[KataGo] prepareModel asset=\(modelAssetPath)")

    let expectedSha = (args["modelSha256"] as? String)?.lowercased()
    guard let assetFilePath = pathForFlutterAsset(assetPath: modelAssetPath) else {
      print("[KataGo] prepareModel asset not found: \(modelAssetPath)")
      result(
        FlutterError(
          code: "MODEL_ASSET_NOT_FOUND",
          message: "Asset not found: \(modelAssetPath)",
          details: nil
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
        print("[KataGo] prepareModel sha256 mismatch")
        result(
          FlutterError(
            code: "MODEL_HASH_MISMATCH",
            message: "Expected sha256 \(expectedSha) but got \(actualSha)",
            details: nil
          )
        )
        return
      }

      print("[KataGo] prepareModel ok path=\(targetFile.path)")
      result([
        "modelPath": targetFile.path,
        "sha256": actualSha,
      ])
    } catch {
      print("[KataGo] prepareModel error: \(error.localizedDescription)")
      result(FlutterError(code: "PREPARE_MODEL_FAILED", message: error.localizedDescription, details: nil))
    }
  }

  private func startEngine(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard
      let args = call.arguments as? [String: Any],
      let modelPath = args["modelPath"] as? String,
      let configAssetPath = args["configAssetPath"] as? String
    else {
      print("[KataGo] startEngine bad args: need modelPath and configAssetPath")
      result(FlutterError(code: "BAD_ARGS", message: "modelPath and configAssetPath are required", details: nil))
      return
    }
    do {
      if katagoHandle != nil {
        print("[KataGo] startEngine destroying previous handle")
        kg_analysis_destroy(katagoHandle)
        katagoHandle = nil
      }
      let configFile = try prepareRuntimeAssetFile(
        assetPath: configAssetPath,
        relativeDir: "katago/config"
      )
      let configPath = configFile.path
      let fm = FileManager.default
      guard fm.fileExists(atPath: configPath) else {
        print("[KataGo] startEngine config file missing: \(configPath)")
        iosEngineStarted = false
        result(FlutterError(code: "START_ENGINE_FAILED", message: "Config file not found: \(configPath)", details: nil))
        return
      }
      guard fm.fileExists(atPath: modelPath) else {
        print("[KataGo] startEngine model file missing: \(modelPath)")
        iosEngineStarted = false
        result(FlutterError(code: "START_ENGINE_FAILED", message: "Model file not found: \(modelPath)", details: nil))
        return
      }
      print("[KataGo] startEngine config=\(configPath) model=\(modelPath) (files exist)")
      let h: OpaquePointer? = configPath.withCString { cConfig in
        modelPath.withCString { cModel in
          kg_analysis_create(cConfig, cModel)
        }
      }
      guard let handle = h else {
        print("[KataGo] startEngine failed: kg_analysis_create returned nil (config/model paths ok)")
        iosEngineStarted = false
        result(
          FlutterError(
            code: "START_ENGINE_FAILED",
            message: "KataGo in-process engine failed to create (config or model path invalid).",
            details: nil
          )
        )
        return
      }
      // Probe model loading immediately so startup does not silently succeed with no NN.
      let probeId = "probe-model-\(currentTimeMs())"
      let probeReq: [String: Any] = ["id": probeId, "action": "query_models"]
      let probeData = try JSONSerialization.data(withJSONObject: probeReq)
      guard let probeJson = String(data: probeData, encoding: .utf8) else {
        kg_analysis_destroy(handle)
        print("[KataGo] startEngine probe JSON encode failed")
        iosEngineStarted = false
        katagoHandle = nil
        result(FlutterError(code: "START_ENGINE_FAILED", message: "Probe JSON encoding failed", details: nil))
        return
      }
      let probeCStr: UnsafeMutablePointer<CChar>? = probeJson.withCString { cReq in
        kg_analysis_analyze(handle, cReq)
      }
      guard let probeCStr = probeCStr else {
        kg_analysis_destroy(handle)
        print("[KataGo] startEngine probe failed: query_models returned nil")
        iosEngineStarted = false
        katagoHandle = nil
        result(FlutterError(code: "START_ENGINE_FAILED", message: "Engine probe failed (query_models nil)", details: nil))
        return
      }
      defer { kg_analysis_free_string(probeCStr) }
      let probeStr = String(cString: probeCStr)
      guard
        let probeRespData = probeStr.data(using: .utf8),
        let probeResp = try JSONSerialization.jsonObject(with: probeRespData) as? [String: Any]
      else {
        kg_analysis_destroy(handle)
        print("[KataGo] startEngine probe failed: invalid JSON")
        iosEngineStarted = false
        katagoHandle = nil
        result(FlutterError(code: "START_ENGINE_FAILED", message: "Engine probe invalid JSON", details: nil))
        return
      }
      let models = probeResp["models"] as? [[String: Any]] ?? []
      if models.isEmpty {
        kg_analysis_destroy(handle)
        let keys = probeResp.keys.joined(separator: ",")
        print("[KataGo] startEngine probe failed: models empty keys=\(keys) probe=\(probeStr)")
        iosEngineStarted = false
        katagoHandle = nil
        result(FlutterError(code: "START_ENGINE_FAILED", message: "Engine probe models empty", details: probeResp))
        return
      }

      let modelNames = models.compactMap { $0["name"] as? String }.joined(separator: ",")
      print("[KataGo] startEngine probe ok models=\(models.count) names=\(modelNames)")
      katagoHandle = handle
      iosEngineStarted = true
      print("[KataGo] startEngine ok")
      result(["started": true, "modelsLoaded": models.count])
    } catch {
      print("[KataGo] startEngine error: \(error.localizedDescription)")
      iosEngineStarted = false
      katagoHandle = nil
      result(
        FlutterError(
          code: "START_ENGINE_FAILED",
          message: error.localizedDescription,
          details: nil
        )
      )
    }
  }

  private func analyzeOnce(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard iosEngineStarted, let handle = katagoHandle else {
      print("[KataGo] analyzeOnce rejected: engine not running")
      result(
        FlutterError(
          code: "ENGINE_NOT_RUNNING",
          message: "KataGo iOS engine is not started.",
          details: "Call startEngine first."
        )
      )
      return
    }

    guard let args = call.arguments as? [String: Any] else {
      print("[KataGo] analyzeOnce bad args: nil")
      result(FlutterError(code: "BAD_ARGS", message: "analyzeOnce args are required", details: nil))
      return
    }

    let queryId = (args["queryId"] as? String) ?? "query-default"
    let maxVisits = (args["maxVisits"] as? Int) ?? 120
    let thinkingTimeMs = (args["thinkingTimeMs"] as? Int) ?? 1200
    var boardSize = (args["boardSize"] as? Int) ?? (args["boardSize"] as? NSNumber)?.intValue ?? 19
    let initialPlayer = (args["initialPlayer"] as? String) ?? "B"
    let komi = (args["komi"] as? Double) ?? (args["komi"] as? NSNumber)?.doubleValue ?? 7.5
    let ruleset = (args["ruleset"] as? String) ?? "chinese"
    let moves: [String] = normalizeMovesFromChannel(args["moves"])
    let initialStones: [String] = (args["initialStones"] as? [String]) ?? (args["initialStones"] as? [Any])?.compactMap { $0 as? String } ?? []
    let includeOwnership = (args["includeOwnership"] as? Bool) ?? false

    if boardSize < 2 || boardSize > 25 {
      print("[KataGo] analyzeOnce id=\(queryId) invalid boardSize=\(boardSize) (must be 2..25)")
      result(FlutterError(code: "BAD_ARGS", message: "boardSize must be 2..25, got \(boardSize)", details: nil))
      return
    }

    let parsedMoves = parseTokenArray(tokens: moves)
    if moves.count > 0 && parsedMoves.count == 0 {
      print("[KataGo] analyzeOnce id=\(queryId) moves format invalid: got \(moves.count) tokens but 0 parsed (expect 'B:Q16' style). first=\(moves.first ?? "")")
      result(FlutterError(code: "BAD_ARGS", message: "moves must be 'B:Q16' / 'W:D4' style pairs, got \(moves.count) unparseable", details: nil))
      return
    }

    print("[KataGo] analyzeOnce id=\(queryId) board=\(boardSize) moves=\(moves.count)->\(parsedMoves.count) initialStones=\(initialStones.count) initialPlayer=\(initialPlayer) rules=\(ruleset) maxVisits=\(maxVisits) maxTime=\(Double(thinkingTimeMs)/1000)s")

    var payload: [String: Any] = [
      "id": queryId,
      "rules": ruleset,
      "komi": komi,
      "boardXSize": boardSize,
      "boardYSize": boardSize,
      "initialPlayer": initialPlayer,
      "maxVisits": maxVisits,
      "moves": parsedMoves,
      "initialStones": parseTokenArray(tokens: initialStones),
    ]
    // This KataGo analysis protocol version does not accept top-level "maxTime".
    // Use overrideSettings so time budget still applies without triggering unused-field warnings.
    payload["overrideSettings"] = ["maxTime": Double(thinkingTimeMs) / 1000.0]
    payload["includeOwnership"] = includeOwnership

    if let arr = payload["moves"] as? [[String]], !arr.isEmpty {
      let head = arr.prefix(2).map { "[\($0.joined(separator: ","))]" }.joined(separator: " ")
      let tail = arr.count > 2 ? " …(\(arr.count) total)" : ""
      print("[KataGo] analyzeOnce id=\(queryId) payload.moves sample: \(head)\(tail)")
    }

    do {
      let data = try JSONSerialization.data(withJSONObject: payload)
      guard let requestJson = String(data: data, encoding: .utf8) else {
        result(FlutterError(code: "ANALYZE_FAILED", message: "Request JSON encoding failed", details: nil))
        return
      }
      let responseCStr: UnsafeMutablePointer<CChar>? = requestJson.withCString { cReq in
        kg_analysis_analyze(handle, cReq)
      }
      guard let responseCStr = responseCStr else {
        print("[KataGo] analyzeOnce id=\(queryId) engine returned nil (timeout or done)")
        result(FlutterError(code: "ANALYZE_FAILED", message: "Engine returned no response", details: nil))
        return
      }
      defer { kg_analysis_free_string(responseCStr) }
      let responseStr = String(cString: responseCStr)
      guard
        let responseData = responseStr.data(using: .utf8),
        let response = try JSONSerialization.jsonObject(with: responseData) as? [String: Any]
      else {
        print("[KataGo] analyzeOnce id=\(queryId) invalid JSON from engine")
        result(FlutterError(code: "ANALYZE_FAILED", message: "Invalid JSON from engine", details: nil))
        return
      }

      if let errorMsg = response["error"] as? String {
        print("[KataGo] analyzeOnce id=\(queryId) error=\(errorMsg)")
        result(
          FlutterError(
            code: "ENGINE_RESPONSE_ERROR",
            message: errorMsg,
            details: response
          )
        )
        return
      }

      if (response["noResults"] as? NSNumber)?.boolValue == true {
        print("[KataGo] analyzeOnce id=\(queryId) noResults=true")
        result(
          FlutterError(
            code: "ENGINE_NO_RESULTS",
            message: "KataGo returned no analysis (search may have been terminated or failed).",
            details: response
          )
        )
        return
      }

      let responseId = response["id"] as? String
      let rootInfo = response["rootInfo"] as? [String: Any]
      let moveInfos = response["moveInfos"] as? [[String: Any]]
      if rootInfo == nil || moveInfos == nil {
        let keys = response.keys.joined(separator: ",")
        let snippet = responseStr.count > 800 ? String(responseStr.prefix(800)) + "…" : responseStr
        print("[KataGo] analyzeOnce id=\(queryId) unexpected response shape id=\(responseId ?? "nil") keys=\(keys) snippet=\(snippet)")
        result(
          FlutterError(
            code: "ENGINE_UNEXPECTED_RESPONSE",
            message: "Engine response missing rootInfo or moveInfos",
            details: response
          )
        )
        return
      }
      let moveInfosCount = moveInfos?.count ?? 0
      let winrate = (rootInfo?["winrate"] as? NSNumber)?.doubleValue ?? 0.5
      let scoreLead = (rootInfo?["scoreLead"] as? NSNumber)?.doubleValue ?? 0.0
      let bestMove = (moveInfos?.first?["move"] as? String) ?? "pass"
      print("[KataGo] analyzeOnce id=\(queryId) bestMove=\(bestMove) winrate=\(String(format: "%.3f", winrate)) scoreLead=\(String(format: "%.1f", scoreLead)) moveInfos=\(moveInfosCount)) rootInfo=\(rootInfo != nil)")

      if moveInfosCount == 0 {
        let respKeys = response.keys.joined(separator: ",")
        let snippet = responseStr.count > 600 ? String(responseStr.prefix(600)) + "…" : responseStr
        print("[KataGo] analyzeOnce WARNING moveInfos empty! responseKeys=\(respKeys) snippet=\(snippet)")
      } else if bestMove == "pass" && moveInfosCount > 0 {
        let first = moveInfos?.first ?? [:]
        print("[KataGo] analyzeOnce first moveInfo keys=\(first.keys.joined(separator: ",")) move=\(first["move"] ?? "nil")")
      }

      var resultMap: [String: Any] = [
        "queryId": queryId,
        "bestMove": bestMove,
        "winrate": winrate,
        "scoreLead": scoreLead,
        "rawResponse": response
      ]
      if let ownershipAny = response["ownership"] as? [Any] {
        resultMap["ownership"] = ownershipAny.compactMap { ($0 as? NSNumber)?.doubleValue }
      }
      resultMap["_debugNativeMovesReceived"] = moves.count
      resultMap["_debugNativeMovesParsed"] = parsedMoves.count
      resultMap["_debugEngineResponseId"] = responseId
      resultMap["_debugRootInfoPresent"] = (rootInfo != nil)
      resultMap["_debugMoveInfosPresent"] = (moveInfos != nil)
      result(resultMap)
    } catch {
      print("[KataGo] analyzeOnce id=\(queryId) throw: \(error.localizedDescription)")
      result(FlutterError(code: "ANALYZE_FAILED", message: error.localizedDescription, details: nil))
    }
  }

  private func shutdownEngine(result: @escaping FlutterResult) {
    print("[KataGo] shutdownEngine")
    if let h = katagoHandle {
      kg_analysis_destroy(h)
      katagoHandle = nil
    }
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
    relativeDir: String
  ) throws -> URL {
    guard let assetFilePath = pathForFlutterAsset(assetPath: assetPath) else {
      throw NSError(
        domain: "mastergo.katago",
        code: 2001,
        userInfo: [NSLocalizedDescriptionKey: "Asset not found: \(assetPath)"]
      )
    }

    let targetDir = try ensureDirectory(relativePath: relativeDir)
    let fileName = URL(fileURLWithPath: assetPath).lastPathComponent
    let targetFile = targetDir.appendingPathComponent(fileName)
    try copyFileReplacing(from: URL(fileURLWithPath: assetFilePath), to: targetFile)
    return targetFile
  }

  private func copyFileReplacing(from source: URL, to target: URL) throws {
    if FileManager.default.fileExists(atPath: target.path) {
      try FileManager.default.removeItem(at: target)
    }
    try FileManager.default.copyItem(at: source, to: target)
  }

  /// Normalize moves from channel: accept [String] ("B:Q16") or [Any] of String, or [Any] of [String]/[Any] pairs.
  private func normalizeMovesFromChannel(_ raw: Any?) -> [String] {
    if let arr = raw as? [String] {
      return arr
    }
    guard let anyList = raw as? [Any] else { return [] }
    var out: [String] = []
    for item in anyList {
      if let s = item as? String {
        out.append(s)
        continue
      }
      if let pair = item as? [String], pair.count == 2 {
        out.append("\(pair[0]):\(pair[1])")
        continue
      }
      if let pair = item as? [Any], pair.count == 2,
         let a = pair[0] as? String, let b = pair[1] as? String {
        out.append("\(a):\(b)")
      }
    }
    return out
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
