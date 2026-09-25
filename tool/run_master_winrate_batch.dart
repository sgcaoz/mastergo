// 后台长程：给 seed 库里每一盘名局算每步黑方胜率，按该盘的规则/贴目（古谱 classical、贴目 0）。
// 每盘写完立刻落库，中断后可续跑。
//
//   dart run tool/run_master_winrate_batch.dart
//   ./tool/run_master_winrate_background.sh
//
// 环境变量：KATAGO_BIN、KATAGO_MODEL、MASTER_VISITS（默认 10）、MASTER_CHUNK（默认 12）
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mastergo/application/batch/master_winrate_checkpoint.dart';
import 'package:mastergo/application/batch/master_winrate_rules.dart';
import 'package:mastergo/domain/go/go_types.dart';
import 'package:mastergo/domain/sgf/sgf_parser.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

const int _maxRetries = 3;
const Duration _perResponseTimeout = Duration(seconds: 180);

Future<void> main(List<String> args) async {
  final String projectRoot = Directory.current.path;
  final String seedPath =
      p.join(projectRoot, 'assets', 'master_games', 'mastergo_seed.db');
  final File seedFile = File(seedPath);
  if (!seedFile.existsSync()) {
    stderr.writeln('ERROR: seed DB not found at $seedPath');
    exit(1);
  }

  final String katagoBin = _resolveKatagoBin(projectRoot);
  final String modelPath = Platform.environment['KATAGO_MODEL']?.trim().isNotEmpty == true
      ? Platform.environment['KATAGO_MODEL']!
      : p.join(projectRoot, 'assets', 'models', 'katago', 'standard.bin.gz');
  if (!File(katagoBin).existsSync()) {
    stderr.writeln('ERROR: KataGo binary not found: $katagoBin');
    exit(1);
  }
  if (!File(modelPath).existsSync()) {
    stderr.writeln('ERROR: model not found: $modelPath');
    exit(1);
  }

  final int visits = _positiveEnv('MASTER_VISITS', 10);
  final int chunkSize = _positiveEnv('MASTER_CHUNK', 12);
  final String tempDirPath = p.join(projectRoot, 'tool', 'master_winrate_temp');
  Directory(tempDirPath).createSync(recursive: true);
  final File progressFile = File(p.join(tempDirPath, 'progress.json'));
  final File statusFile = File(p.join(tempDirPath, 'status.json'));
  final File logFile = File(p.join(tempDirPath, 'batch.log'));
  final File pidFile = File(p.join(tempDirPath, 'batch.pid'));
  final File configFile = File(p.join(tempDirPath, 'katago_batch.cfg'));

  if (!_acquirePidLock(pidFile)) {
    stderr.writeln('ERROR: another batch is running (see $pidFile)');
    exit(1);
  }

  void log(String line) {
    final String stamped = '${DateTime.now().toIso8601String()}  $line';
    logFile.writeAsStringSync('$stamped\n', mode: FileMode.append);
    stdout.writeln(stamped);
  }

  configFile.writeAsStringSync('''
numSearchThreadsPerAnalysisThread = 8
numAnalysisThreads = 1
nnMaxBatchSize = 16
maxVisits = $visits
nnCacheSizePowerOfTwo = 20
reportAnalysisWinratesAs = BLACK
wideRootNoise = 0.0
''');

  final Database db = sqlite3.open(seedPath);
  final MasterWinrateProgress progress = MasterWinrateProgress.load(progressFile);
  final _KatagoAnalysis engine = _KatagoAnalysis(
    bin: katagoBin,
    config: configFile.path,
    model: modelPath,
    cwd: projectRoot,
  );

  var shuttingDown = false;
  Future<void> shutdown({required int code}) async {
    if (shuttingDown) {
      return;
    }
    shuttingDown = true;
    _saveProgress(progressFile, progress);
    engine.kill();
    db.close();
    _releasePidLock(pidFile);
    exit(code);
  }

  ProcessSignal.sigint.watch().listen((_) {
    log('收到中断，保存进度后退出');
    unawaited(shutdown(code: 0));
  });
  if (!Platform.isWindows) {
    ProcessSignal.sigterm.watch().listen((_) {
      log('收到 SIGTERM，保存进度后退出');
      unawaited(shutdown(code: 0));
    });
  }

  log('批次开始  visits=$visits chunk=$chunkSize  bin=$katagoBin');
  try {
    await engine.start();
  } catch (e) {
    log('启动 KataGo 失败: $e');
    await shutdown(code: 1);
    return;
  }

  final List<Map<String, dynamic>> rows = db.select(
    'SELECT id, title, sgf, ruleset, komi, sessionJson, winrateJson '
    'FROM game_records WHERE source = ? ORDER BY id',
    ['master'],
  );
  log('名局总数 ${rows.length}');

  int completed = 0;
  int skipped = 0;
  int failed = 0;
  var wroteAny = false;

  for (int index = 0; index < rows.length; index++) {
    final Map<String, dynamic> row = rows[index];
    final String id = row['id'] as String;
    final String title = row['title'] as String? ?? id;
    final String category = _categoryOf(row['sessionJson'] as String? ?? '');
    final MasterWinrateEngineRules rules = resolveMasterWinrateRules(
      dbRuleset: row['ruleset'] as String? ?? '',
      dbKomi: (row['komi'] as num?)?.toDouble() ?? 0,
      category: category,
    );

    SgfGame sgf;
    try {
      sgf = const SgfParser().parse(row['sgf'] as String);
    } catch (e) {
      log('SKIP $id  SGF 解析失败: $e');
      progress.failed[id] = 'parse: $e';
      _saveProgress(progressFile, progress);
      failed += 1;
      continue;
    }

    final List<String> moveTokens = <String>[
      for (final SgfNode node in sgf.mainLineNodes())
        if (node.move != null) node.move!.toProtocolToken(sgf.boardSize),
    ];
    final int totalMoves = moveTokens.length;
    final File gameFile = File(p.join(tempDirPath, '$id.json'));

    if (progress.completedGameIds.contains(id) ||
        _dbWinrateComplete(row['winrateJson'] as String? ?? '', totalMoves)) {
      skipped += 1;
      completed += 1;
      progress.completedGameIds.add(id);
      continue;
    }

    var checkpoint = MasterWinrateGameCheckpoint.tryLoad(gameFile);
    if (checkpoint != null && !checkpoint.matches(rules, totalMoves)) {
      log('$id  规则/手数与存档不一致，重跑');
      checkpoint = null;
    }
    checkpoint ??= MasterWinrateGameCheckpoint(
      id: id,
      presetId: rules.presetId,
      kataGoRules: rules.kataGoRules,
      komi: rules.komi,
      category: rules.category,
      totalMoves: totalMoves,
      winrates: <int, double>{},
    );
    final MasterWinrateGameCheckpoint game = checkpoint;

    if (game.isComplete) {
      _writeGameToDb(db, id, game.winrates);
      wroteAny = true;
      progress.completedGameIds.add(id);
      progress.failed.remove(id);
      _saveProgress(progressFile, progress);
      skipped += 1;
      completed += 1;
      continue;
    }

    progress.currentGameId = id;
    progress.currentTurn = nextMissingTurn(game.winrates, totalMoves);
    _saveProgress(progressFile, progress);
    _writeStatus(
      statusFile,
      index: index,
      total: rows.length,
      id: id,
      title: title,
      rules: rules,
      turn: progress.currentTurn,
      totalMoves: totalMoves,
      completed: completed,
    );
    log(
      '开始 $id  《$title》  ${rules.ancient ? '古谱' : rules.presetId}  '
      '贴目 ${rules.komi}  KataGo=${rules.kataGoRules}  '
      '${progress.currentTurn}/$totalMoves',
    );

    final List<List<String>> kataMoves = _tokensToKataGoMoves(moveTokens);
    final List<List<String>> initialStones = _initialStonesToKataGo(
      sgf.initialBlackStones,
      sgf.initialWhiteStones,
      sgf.boardSize,
    );

    try {
      while (!game.isComplete) {
        final int start = nextMissingTurn(game.winrates, totalMoves);
        if (start > totalMoves) {
          break;
        }
        final int end = (start + chunkSize - 1).clamp(start, totalMoves);
        final List<int> turns = <int>[
          for (int t = start; t <= end; t++) t,
        ];
        progress.currentTurn = start;
        _saveProgress(progressFile, progress);
        await engine.analyzeTurns(
          id: id,
          boardSize: sgf.boardSize,
          rules: rules.kataGoRules,
          komi: rules.komi,
          moves: kataMoves,
          initialStones: initialStones,
          analyzeTurns: turns,
          maxVisits: visits,
          onTurn: (int turn, double wr) {
            game.winrates[turn] = wr;
            progress.currentTurn = turn;
            log(
              '$id  第$turn/$totalMoves手  '
              '${rules.ancient ? '古谱' : rules.presetId} KM${rules.komi}  '
              '胜率 ${(wr * 100).toStringAsFixed(1)}%',
            );
            if (turn == turns.last || turn % 8 == 0) {
              gameFile.writeAsStringSync(
                const JsonEncoder.withIndent('  ').convert(game.toJson()),
              );
              _saveProgress(progressFile, progress);
            }
          },
        );
        gameFile.writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert(game.toJson()),
        );
        _saveProgress(progressFile, progress);
      }

      if (!game.isComplete) {
        throw StateError('incomplete after loop');
      }
      _writeGameToDb(db, id, game.winrates);
      wroteAny = true;
      progress.completedGameIds.add(id);
      progress.failed.remove(id);
      progress.currentGameId = null;
      progress.currentTurn = 0;
      _saveProgress(progressFile, progress);
      completed += 1;
      log('完成 $id  ${index + 1}/${rows.length}');
    } catch (e, st) {
      log('失败 $id: $e');
      log('$st');
      progress.failed[id] = e.toString();
      progress.currentGameId = id;
      _saveProgress(progressFile, progress);
      failed += 1;
      try {
        await engine.restart();
      } catch (restartError) {
        log('重启 KataGo 失败: $restartError');
        await shutdown(code: 1);
        return;
      }
    }
  }

  progress.currentGameId = null;
  progress.currentTurn = 0;
  _saveProgress(progressFile, progress);
  if (wroteAny && failed == 0) {
    _bumpSeedVersion(projectRoot, log);
  }
  log('全部结束  完成 $completed  其中跳过 $skipped  失败 $failed  库 $seedPath');
  await shutdown(code: failed == 0 ? 0 : 2);
}

