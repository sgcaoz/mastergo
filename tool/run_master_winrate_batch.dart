// 在开发机本地跑名局每步胜率（maxVisits=10），规则以 SGF 为准。
// 每步追加一条日志到 tool/master_winrate_temp/batch.log；每局跑完生成 tool/master_winrate_temp/{gameId}.json；全部跑完再更新 seed DB。
// 运行：dart run tool/run_master_winrate_batch.dart
// 后台跑：nohup dart run tool/run_master_winrate_batch.dart >> tool/master_winrate_temp/console.log 2>&1 &
// 日志地址：tool/master_winrate_temp/batch.log
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'package:mastergo/domain/go/go_types.dart';
import 'package:mastergo/domain/sgf/sgf_parser.dart';

void main(List<String> args) async {
  final String projectRoot = Directory.current.path;
  final String seedPath =
      p.join(projectRoot, 'assets', 'master_games', 'mastergo_seed.db');
  final File seedFile = File(seedPath);
  if (!seedFile.existsSync()) {
    print('ERROR: seed DB not found at $seedPath');
    exit(1);
  }

  // 优先用项目内 iOS 模拟器用的 KataGo（同机可直接跑 analysis）
  final String projectKatago = p.join(
    projectRoot,
    'assets',
    'native',
    'ios',
    'simulator-arm64',
    'katago',
  );
  final String katagoBin = Platform.environment['KATAGO_BIN']?.trim().isNotEmpty == true
      ? Platform.environment['KATAGO_BIN']!
      : (File(projectKatago).existsSync() ? projectKatago : _which('katago') ?? '');
  final String modelPath = Platform.environment['KATAGO_MODEL']?.trim().isNotEmpty == true
      ? Platform.environment['KATAGO_MODEL']!
      : p.join(projectRoot, 'assets', 'models', 'katago', 'standard.bin.gz');
  if (katagoBin.isEmpty || !File(katagoBin).existsSync()) {
    print('ERROR: KataGo binary not found. Set KATAGO_BIN or put binary at $projectKatago');
    exit(1);
  }
  final File modelFile = File(modelPath);
  if (!modelFile.existsSync()) {
    print('ERROR: Model not found at $modelPath. Set KATAGO_MODEL.');
    exit(1);
  }

  final String tempDirPath =
      p.join(projectRoot, 'tool', 'master_winrate_temp');
  final Directory tempDir = Directory(tempDirPath);
  if (!tempDir.existsSync()) tempDir.createSync(recursive: true);
  final String progressPath = p.join(tempDirPath, 'progress.json');
  final String logPath = p.join(tempDirPath, 'batch.log');
  void appendLog(String line) {
    File(logPath).writeAsStringSync('$line\n', mode: FileMode.append);
  }
  appendLog('--- ${DateTime.now().toIso8601String()} 批次开始 ---');
  print('日志文件: $logPath');
  print('临时目录: $tempDirPath（每局跑完生成 {gameId}.json）');
  print('');

  final Database db = sqlite3.open(seedPath);
  final List<Map<String, dynamic>> rows = db.select(
    'SELECT id, sgf, ruleset, komi FROM game_records WHERE source = ?',
    ['master'],
  );

  final Map<String, Map<String, double>> results = {};
  final Set<String> completedIds = {};
  String? currentId;
  int currentTurn = 0;
  final File progressFile = File(progressPath);
  if (progressFile.existsSync()) {
    try {
      final Map<String, dynamic> prog =
          jsonDecode(progressFile.readAsStringSync()) as Map<String, dynamic>;
      completedIds.addAll(
        (prog['completedGameIds'] as List<dynamic>? ?? []).cast<String>(),
      );
      currentId = prog['currentGameId'] as String?;
      currentTurn = (prog['currentTurn'] as num?)?.toInt() ?? 0;
      final Map<String, dynamic>? r = prog['results'] as Map<String, dynamic>?;
      if (r != null) {
        for (final MapEntry<String, dynamic> e in r.entries) {
          final Map<String, dynamic>? m = e.value as Map<String, dynamic>?;
          if (m == null) continue;
          results[e.key] = m.map(
            (String k, dynamic v) =>
                MapEntry<String, double>(k, (v as num).toDouble()),
          );
        }
      }
    } catch (_) {}
  }

  final SgfParser parser = const SgfParser();
  final List<Map<String, dynamic>> todo = rows
      .where((Map<String, dynamic> r) =>
          !completedIds.contains(r['id'] as String?))
      .toList();

  if (todo.isEmpty) {
    appendLog('无待跑对局，直接写库');
    print('No games left to run. Writing results to DB...');
    _writeResultsToDb(db, results);
    db.dispose();
    print('日志: $logPath');
    exit(0);
  }

  final String configPath = Platform.environment['KATAGO_CONFIG'] ??
      p.join(tempDirPath, 'katago_batch.cfg');
  final File configFile = File(configPath);
  if (!configFile.existsSync()) {
    configFile.writeAsStringSync('''
numSearchThreadsPerAnalysisThread = 1
numAnalysisThreads = 1
maxVisits = 10
nnCacheSizePowerOfTwo = 18
reportAnalysisWinratesAs = BLACK
wideRootNoise = 0.0
''');
  }

  print('Starting KataGo: $katagoBin analysis -config $configPath -model $modelPath');
  final Process process = await Process.start(
    katagoBin,
    ['analysis', '-config', configPath, '-model', modelPath],
    workingDirectory: projectRoot,
    environment: Platform.environment,
    runInShell: false,
  );
  final Stream<String> stdoutLines = process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter());
  final List<String> pendingLines = [];
  stdoutLines.listen((String line) {
    pendingLines.add(line);
  });
  final IOSink stdin = process.stdin;

  /// 读一条 KataGo 分析结果（含 rootInfo），超时返回 null；出错抛异常。
  Future<String?> readOneResponse(String queryId, Duration timeout) async {
    final DateTime deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      for (int i = 0; i < pendingLines.length; i++) {
        final String line = pendingLines[i].trim();
        if (!line.startsWith('{')) continue;
        try {
          final Map<String, dynamic> obj =
              jsonDecode(line) as Map<String, dynamic>;
          final String? respId = obj['id'] as String?;
          if (respId != null && respId != queryId) continue;
          if (obj.containsKey('error')) {
            throw Exception(obj['error'].toString());
          }
          if (obj.containsKey('rootInfo')) {
            pendingLines.removeAt(i);
            return line;
          }
        } catch (_) {}
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return null;
  }

  String rulesToKataGo(String rules) {
    final String r = rules.trim().toLowerCase();
    if (r.contains('japanese') || r == 'japanese') return 'japanese';
    if (r.contains('korean') || r == 'korean') return 'korean';
    if (r.contains('chinese') || r == 'chinese') return 'chinese';
    if (r.contains('classical') || r.contains('ancient') || r == 'tromp-taylor')
      return 'tromp-taylor';
    return 'chinese';
  }

  List<List<String>> tokenToKataGoMoves(List<String> moveTokens, int boardSize) {
    final List<List<String>> out = [];
    for (final String t in moveTokens) {
      final int colon = t.indexOf(':');
      if (colon < 0) continue;
      final String color = t.substring(0, colon).toUpperCase();
      final String rest = t.substring(colon + 1).trim().toUpperCase();
      if (rest == 'PASS' || rest.isEmpty) {
        out.add([color, 'pass']);
        continue;
      }
      out.add([color, rest]);
    }
    return out;
  }

  List<List<String>> initialStonesToKataGo(
    List<GoPoint> black, List<GoPoint> white, int boardSize,
  ) {
    const String columns = 'ABCDEFGHJKLMNOPQRSTUVWXYZ';
    final List<List<String>> out = [];
    for (final GoPoint pt in black) {
      final String col = columns[pt.x];
      final int row = boardSize - pt.y;
      out.add(['B', '$col$row']);
    }
    for (final GoPoint pt in white) {
      final String col = columns[pt.x];
      final int row = boardSize - pt.y;
      out.add(['W', '$col$row']);
    }
    return out;
  }

  for (int gameIndex = 0; gameIndex < todo.length; gameIndex++) {
    final Map<String, dynamic> row = todo[gameIndex];
    final String id = row['id'] as String;
    final String sgfContent = row['sgf'] as String;
    currentId = id;

    SgfGame sgf;
    try {
      sgf = parser.parse(sgfContent);
    } catch (e) {
      appendLog('${DateTime.now().toIso8601String()}  $id  Parse SGF 失败: $e');
      print('Parse SGF failed $id: $e');
      completedIds.add(id);
      results[id] = <String, double>{};
      _saveProgress(progressPath, completedIds, currentId, 0, results);
      continue;
    }

    final List<SgfNode> mainLine = sgf.mainLineNodes();
    final int numTurns = mainLine.length;
    final List<String> moveTokens = [];
    for (final SgfNode node in mainLine) {
      if (node.move != null) {
        moveTokens.add(node.move!.toProtocolToken(sgf.boardSize));
      }
    }
    final List<List<String>> kataGoMoves =
        tokenToKataGoMoves(moveTokens, sgf.boardSize);
    final List<List<String>> initialStones = initialStonesToKataGo(
      sgf.initialBlackStones,
      sgf.initialWhiteStones,
      sgf.boardSize,
    );
    final String rules = rulesToKataGo(sgf.rules);
    final double komi = sgf.komi;

    Map<String, double> gameWinrates = results[id] ?? <String, double>{};
    int startTurn = 0;
    if (currentId == id && currentTurn > 0) startTurn = currentTurn;

    final List<int> analyzeTurns =
        List<int>.generate(numTurns - startTurn + 1, (int i) => startTurn + i);
    if (analyzeTurns.isEmpty) {
      completedIds.add(id);
      _saveProgress(progressPath, completedIds, null, 0, results);
      continue;
    }

    final String queryId = 'q-$id-${DateTime.now().millisecondsSinceEpoch}';
    final Map<String, dynamic> query = <String, dynamic>{
      'id': queryId,
      'boardXSize': sgf.boardSize,
      'boardYSize': sgf.boardSize,
      'rules': rules,
      'komi': komi,
      'maxVisits': 10,
      'moves': kataGoMoves,
      'initialStones': initialStones,
      'analyzeTurns': analyzeTurns,
    };
    stdin.writeln(jsonEncode(query));
    await stdin.flush();

    final Set<int> receivedTurns = {};
    while (receivedTurns.length < analyzeTurns.length) {
      final String? resp =
          await readOneResponse(queryId, const Duration(seconds: 120));
      if (resp == null) {
        appendLog('TIMEOUT $id ${receivedTurns.length}/${analyzeTurns.length}');
        print('Timeout waiting for KataGo response $id (got ${receivedTurns.length}/${analyzeTurns.length})');
        currentTurn = analyzeTurns.isNotEmpty ? analyzeTurns[receivedTurns.length] : 0;
        _saveProgress(progressPath, completedIds, currentId, currentTurn, results);
        db.dispose();
        process.kill();
        exit(1);
      }
      final Map<String, dynamic> obj =
          jsonDecode(resp) as Map<String, dynamic>;
      final int turnNum = (obj['turnNumber'] as num?)?.toInt() ?? 0;
      final Map<String, dynamic>? rootInfo =
          obj['rootInfo'] as Map<String, dynamic>?;
      final double wr = (rootInfo?['winrate'] as num?)?.toDouble() ?? 0.5;
      if (!receivedTurns.contains(turnNum)) {
        receivedTurns.add(turnNum);
        gameWinrates['$turnNum'] = wr;
        results[id] = gameWinrates;
        final String logLine =
            '${DateTime.now().toIso8601String()}  $id  第${turnNum}步  胜率 ${(wr * 100).toStringAsFixed(1)}%';
        appendLog(logLine);
        if (receivedTurns.length % 20 == 0 || receivedTurns.length == analyzeTurns.length) {
          print('  $id turns ${receivedTurns.length}/${analyzeTurns.length}');
          _saveProgress(progressPath, completedIds, currentId, turnNum + 1, results);
        }
      }
    }

    completedIds.add(id);
    currentTurn = 0;
    _saveProgress(progressPath, completedIds, null, 0, results);
    final String gameJsonPath = p.join(tempDirPath, '$id.json');
    File(gameJsonPath).writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(
        gameWinrates.map((String k, double v) => MapEntry<String, dynamic>(k, v)),
      ),
    );
    appendLog('${DateTime.now().toIso8601String()}  完成对局 $id  临时文件 $gameJsonPath');
    print('Done game ${gameIndex + 1}/${todo.length}: $id -> $gameJsonPath');
  }

  process.stdin.close();
  await process.exitCode;

  appendLog('--- ${DateTime.now().toIso8601String()} 全部跑完，更新数据库 ---');
  _writeResultsToDb(db, results);
  db.dispose();
  print('All done. Winrate data written to seed DB.');
  print('日志地址: $logPath');
}

