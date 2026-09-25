package com.boringtime.mastergo

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import android.util.Log
import io.flutter.FlutterInjector
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedReader
import java.io.BufferedWriter
import java.io.File
import java.io.InputStreamReader
import java.security.MessageDigest
import java.util.Locale
import java.util.concurrent.Executors
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

class MainActivity : FlutterActivity() {
    private val logTag = "MasterGo/KataGo"

    companion object {
        @Volatile
        var pendingOpenUri: Uri? = null
    }

    private val channelName = "mastergo/katago"
    private val fileOpenerChannelName = "mastergo/file_opener"
    private val engineExecutor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    private var katagoProcess: Process? = null
    private var katagoStdin: BufferedWriter? = null
    private var katagoStdout: BufferedReader? = null
    private val stdoutLines = LinkedBlockingQueue<String>()
    private var stdoutPump: Thread? = null

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        saveIntentUri(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        saveIntentUri(intent)
    }

    private fun saveIntentUri(intent: Intent?) {
        val uri = intent?.data ?: return
        when (uri.scheme) {
            "file" -> if (uri.path?.lowercase(Locale.US)?.endsWith(".sgf") == true) {
                pendingOpenUri = uri
            }
            "content" -> pendingOpenUri = uri
            else -> { }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, fileOpenerChannelName)
            .setMethodCallHandler { call, result ->
                if (call.method == "getInitialOpenedSgf") {
                    engineExecutor.execute {
                        try {
                            val uri = pendingOpenUri
                            pendingOpenUri = null
                            if (uri == null) {
                                mainHandler.post { result.success(null) }
                                return@execute
                            }
                            val (content, fileName) = readUriToSgfContent(uri)
                            if (content == null) {
                                mainHandler.post { result.success(null) }
                                return@execute
                            }
                            mainHandler.post {
                                result.success(mapOf("content" to content, "fileName" to fileName))
                            }
                        } catch (e: Exception) {
                            mainHandler.post {
                                result.error("READ_FAILED", e.message, null)
                            }
                        }
                    }
                } else {
                    mainHandler.post { result.notImplemented() }
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call: MethodCall, result: MethodChannel.Result ->
                if (call.method == "prepareModel" ||
                    call.method == "startEngine" ||
                    call.method == "analyzeOnce" ||
                    call.method == "shutdownEngine"
                ) {
                    // All heavy engine calls run off the UI thread to avoid frame drops/white screen.
                    engineExecutor.execute {
                        when (call.method) {
                            "prepareModel" -> prepareModel(call, result)
                            "startEngine" -> startEngine(call, result)
                            "analyzeOnce" -> analyzeOnce(call, result)
                            "shutdownEngine" -> shutdownEngine(result)
                        }
                    }
                } else {
                    mainHandler.post { result.notImplemented() }
                }
            }
    }

    override fun onDestroy() {
        engineExecutor.execute {
            cleanupEngineState()
        }
        engineExecutor.shutdownNow()
        super.onDestroy()
    }

    private fun prepareModel(call: MethodCall, result: MethodChannel.Result) {
        try {
            val modelAssetPath = call.argument<String>("modelAssetPath")
                ?: run {
                    mainHandler.post { result.error("BAD_ARGS", "modelAssetPath is required", null) }
                    return
                }
            val modelSha256 = call.argument<String>("modelSha256")?.lowercase(Locale.US)

            val outputDir = File(filesDir, "katago/models").apply { mkdirs() }
            val outputFile = File(outputDir, modelAssetPath.substringAfterLast('/'))

            // Skip copy if file already exists and hash matches (normal startup <10s after first run).
            if (outputFile.exists()) {
                val existingSha = sha256(outputFile)
                if (modelSha256 == null || modelSha256 == existingSha.lowercase(Locale.US)) {
                    mainHandler.post {
                        result.success(
                            mapOf(
                                "modelPath" to outputFile.absolutePath,
                                "sha256" to existingSha
                            )
                        )
                    }
                    return
                }
            }

            copyAssetToFile(modelAssetPath, outputFile)

            val actualSha = sha256(outputFile)
            if (modelSha256 != null && modelSha256 != actualSha.lowercase(Locale.US)) {
                mainHandler.post {
                    result.error(
                        "MODEL_HASH_MISMATCH",
                        "Expected sha256=$modelSha256 but got $actualSha",
                        null
                    )
                }
                return
            }

            mainHandler.post {
                result.success(
                    mapOf(
                        "modelPath" to outputFile.absolutePath,
                        "sha256" to actualSha
                    )
                )
            }
        } catch (e: Exception) {
            mainHandler.post { result.error("PREPARE_MODEL_FAILED", e.message, null) }
        }
    }

    private fun startEngine(call: MethodCall, result: MethodChannel.Result) {
        try {
            val modelPath = call.argument<String>("modelPath")
                ?: run {
                    mainHandler.post { result.error("BAD_ARGS", "modelPath is required", null) }
                    return
                }
            val configAssetPath = call.argument<String>("configAssetPath")
                ?: run {
                    mainHandler.post { result.error("BAD_ARGS", "configAssetPath is required", null) }
                    return
                }

            val configDir = File(filesDir, "katago/config").apply { mkdirs() }
            val configFile = File(configDir, configAssetPath.substringAfterLast('/'))
            copyAssetToFile(configAssetPath, configFile)

            val binaryFile = resolveKatagoExecutablePath()
            if (!binaryFile.exists()) {
                mainHandler.post {
                    result.error(
                        "BINARY_NOT_FOUND",
                        "KataGo executable not found in jniLibs",
                        mapOf(
                            "nativeLibPath" to binaryFile.absolutePath,
                            "nativeLibraryDir" to applicationInfo.nativeLibraryDir,
                            "abi" to Build.SUPPORTED_ABIS.joinToString(","),
                            "note" to "Run ./scripts/android/build_katago_android.sh before building"
                        )
                    )
                }
                return
            }
            if (!binaryFile.canExecute()) {
                try {
                    binaryFile.setExecutable(true)
                } catch (_: Exception) {
                    // Some system-managed native library dirs are readonly.
                }
            }

            if (katagoProcess?.isAlive == true) {
                mainHandler.post { result.success(mapOf("started" to true)) }
                return
            }

            val process = ProcessBuilder(
                binaryFile.absolutePath,
                "analysis",
                "-config", configFile.absolutePath,
                "-model", modelPath
            )
                .apply {
                    environment()["LD_LIBRARY_PATH"] = applicationInfo.nativeLibraryDir
                }
                .directory(filesDir)
                .redirectErrorStream(true)
                .start()

            katagoProcess = process
            katagoStdin = process.outputStream.bufferedWriter()
            katagoStdout = BufferedReader(InputStreamReader(process.inputStream))
            startStdoutPump()
            Thread.sleep(250)
            if (katagoProcess?.isAlive != true) {
                val startupLogs = readAnyLinesWithin(1200)
                val exitCode = try {
                    katagoProcess?.exitValue()
                } catch (_: Exception) {
                    null
                }
                cleanupEngineState()
                mainHandler.post {
                    result.error(
                        "ENGINE_STARTUP_FAILED",
                        "KataGo process exited immediately after start",
                        mapOf(
                            "logs" to startupLogs.ifEmpty { "<no startup logs>" },
                            "exitCode" to exitCode,
                            "binaryPath" to binaryFile.absolutePath,
                            "modelPath" to modelPath,
                            "configPath" to configFile.absolutePath
                        )
                    )
                }
                return
            }

            mainHandler.post { result.success(mapOf("started" to true)) }
        } catch (e: Exception) {
            mainHandler.post { result.error("START_ENGINE_FAILED", e.message, null) }
        }
    }

    private fun analyzeOnce(call: MethodCall, result: MethodChannel.Result) {
        try {
            if (katagoProcess?.isAlive != true) {
                mainHandler.post { result.error("ENGINE_NOT_RUNNING", "KataGo engine is not started", null) }
                return
            }

            val queryId = call.argument<String>("queryId") ?: "query-default"
            val maxVisits = call.argument<Int>("maxVisits") ?: 120
            val thinkingTimeMs = call.argument<Int>("thinkingTimeMs") ?: 1200
            val timeoutOverrideMs = call.argument<Int>("timeoutMs")
            val boardSize = call.argument<Int>("boardSize") ?: 19
            val initialPlayer = call.argument<String>("initialPlayer") ?: "B"
            val komi = call.argument<Double>("komi") ?: 7.5
            val ruleset = call.argument<String>("ruleset") ?: "chinese"
            val moveTokens = call.argument<List<String>>("moves") ?: emptyList()
            val initialStones = call.argument<List<String>>("initialStones") ?: emptyList()
            val includeOwnership = call.argument<Boolean>("includeOwnership") ?: false
            @Suppress("UNCHECKED_CAST")
            val analyzeTurns = (call.argument<List<*>>("analyzeTurns") ?: emptyList<Any>())
                .mapNotNull { (it as? Number)?.toInt() }

            val queryObj = JSONObject().apply {
                put("id", queryId)
                put("rules", ruleset)
                put("komi", komi)
                put("boardXSize", boardSize)
                put("boardYSize", boardSize)
                put("initialPlayer", initialPlayer)
                put("maxVisits", maxVisits)
                // This KataGo build rejects top-level maxTime and may never answer.
                put("overrideSettings", JSONObject().apply {
                    put("maxTime", thinkingTimeMs / 1000.0)
                })
                put("moves", parseTokenArray(moveTokens))
                put("initialStones", parseTokenArray(initialStones))
                put("includeOwnership", includeOwnership)
                if (analyzeTurns.isNotEmpty()) {
                    put("analyzeTurns", JSONArray(analyzeTurns))
                }
                val allowMoves = toAllowMovesJson(call.argument<List<*>>("allowMoves"))
                if (allowMoves.length() > 0) {
                    put("allowMoves", allowMoves)
                }
            }
            val query = queryObj.toString()

            katagoStdin?.apply {
                write(query)
                newLine()
                flush()
            }

            val expectedCount = if (analyzeTurns.isEmpty()) 1 else analyzeTurns.size
            val timeoutMs = timeoutOverrideMs?.toLong()
                ?: (thinkingTimeMs.toLong() * 2L * expectedCount)
            val responses = readJsonResponsesByQueryId(queryId, expectedCount, timeoutMs)
            if (responses.isEmpty()) {
                if (katagoProcess?.isAlive != true) {
                    mainHandler.post { result.error("ENGINE_DIED", "KataGo process exited during analysis", null) }
                    return
                }
                val tail = readAnyLinesWithin(1200).ifEmpty { "<no output>" }
                mainHandler.post {
                    result.error(
                        "ENGINE_TIMEOUT",
                        "No valid JSON response from engine within ${timeoutMs}ms",
                        mapOf("queryId" to queryId, "timeoutMs" to timeoutMs, "engineOutputTail" to tail)
                    )
                }
                return
            }
            val errorResponse = responses.firstOrNull { it.has("error") }
            if (errorResponse != null) {
                mainHandler.post {
                    result.error(
                        "ENGINE_RESPONSE_ERROR",
                        errorResponse.optString("error", "Unknown KataGo error"),
                        errorResponse.toString()
                    )
                }
                return
            }

            if (analyzeTurns.isEmpty()) {
                mainHandler.post { result.success(toAnalyzeResultMap(queryId, responses.first())) }
                return
            }
            val resultMaps = responses.map { toAnalyzeResultMap(queryId, it) }
            mainHandler.post {
                result.success(
                    mapOf(
                        "queryId" to queryId,
                        "results" to resultMaps,
                    )
                )
            }
        } catch (e: Exception) {
            mainHandler.post { result.error("ANALYZE_FAILED", e.message, null) }
        }
    }

    private fun shutdownEngine(result: MethodChannel.Result) {
        try {
            cleanupEngineState()
            mainHandler.post { result.success(null) }
        } catch (e: Exception) {
            mainHandler.post { result.error("SHUTDOWN_FAILED", e.message, null) }
        }
    }

    private fun copyAssetToFile(assetPath: String, outputFile: File) {
        val flutterAssetKey = FlutterInjector.instance()
            .flutterLoader()
            .getLookupKeyForAsset(assetPath)
        val candidateKeys = listOf(
            flutterAssetKey,
            assetPath,
            assetPath.removePrefix("assets/")
        ).distinct()

        var lastError: Exception? = null
        for (key in candidateKeys) {
            try {
                assets.open(key).use { input ->
                    outputFile.outputStream().use { output ->
                        input.copyTo(output)
                    }
                }
                return
            } catch (e: Exception) {
                lastError = e
            }
        }
        throw IllegalStateException(
            "Unable to open asset: $assetPath, tried keys=$candidateKeys",
            lastError
        )
    }

    /** KataGo executable: only from jniLibs → nativeLibraryDir/libkatago.so. Build with scripts/android/build_katago_android.sh first. */
    private fun resolveKatagoExecutablePath(): File {
        return File(applicationInfo.nativeLibraryDir, "libkatago.so")
    }

    private fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(8192)
            var read = input.read(buffer)
            while (read != -1) {
                digest.update(buffer, 0, read)
                read = input.read(buffer)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    private fun startStdoutPump() {
        stdoutPump?.interrupt()
        stdoutLines.clear()
        val reader = katagoStdout ?: return
        val pump = Thread({
            try {
                while (!Thread.currentThread().isInterrupted) {
                    val line = reader.readLine() ?: break
                    stdoutLines.offer(line)
                }
            } catch (_: Exception) {
            }
        }, "katago-stdout")
        pump.isDaemon = true
        stdoutPump = pump
        pump.start()
    }

    private fun readLineWithTimeout(timeoutMs: Long): String? {
        return try {
            stdoutLines.poll(timeoutMs, TimeUnit.MILLISECONDS)
        } catch (_: InterruptedException) {
            null
        }
    }

    private fun readAnyLinesWithin(timeoutMs: Long): String {
        val start = System.currentTimeMillis()
        val lines = mutableListOf<String>()
        while (System.currentTimeMillis() - start < timeoutMs) {
            val line = readLineWithTimeout(120)
            if (line.isNullOrBlank()) {
                continue
            }
            lines.add(line)
            if (lines.size >= 8) {
                break
            }
        }
        return lines.joinToString("\n")
    }

    private fun cleanupEngineState() {
        try {
            katagoStdin?.close()
        } catch (_: Exception) {
        }
        try {
            katagoStdout?.close()
        } catch (_: Exception) {
        }
        katagoProcess?.destroy()
        katagoProcess?.waitFor(1, TimeUnit.SECONDS)
        stdoutPump?.interrupt()
        stdoutPump = null
        stdoutLines.clear()
        katagoStdin = null
        katagoStdout = null
        katagoProcess = null
    }

    private fun toAnalyzeResultMap(queryId: String, response: JSONObject): Map<String, Any?> {
        val rootInfo = response.optJSONObject("rootInfo")
        val moveInfos = response.optJSONArray("moveInfos")
        val winrate = rootInfo?.optDouble("winrate", 0.5) ?: 0.5
        val scoreLead = rootInfo?.optDouble("scoreLead", 0.0) ?: 0.0
        val bestMove = if (moveInfos != null && moveInfos.length() > 0) {
            moveInfos.getJSONObject(0).optString("move", "pass")
        } else {
            "pass"
        }
        val ownershipList = mutableListOf<Double>()
        response.optJSONArray("ownership")?.let { arr ->
            for (i in 0 until arr.length()) {
                ownershipList.add(arr.optDouble(i, 0.0))
            }
        }
        val resultMap = mutableMapOf<String, Any?>(
            "queryId" to queryId,
            "bestMove" to bestMove,
            "winrate" to winrate,
            "scoreLead" to scoreLead,
            "turnNumber" to response.optInt("turnNumber", 0),
            "rawResponse" to response.toString()
        )
        if (ownershipList.isNotEmpty()) {
            resultMap["ownership"] = ownershipList
        }
        return resultMap
    }

    private fun readJsonResponseByQueryId(queryId: String, timeoutMs: Long): JSONObject? {
        return readJsonResponsesByQueryId(queryId, 1, timeoutMs).firstOrNull()
    }

    private fun readJsonResponsesByQueryId(
        queryId: String,
        expectedCount: Int,
        timeoutMs: Long
    ): List<JSONObject> {
        val found = mutableListOf<JSONObject>()
        val seenTurns = mutableSetOf<Int>()
        val start = System.currentTimeMillis()
        while (found.size < expectedCount && System.currentTimeMillis() - start < timeoutMs) {
            val line = readLineWithTimeout(300)
            if (line.isNullOrBlank()) {
                continue
            }
            val trimmed = line.trim()
            if (!trimmed.startsWith("{")) {
                continue
            }
            try {
                val obj = JSONObject(trimmed)
                val id = obj.opt("id")?.toString() ?: ""
                val hasError = obj.has("error")
                val hasRootInfo = obj.has("rootInfo")
                if (id.isNotEmpty() && id != queryId) {
                    continue
                }
                if (obj.has("warning") && !hasRootInfo && !hasError) {
                    continue
                }
                if (hasError) {
                    found.add(obj)
                    break
                }
                if (obj.optBoolean("isDuringSearch", false)) {
                    continue
                }
                if (hasRootInfo) {
                    val turn = if (obj.has("turnNumber")) obj.optInt("turnNumber") else found.size
                    if (seenTurns.add(turn) || expectedCount == 1) {
                        found.add(obj)
                    }
                }
            } catch (_: Exception) {
                // Skip non-JSON logs and malformed lines.
            }
        }
        return found
    }

    private fun toAllowMovesJson(raw: List<*>?): JSONArray {
        val arr = JSONArray()
        if (raw == null) {
            return arr
        }
        for (item in raw) {
            val map = item as? Map<*, *> ?: continue
            val movesRaw = map["moves"] as? List<*> ?: continue
            val moves = JSONArray()
            for (move in movesRaw) {
                if (move is String && move.isNotEmpty()) {
                    moves.put(move)
                }
            }
            if (moves.length() == 0) {
                continue
            }
            arr.put(
                JSONObject().apply {
                    put("player", map["player"] as? String ?: "B")
                    put("untilDepth", (map["untilDepth"] as? Number)?.toInt() ?: 20)
                    put("moves", moves)
                }
            )
        }
        return arr
    }

    private fun parseTokenArray(tokens: List<String>): JSONArray {
        val arr = JSONArray()
        for (token in tokens) {
            val parts = token.split(":")
            if (parts.size != 2) {
                continue
            }
            arr.put(JSONArray().apply {
                put(parts[0])
                put(parts[1])
            })
        }
        return arr
    }

    private val maxOpenedSgfBytes = 2 * 1024 * 1024

    private fun readUriToSgfContent(uri: Uri): Pair<String?, String> {
        val fileName = when (uri.scheme) {
            "file" -> uri.lastPathSegment?.takeIf { it.lowercase(Locale.US).endsWith(".sgf") } ?: "opened.sgf"
            "content" -> run {
                contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                    val nameIdx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (nameIdx >= 0 && cursor.moveToFirst()) {
                        cursor.getString(nameIdx) ?: "opened.sgf"
                    } else "opened.sgf"
                } ?: "opened.sgf"
            }
            else -> "opened.sgf"
        }
        val content = when (uri.scheme) {
            "file" -> {
                val path = uri.path ?: return Pair(null, fileName)
                try {
                    val file = File(path)
                    if (!file.isFile || file.length() > maxOpenedSgfBytes) {
                        return Pair(null, fileName)
                    }
                    file.readText(Charsets.UTF_8)
                } catch (_: Exception) {
                    return Pair(null, fileName)
                }
            }
            "content" -> {
                try {
                    contentResolver.openInputStream(uri)?.use { input ->
                        val buffer = java.io.ByteArrayOutputStream()
                        val chunk = ByteArray(8192)
                        var total = 0
                        while (true) {
                            val n = input.read(chunk)
                            if (n < 0) {
                                break
                            }
                            total += n
                            if (total > maxOpenedSgfBytes) {
                                return Pair(null, fileName)
                            }
                            buffer.write(chunk, 0, n)
                        }
                        buffer.toByteArray().decodeToString()
                    }
                } catch (_: Exception) {
                    null
                }
            }
            else -> null
        }
        val safeContent = content ?: return Pair(null, fileName)
        if (!fileName.lowercase(Locale.US).endsWith(".sgf") && !looksLikeSgfContent(safeContent)) {
            return Pair(null, fileName)
        }
        return Pair(safeContent, fileName)
    }

    private fun looksLikeSgfContent(content: String): Boolean {
        val trimmed = content.trimStart()
        if (trimmed.isEmpty()) {
            return false
        }
        return trimmed.startsWith("(;") || trimmed.startsWith("(")
    }
}