String _resolveKatagoBin(String projectRoot) {
  final String? env = Platform.environment['KATAGO_BIN'];
  if (env != null && env.trim().isNotEmpty && File(env).existsSync()) {
    return env;
  }
  const List<String> candidates = <String>[
    '/opt/homebrew/bin/katago',
    '/usr/local/bin/katago',
  ];
  for (final String path in candidates) {
    if (File(path).existsSync()) {
      return path;
    }
  }
  return _which('katago') ?? '';
}

String? _which(String cmd) {
  try {
    final ProcessResult r = Process.runSync('which', <String>[cmd], runInShell: true);
    if (r.exitCode == 0 && r.stdout.toString().trim().isNotEmpty) {
      return r.stdout.toString().trim().split('\n').first.trim();
    }
  } catch (_) {}
  return null;
}

int _positiveEnv(String key, int fallback) {
  final int parsed = int.tryParse(Platform.environment[key] ?? '') ?? fallback;
  return parsed < 1 ? fallback : parsed;
}

bool _acquirePidLock(File pidFile) {
  if (pidFile.existsSync()) {
    final int? pid = int.tryParse(pidFile.readAsStringSync().trim());
    if (pid != null && _pidAlive(pid)) {
      return false;
    }
  }
  pidFile.writeAsStringSync('${pid}\n');
  return true;
}

