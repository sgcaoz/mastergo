import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:mastergo/domain/entities/analysis_profile.dart';
import 'package:mastergo/domain/entities/game_record.dart';
import 'package:mastergo/domain/entities/game_rules.dart';
import 'package:mastergo/domain/entities/game_setup.dart';
import 'package:mastergo/domain/entities/rule_presets.dart';
import 'package:mastergo/domain/go/go_types.dart';
import 'package:mastergo/domain/sgf/sgf_parser.dart';
import 'package:mastergo/infra/engine/katago/katago_adapter.dart';
import 'package:mastergo/infra/storage/game_record_repository.dart';
import 'package:path_provider/path_provider.dart';

/// 名局每步胜率批量分析：maxVisits=2，规则以 SGF 为准（含古谱、让子），
/// 先写临时文件，跑完后写入 DB；支持断点恢复与引擎唤醒重试。
class MasterWinrateBatchRunner {
  MasterWinrateBatchRunner({
    required KatagoAdapter adapter,
    GameRecordRepository? recordRepository,
    String? tempDirPath,
  })  : _adapter = adapter,
        _repo = recordRepository ?? GameRecordRepository(),
        _tempDirPath = tempDirPath;

  static const AnalysisProfile _batchProfile = AnalysisProfile(
    id: 'master_batch',
    name: 'Batch',
    description: 'maxVisits=2 for master games',
    maxVisits: 2,
    thinkingTimeMs: 100,
    includeOwnership: false,
  );

  static const int _maxRetries = 3;
  static const String _progressFileName = 'master_winrate_progress.json';

  final KatagoAdapter _adapter;
  final GameRecordRepository _repo;
  final String? _tempDirPath;

  String? _currentTempDir;
  final Set<String> _completedGameIds = <String>{};
  String? _currentGameId;
  int _currentTurn = 0;
  final Map<String, Map<String, double>> _results =
      <String, Map<String, double>>{};

  /// 当前进度描述，用于 UI
  String get progressDescription {
    if (_currentGameId == null) return '空闲';
    return '$_currentGameId @ turn $_currentTurn';
  }

  /// 已完成局数
  int get completedCount => _completedGameIds.length;

  Future<String> _tempDir() async {
    final String? cur = _currentTempDir;
    if (cur != null) return cur;
    final String? pathArg = _tempDirPath;
    if (pathArg != null && pathArg.isNotEmpty) {
      _currentTempDir = pathArg;
      return pathArg;
    }
    final Directory dir = await getTemporaryDirectory();
    final Directory batchDir =
        Directory('${dir.path}${Platform.pathSeparator}master_winrate_batch');
    if (!await batchDir.exists()) {
      await batchDir.create(recursive: true);
    }
    _currentTempDir = batchDir.path;
    return _currentTempDir!;
  }

  Future<File> _progressFile() async {
    final String dir = await _tempDir();
    return File('$dir${Platform.pathSeparator}$_progressFileName');
  }

  Future<void> loadProgress() async {
    final File file = await _progressFile();
    if (!await file.exists()) return;
    try {
      final String raw = await file.readAsString();
      final Map<String, dynamic> json =
          jsonDecode(raw) as Map<String, dynamic>;
      final List<dynamic> completed =
          json['completedGameIds'] as List<dynamic>? ?? const [];
      _completedGameIds.clear();
      _completedGameIds.addAll(completed.cast<String>());
      _currentGameId = json['currentGameId'] as String?;
      _currentTurn = (json['currentTurn'] as num?)?.toInt() ?? 0;
      final Map<String, dynamic>? results =
          json['results'] as Map<String, dynamic>?;
      _results.clear();
      if (results != null) {
        for (final MapEntry<String, dynamic> e in results.entries) {
          final Map<String, dynamic>? m = e.value as Map<String, dynamic>?;
          if (m == null) continue;
          final Map<String, double> turnToWr = <String, double>{};
          for (final MapEntry<String, dynamic> t in m.entries) {
            final num? v = t.value as num?;
            if (v != null) turnToWr[t.key] = v.toDouble();
          }
          _results[e.key] = turnToWr;
        }
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('MasterWinrateBatch: loadProgress failed: $e');
      }
    }
  }