String? _which(String cmd) {
  try {
    final ProcessResult r = Process.runSync('which', [cmd], runInShell: true);
    if (r.exitCode == 0 && r.stdout.toString().trim().isNotEmpty) {
      return r.stdout.toString().trim().split('\n').first.trim();
    }
  } catch (_) {}
  return null;
}

void _saveProgress(
  String path,
  Set<String> completedIds,
  String? currentId,
  int currentTurn,
  Map<String, Map<String, double>> results,
) {
  final Map<String, dynamic> json = <String, dynamic>{
    'completedGameIds': completedIds.toList(),
    'currentGameId': currentId,
    'currentTurn': currentTurn,
    'results': results.map(
      (String k, Map<String, double> v) =>
          MapEntry<String, dynamic>(k, v.map((String a, double b) => MapEntry<String, dynamic>(a, b))),
    ),
  };
  File(path).writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(json),
  );
}

void _writeResultsToDb(Database db, Map<String, Map<String, double>> results) {
  final int now = DateTime.now().millisecondsSinceEpoch;
  for (final String gameId in results.keys) {
    final Map<String, double>? winrates = results[gameId];
    if (winrates == null || winrates.isEmpty) continue;
    final String winrateJson = jsonEncode(
      winrates.map((String k, double v) => MapEntry<String, dynamic>(k, v)),
    );
    db.execute(
      'UPDATE game_records SET winrateJson = ?, updatedAtMs = ? WHERE id = ?',
      [winrateJson, now, gameId],
    );
  }
}