void _releasePidLock(File pidFile) {
  try {
    if (pidFile.existsSync()) {
      pidFile.deleteSync();
    }
  } catch (_) {}
}

bool _pidAlive(int pid) {
  try {
    final ProcessResult r = Process.runSync('kill', <String>['-0', '$pid']);
    return r.exitCode == 0;
  } catch (_) {
    return false;
  }
}

String _categoryOf(String sessionJson) {
  try {
    final Object decoded = jsonDecode(sessionJson);
    if (decoded is Map<String, dynamic>) {
      return (decoded['category'] as String?)?.trim() ?? '';
    }
  } catch (_) {}
  return '';
}

bool _dbWinrateComplete(String raw, int totalMoves) {
  if (raw.trim().isEmpty || raw.trim() == '{}') {
    return false;
  }
  try {
    final Object decoded = jsonDecode(raw);
    if (decoded is! Map) {
      return false;
    }
    final Map<dynamic, dynamic> map = decoded;
    final Object? first = map.isEmpty ? null : map.values.first;
    final Map<dynamic, dynamic> turns = first is Map ? first : map;
    final Map<int, double> winrates = <int, double>{};
    for (final MapEntry<dynamic, dynamic> e in turns.entries) {
      final int? turn = int.tryParse(e.key.toString());
      final num? wr = e.value as num?;
      if (turn == null || wr == null) {
        continue;
      }
      winrates[turn] = wr.toDouble();
    }
    return winrateTurnsComplete(winrates, totalMoves);
  } catch (_) {
    return false;
  }
}