  Future<void> saveProgress() async {
    final Map<String, dynamic> json = <String, dynamic>{
      'completedGameIds': _completedGameIds.toList(),
      'currentGameId': _currentGameId,
      'currentTurn': _currentTurn,
      'results': _results.map(
        (String k, Map<String, double> v) =>
            MapEntry<String, dynamic>(k, v.map((String a, double b) => MapEntry<String, dynamic>(a, b))),
      ),
    };
    final File file = await _progressFile();
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(json));
  }

  /// 跑完所有名局后，将 _results 写入 DB 的 winrateJson。
  Future<void> writeResultsToDb() async {
    for (final String gameId in _results.keys) {
      final Map<String, double>? winrates = _results[gameId];
      if (winrates == null || winrates.isEmpty) continue;
      final GameRecord? record = await _repo.loadById(gameId);
      if (record == null) continue;
      final String winrateJson = jsonEncode(
        winrates.map((String k, double v) => MapEntry<String, dynamic>(k, v)),
      );
      final GameRecord updated = GameRecord(
        id: record.id,
        source: record.source,
        title: record.title,
        boardSize: record.boardSize,
        ruleset: record.ruleset,
        komi: record.komi,
        sgf: record.sgf,
        status: record.status,
        sessionJson: record.sessionJson,
        winrateJson: winrateJson,
        createdAtMs: record.createdAtMs,
        updatedAtMs: DateTime.now().millisecondsSinceEpoch,
      );
      await _repo.upsert(updated);
    }
  }

  /// 执行一批：从 DB 拉名局，按进度跳过已完成，逐局逐手分析，先写临时再可写 DB。
  /// [onProgress] 可选，用于 UI 更新。
  Future<void> run({
    void Function(String gameId, int turn, int totalTurns)? onProgress,
  }) async {
    await _adapter.ensureStarted();
    await loadProgress();

    final List<GameRecord> masters =
        await _repo.listBySource('master', limit: 500);
    if (masters.isEmpty) return;

    final List<GameRecord> todo = masters
        .where((GameRecord r) => !_completedGameIds.contains(r.id))
        .toList();
    if (todo.isEmpty) {
      await writeResultsToDb();
      return;
    }

    final SgfParser parser = const SgfParser();

    for (int gameIndex = 0; gameIndex < todo.length; gameIndex++) {
      final GameRecord record = todo[gameIndex];
      _currentGameId = record.id;

      SgfGame sgf;
      try {
        sgf = parser.parse(record.sgf);
      } catch (e) {
        if (kDebugMode) {
          debugPrint('MasterWinrateBatch: parse SGF failed ${record.id}: $e');
        }
        _completedGameIds.add(record.id);
        _results[record.id] = <String, double>{};
        await saveProgress();
        continue;
      }

      final List<SgfNode> mainLine = sgf.mainLineNodes();
      final int numTurns = mainLine.length;
      final List<String> moveTokens = <String>[];
      for (final SgfNode node in mainLine) {
        if (node.move != null) {
          moveTokens.add(node.move!.toProtocolToken(sgf.boardSize));
        }
      }

      final List<String> initialStones = <String>[
        ...sgf.initialBlackStones.map(
          (GoPoint p) =>
              'B:${GoMove(player: GoStone.black, point: p).toGtp(sgf.boardSize)}',
        ),
        ...sgf.initialWhiteStones.map(
          (GoPoint p) =>
              'W:${GoMove(player: GoStone.white, point: p).toGtp(sgf.boardSize)}',
        ),
      ];
      final StoneColor startingPlayer = sgf.initialBlackStones.isNotEmpty
          ? StoneColor.white
          : StoneColor.black;
      final GameRules rules =
          rulePresetFromString(sgf.rules).toGameRules(komi: sgf.komi);

      Map<String, double> gameWinrates = _results[record.id] ?? <String, double>{};
      int startTurn = 0;
      if (_currentGameId == record.id && _currentTurn > 0) {
        startTurn = _currentTurn;
      }

      for (int turn = startTurn; turn <= numTurns; turn++) {
        _currentTurn = turn;

        final List<String> movesForTurn =
            moveTokens.take(turn).toList();
        KatagoAnalyzeResult? res;
        for (int attempt = 0; attempt < _maxRetries; attempt++) {
          try {
            res = await _adapter.analyze(
              KatagoAnalyzeRequest(
                queryId: 'batch-${record.id}-$turn-${DateTime.now().millisecondsSinceEpoch}',
                moves: movesForTurn,
                initialStones: initialStones,
                gameSetup: GameSetup(
                  boardSize: sgf.boardSize,
                  startingPlayer: startingPlayer,
                ),
                rules: rules,
                profile: _batchProfile,
                timeoutMs: 15000,
              ),
            );
            break;
          } catch (e) {
            if (kDebugMode) {
              debugPrint(
                  'MasterWinrateBatch: analyze attempt ${attempt + 1}/$_maxRetries ${record.id} turn $turn: $e');
            }
            if (attempt < _maxRetries - 1) {
              await _adapter.ensureStarted();
            } else {
              await saveProgress();
              rethrow;
            }
          }
        }
        if (res != null) {
          gameWinrates['$turn'] = res.winrate;
          _results[record.id] = gameWinrates;
        }
        onProgress?.call(record.id, turn, numTurns);
      }

      _completedGameIds.add(record.id);
      _currentTurn = 0;
      await saveProgress();
    }

    _currentGameId = null;
    await saveProgress();
    await writeResultsToDb();
  }
}