void _writeGameToDb(Database db, String id, Map<int, double> winrates) {
  db.execute(
    'UPDATE game_records SET winrateJson = ?, updatedAtMs = ? WHERE id = ?',
    <Object?>[winrateJsonForDb(winrates), DateTime.now().millisecondsSinceEpoch, id],
  );
}

void _saveProgress(File file, MasterWinrateProgress progress) {
  file.writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(progress.toJson()),
  );
}

void _writeStatus(
  File file, {
  required int index,
  required int total,
  required String id,
  required String title,
  required MasterWinrateEngineRules rules,
  required int turn,
  required int totalMoves,
  required int completed,
}) {
  file.writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(<String, dynamic>{
      'index': index,
      'total': total,
      'completed': completed,
      'id': id,
      'title': title,
      'ruleset': rules.presetId,
      'kataGoRules': rules.kataGoRules,
      'komi': rules.komi,
      'ancient': rules.ancient,
      'turn': turn,
      'totalMoves': totalMoves,
      'updatedAt': DateTime.now().toIso8601String(),
    }),
  );
}

void _bumpSeedVersion(String projectRoot, void Function(String) log) {
  final File metaFile = File(
    p.join(projectRoot, 'assets', 'config', 'master_seed_meta.json'),
  );
  if (!metaFile.existsSync()) {
    return;
  }
  try {
    final Map<String, dynamic> json =
        jsonDecode(metaFile.readAsStringSync()) as Map<String, dynamic>;
    final int version = (json['version'] as num?)?.toInt() ?? 0;
    json['version'] = version + 1;
    json['note'] =
        'Winrate batch ${DateTime.now().toIso8601String().split('T').first}';
    metaFile.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(json) + '\n',
    );
    log('seed version ${version + 1}');
  } catch (e) {
    log('未能写入 seed version: $e');
  }
}

List<List<String>> _tokensToKataGoMoves(List<String> tokens) {
  final List<List<String>> out = <List<String>>[];
  for (final String token in tokens) {
    final int colon = token.indexOf(':');
    if (colon < 0) {
      continue;
    }
    final String color = token.substring(0, colon).toUpperCase();
    final String rest = token.substring(colon + 1).trim().toUpperCase();
    if (rest.isEmpty || rest == 'PASS') {
      out.add(<String>[color, 'pass']);
    } else {
      out.add(<String>[color, rest]);
    }
  }
  return out;
}

List<List<String>> _initialStonesToKataGo(
  List<GoPoint> black,
  List<GoPoint> white,
  int boardSize,
) {
  const String columns = 'ABCDEFGHJKLMNOPQRSTUVWXYZ';
  final List<List<String>> out = <List<String>>[];
  for (final GoPoint pt in black) {
    out.add(<String>['B', '${columns[pt.x]}${boardSize - pt.y}']);
  }
  for (final GoPoint pt in white) {
    out.add(<String>['W', '${columns[pt.x]}${boardSize - pt.y}']);
  }
  return out;
}

class _KatagoAnalysis {
  _KatagoAnalysis({
    required this.bin,
    required this.config,
    required this.model,
    required this.cwd,
  });

  final String bin;
  final String config;
  final String model;
  final String cwd;

  Process? _process;
  final List<String> _lines = <String>[];

  Future<void> start() async {
    final Process process = await Process.start(
      bin,
      <String>['analysis', '-config', config, '-model', model],
      workingDirectory: cwd,
    );
    _process = process;
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_lines.add);
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((String line) {
          stderr.writeln('[katago] $line');
        });
    await Future<void>.delayed(const Duration(milliseconds: 400));
  }

  Future<void> restart() async {
    kill();
    _lines.clear();
    await start();
  }

  void kill() {
    _process?.kill();
    _process = null;
  }

  Future<void> analyzeTurns({
    required String id,
    required int boardSize,
    required String rules,
    required double komi,
    required List<List<String>> moves,
    required List<List<String>> initialStones,
    required List<int> analyzeTurns,
    required int maxVisits,
    required void Function(int turn, double winrate) onTurn,
  }) async {
    if (analyzeTurns.isEmpty) {
      return;
    }
    Object? lastError;
    for (int attempt = 0; attempt < _maxRetries; attempt++) {
      try {
        await _analyzeTurnsOnce(
          id: id,
          boardSize: boardSize,
          rules: rules,
          komi: komi,
          moves: moves,
          initialStones: initialStones,
          analyzeTurns: analyzeTurns,
          maxVisits: maxVisits,
          onTurn: onTurn,
        );
        return;
      } catch (e) {
        lastError = e;
        await restart();
      }
    }
    throw lastError ?? StateError('analyzeTurns failed');
  }

  Future<void> _analyzeTurnsOnce({
    required String id,
    required int boardSize,
    required String rules,
    required double komi,
    required List<List<String>> moves,
    required List<List<String>> initialStones,
    required List<int> analyzeTurns,
    required int maxVisits,
    required void Function(int turn, double winrate) onTurn,
  }) async {
    final Process process = _process!;
    final String queryId =
        'q-$id-${analyzeTurns.first}-${DateTime.now().millisecondsSinceEpoch}';
    final Map<String, dynamic> query = <String, dynamic>{
      'id': queryId,
      'boardXSize': boardSize,
      'boardYSize': boardSize,
      'rules': rules,
      'komi': komi,
      'maxVisits': maxVisits,
      'moves': moves,
      'initialStones': initialStones,
      'analyzeTurns': analyzeTurns,
    };
    process.stdin.writeln(jsonEncode(query));
    await process.stdin.flush();

    final Set<int> received = <int>{};
    while (received.length < analyzeTurns.length) {
      final Map<String, dynamic>? obj = await _readResponse(queryId);
      if (obj == null) {
        throw TimeoutException('KataGo timeout $id turns $analyzeTurns');
      }
      if (obj['error'] != null) {
        throw StateError('KataGo error $id: ${obj['error']}');
      }
      final int turn = (obj['turnNumber'] as num?)?.toInt() ?? 0;
      final Map<String, dynamic>? root =
          obj['rootInfo'] as Map<String, dynamic>?;
      final double wr = (root?['winrate'] as num?)?.toDouble() ?? 0.5;
      if (received.add(turn)) {
        onTurn(turn, wr);
      }
    }
  }

  Future<Map<String, dynamic>?> _readResponse(String queryId) async {
    final DateTime deadline = DateTime.now().add(_perResponseTimeout);
    while (DateTime.now().isBefore(deadline)) {
      for (int i = 0; i < _lines.length; i++) {
        final String line = _lines[i].trim();
        if (!line.startsWith('{')) {
          continue;
        }
        try {
          final Map<String, dynamic> obj =
              jsonDecode(line) as Map<String, dynamic>;
          final String? respId = obj['id'] as String?;
          if (respId != null && respId != queryId) {
            continue;
          }
          if (obj.containsKey('error') || obj.containsKey('rootInfo')) {
            _lines.removeAt(i);
            return obj;
          }
        } catch (_) {}
      }
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
    return null;
  }
}
