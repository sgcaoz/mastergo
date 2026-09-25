import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:mastergo/domain/entities/analysis_profile.dart';
import 'package:mastergo/domain/entities/game_rules.dart';
import 'package:mastergo/domain/entities/game_setup.dart';
import 'package:mastergo/domain/entities/katago_model.dart';
import 'package:mastergo/infra/config/katago_model_repository.dart';
import 'package:mastergo/infra/debug_log.dart';

/// Who moves first in the KataGo query. With no moves yet, that is the side to play
/// (white in a handicap game). Once moves exist, it is the color of the first move.
String katagoInitialPlayer({
  required bool blackToMove,
  required List<String> moves,
}) {
  if (moves.isNotEmpty) {
    final int split = moves.first.indexOf(':');
    if (split > 0) {
      final String color = moves.first.substring(0, split);
      if (color == 'B' || color == 'W') {
        return color;
      }
    }
  }
  return blackToMove ? 'B' : 'W';
}

class KatagoAnalyzeRequest {
  const KatagoAnalyzeRequest({
    required this.queryId,
    required this.moves,
    required this.gameSetup,
    required this.rules,
    required this.profile,
    this.initialStones = const <String>[],
    this.analyzeTurns = const <int>[],
    this.timeoutMs,
    this.includeOwnership = false,
    this.allowMoves = const <Map<String, Object>>[],
  });

  final String queryId;
  final List<String> moves;
  final GameSetup gameSetup;
  final GameRules rules;
  final AnalysisProfile profile;
  final List<String> initialStones;
  final List<int> analyzeTurns;
  final int? timeoutMs;

  /// When true, engine returns per-point ownership (-1 black to 1 white) for territory display.
  final bool includeOwnership;

  /// KataGo `allowMoves` entries: player, untilDepth, moves (GTP).
  final List<Map<String, Object>> allowMoves;
}

class KatagoAnalyzeResult {
  const KatagoAnalyzeResult({
    required this.queryId,
    required this.winrate,
    required this.scoreLead,
    required this.bestMove,
    this.turnNumber,
    this.topCandidates = const <KatagoMoveCandidate>[],
    this.topMoves = const <String>[],
    this.ownership,
  });

  final String queryId;
  final double winrate;
  final double scoreLead;
  final String bestMove;

  /// Present when the engine analyzed a specific turn of a sequence query.
  final int? turnNumber;
  final List<KatagoMoveCandidate> topCandidates;
  final List<String> topMoves;

  /// Per-point ownership from KataGo in this project runtime: row-major, 1 = black territory, -1 = white. Length boardSize².
  final List<double>? ownership;
}

class KatagoMoveCandidate {
  const KatagoMoveCandidate({required this.move, required this.blackWinrate});

  final String move;
  final double blackWinrate;
}

class KatagoPreparationStatus {
  const KatagoPreparationStatus({
    required this.ready,
    required this.downloading,
    this.progress,
    this.message,
  });

  final bool ready;
  final bool downloading;

  /// 0..1 when progress is known.
  final double? progress;
  final String? message;
}

abstract class KatagoAdapter {
  Future<void> ensureStarted();
  Future<KatagoPreparationStatus> getPreparationStatus({
    bool requestDownload = false,
  });
  Future<KatagoAnalyzeResult> analyze(KatagoAnalyzeRequest request);

  /// Analyze several positions of the same game in one engine query when
  /// [KatagoAnalyzeRequest.analyzeTurns] is non-empty. Implementations may
  /// fall back to one query per turn.
  Future<List<KatagoAnalyzeResult>> analyzeSequence(
    KatagoAnalyzeRequest request,
  ) {
    return analyzeTurnsSequentially(this, request);
  }

  Future<void> shutdown();
}

Future<List<KatagoAnalyzeResult>> analyzeTurnsSequentially(
  KatagoAdapter adapter,
  KatagoAnalyzeRequest request,
) async {
  if (request.analyzeTurns.isEmpty) {
    return <KatagoAnalyzeResult>[await adapter.analyze(request)];
  }
  final List<KatagoAnalyzeResult> results = <KatagoAnalyzeResult>[];
  for (final int turn in request.analyzeTurns) {
    results.add(
      await adapter.analyze(
        KatagoAnalyzeRequest(
          queryId: '${request.queryId}-t$turn',
          moves: request.moves.take(turn).toList(),
          gameSetup: request.gameSetup,
          rules: request.rules,
          profile: request.profile,
          initialStones: request.initialStones,
          timeoutMs: request.timeoutMs,
          includeOwnership: request.includeOwnership,
          allowMoves: request.allowMoves,
        ),
      ),
    );
  }
  return results;
}

class PlatformKatagoAdapter implements KatagoAdapter {
  PlatformKatagoAdapter({
    MethodChannel? channel,
    KatagoModelRepository? modelRepository,
  }) : _channel = channel ?? const MethodChannel('mastergo/katago'),
       _modelRepository = modelRepository ?? KatagoModelRepository();

  final MethodChannel _channel;
  final KatagoModelRepository _modelRepository;
  KatagoModel? _activeModel;
  bool _started = false;
  DateTime? _lastAutoRestartAt;
  int _autoRestartBurst = 0;
  static const Duration _autoRestartWindow = Duration(seconds: 20);
  static const int _maxAutoRestartsPerWindow = 2;

  @override
  Future<void> ensureStarted() async {
    if (_started) {
      appLog('[MasterGo/KatagoAdapter] ensureStarted skipped: already started');
      return;
    }

    final KatagoModel model = await _modelRepository.loadDefaultModel();
    appLog(
      '[MasterGo/KatagoAdapter] ensureStarted begin model=${model.id} asset=${model.assetPath}',
    );
    // Model is bundled in app assets (single package); no on-demand pack download.
    final Map<dynamic, dynamic>? prepareResult = await _channel
        .invokeMapMethod<dynamic, dynamic>('prepareModel', <String, Object?>{
          'modelAssetPath': model.assetPath,
          'modelSha256': model.sha256,
        });
    if (prepareResult == null) {
      throw StateError('KataGo prepareModel returned null');
    }

    final String preparedModelPath =
        prepareResult['modelPath'] as String? ?? model.assetPath;
    appLog('[MasterGo/KatagoAdapter] prepareModel path=$preparedModelPath');

    try {
      await _channel.invokeMethod<void>('startEngine', <String, Object?>{
        'modelPath': preparedModelPath,
        'configAssetPath': 'assets/config/katago_analysis.cfg',
      });
    } on PlatformException catch (e) {
      appLog(
        '[MasterGo/KatagoAdapter] startEngine PlatformException '
        'code=${e.code} message=${e.message} details=${e.details}',
      );
      final String msg = e.message ?? '';
      if (e.code == 'START_ENGINE_FAILED' &&
          (msg.contains('Permission denied') ||
              msg.contains('Operation not permitted'))) {
        throw PlatformException(
          code: 'IOS_EXEC_NOT_ALLOWED',
          message:
              'iOS sandbox blocks spawning external executables from app bundle. '
              'KataGo must run in-process (library API), not via posix_spawn.',
          details: e.details,
        );
      }
      rethrow;
    }
    appLog('[MasterGo/KatagoAdapter] startEngine returned success');

    _activeModel = model;
    _started = true;
    appLog('[MasterGo/KatagoAdapter] ensureStarted completed');
  }

  @override
  Future<KatagoPreparationStatus> getPreparationStatus({
    bool requestDownload = false,
  }) async {
    if (_started) {
      return const KatagoPreparationStatus(ready: true, downloading: false);
    }
    // Single-bundle: model is in app assets; no pack download.
    return const KatagoPreparationStatus(ready: true, downloading: false);
  }

  @override
  Future<KatagoAnalyzeResult> analyze(KatagoAnalyzeRequest request) async {
    try {
      return await _analyzeOnce(request);
    } catch (e) {
      if (e is PlatformException) {
        appLog(
          '[MasterGo/KatagoAdapter] analyze PlatformException '
          'code=${e.code} message=${e.message} details=${e.details}',
        );
      } else {
        appLog('[MasterGo/KatagoAdapter] analyze error: $e');
      }
      if (e is PlatformException && e.code == 'ENGINE_TIMEOUT') {
        rethrow;
      }
      if (e is PlatformException &&
          (e.code == 'IOS_EXEC_NOT_ALLOWED' ||
              e.code == 'START_ENGINE_FAILED' ||
              e.code == 'ENGINE_UNEXPECTED_RESPONSE' ||
              e.code == 'ENGINE_RESPONSE_ERROR' ||
              e.code == 'BAD_ARGS')) {
        // Fatal startup class of errors should not trigger automatic restart loops.
        rethrow;
      }
      if (!_shouldAutoRestart(e)) {
        if (e is PlatformException) {
          appLog(
            '[MasterGo/KatagoAdapter] auto-restart suppressed '
            'code=${e.code} burst=$_autoRestartBurst',
          );
        }
        rethrow;
      }
      _started = false;
      _markAutoRestart();
      await ensureStarted();
      return _analyzeOnce(request);
    }
  }

  bool _shouldAutoRestart(Object error) {
    if (error is PlatformException) {
      const Set<String> recoverableCodes = <String>{
        'ENGINE_NOT_RUNNING',
        'ANALYZE_FAILED',
        'ENGINE_NO_RESULTS',
      };
      if (!recoverableCodes.contains(error.code)) {
        return false;
      }
    }
    final DateTime now = DateTime.now();
    if (_lastAutoRestartAt == null ||
        now.difference(_lastAutoRestartAt!) > _autoRestartWindow) {
      _autoRestartBurst = 0;
      return true;
    }
    return _autoRestartBurst < _maxAutoRestartsPerWindow;
  }

  void _markAutoRestart() {
    final DateTime now = DateTime.now();
    if (_lastAutoRestartAt == null ||
        now.difference(_lastAutoRestartAt!) > _autoRestartWindow) {
      _autoRestartBurst = 1;
    } else {
      _autoRestartBurst += 1;
    }
    _lastAutoRestartAt = now;
  }

  Future<KatagoAnalyzeResult> _analyzeOnce(KatagoAnalyzeRequest request) async {
    await ensureStarted();
    final String initialPlayer = katagoInitialPlayer(
      blackToMove: request.gameSetup.startingPlayer == StoneColor.black,
      moves: request.moves,
    );
    final int boardSize = request.gameSetup.boardSize.clamp(2, 25);
    if (request.gameSetup.boardSize != boardSize) {
      appLog(
        '[MasterGo/KatagoAdapter] analyzeOnce boardSize clamped '
        '${request.gameSetup.boardSize} -> $boardSize',
      );
    }
    appLog(
      '[MasterGo/KatagoAdapter] analyzeOnce req queryId=${request.queryId} '
      'board=$boardSize moves=${request.moves.length} '
      'initialStones=${request.initialStones.length} maxVisits=${request.profile.maxVisits} '
      'thinkingMs=${request.profile.thinkingTimeMs}',
    );
    final Map<dynamic, dynamic>? response = await _channel
        .invokeMapMethod<dynamic, dynamic>(
          'analyzeOnce',
          _analyzePayload(
            request,
            boardSize: boardSize,
            initialPlayer: initialPlayer,
          ),
        );
    if (response == null) {
      appLog('[MasterGo/KatagoAdapter] analyzeOnce response is null');
      throw StateError('KataGo analyzeOnce returned null');
    }

    final String bestMove = response['bestMove'] as String? ?? 'pass';
    final double winrate = (response['winrate'] as num?)?.toDouble() ?? 0.5;
    final double scoreLead = (response['scoreLead'] as num?)?.toDouble() ?? 0.0;
    final int? nativeReceived = (response['_debugNativeMovesReceived'] as num?)
        ?.toInt();
    final int? nativeParsed = (response['_debugNativeMovesParsed'] as num?)
        ?.toInt();
    appLog(
      '[MasterGo/KatagoAdapter] analyzeOnce res queryId=${response['queryId']} '
      'bestMove=$bestMove winrate=${winrate.toStringAsFixed(3)} scoreLead=${scoreLead.toStringAsFixed(1)}'
      '${nativeReceived != null && nativeParsed != null ? " nativeMoves=$nativeReceived->$nativeParsed" : ""}',
    );
    return _resultFromResponseMap(response);
  }

  Map<String, Object?> _analyzePayload(
    KatagoAnalyzeRequest request, {
    required int boardSize,
    required String initialPlayer,
  }) {
    final Map<String, Object?> payload = <String, Object?>{
      'queryId': request.queryId,
      'boardSize': boardSize,
      'initialPlayer': initialPlayer,
      'ruleset': kataGoRulesetName(request.rules.ruleset),
      'komi': request.rules.komi,
      'maxVisits': request.profile.maxVisits,
      'thinkingTimeMs': request.profile.thinkingTimeMs,
      'moves': request.moves,
      'initialStones': request.initialStones,
      'modelId': _activeModel?.id,
      'timeoutMs': request.timeoutMs,
      'includeOwnership': request.includeOwnership,
    };
    if (request.analyzeTurns.isNotEmpty) {
      payload['analyzeTurns'] = request.analyzeTurns;
    }
    if (request.allowMoves.isNotEmpty) {
      payload['allowMoves'] = request.allowMoves;
    }
    return payload;
  }

  @override
  Future<List<KatagoAnalyzeResult>> analyzeSequence(
    KatagoAnalyzeRequest request,
  ) async {
    if (request.analyzeTurns.isEmpty) {
      return <KatagoAnalyzeResult>[await analyze(request)];
    }
    await ensureStarted();
    final String initialPlayer = katagoInitialPlayer(
      blackToMove: request.gameSetup.startingPlayer == StoneColor.black,
      moves: request.moves,
    );
    final int boardSize = request.gameSetup.boardSize.clamp(2, 25);
    try {
      final Map<dynamic, dynamic>? response = await _channel
          .invokeMapMethod<dynamic, dynamic>(
            'analyzeOnce',
            _analyzePayload(
              request,
              boardSize: boardSize,
              initialPlayer: initialPlayer,
            ),
          );
      if (response == null) {
        throw StateError('KataGo analyzeOnce returned null');
      }
      final Object? rawResults = response['results'];
      if (rawResults is List && rawResults.isNotEmpty) {
        return rawResults
            .whereType<Map>()
            .map(
              (Map<dynamic, dynamic> item) =>
                  _resultFromResponseMap(Map<dynamic, dynamic>.from(item)),
            )
            .toList();
      }
      if (response['winrate'] != null) {
        return <KatagoAnalyzeResult>[_resultFromResponseMap(response)];
      }
    } catch (e) {
      appLog('[MasterGo/KatagoAdapter] analyzeSequence falling back: $e');
    }
    return analyzeTurnsSequentially(this, request);
  }

  KatagoAnalyzeResult _resultFromResponseMap(Map<dynamic, dynamic> response) {
    final String bestMove = response['bestMove'] as String? ?? 'pass';
    final double winrate = (response['winrate'] as num?)?.toDouble() ?? 0.5;
    final double scoreLead = (response['scoreLead'] as num?)?.toDouble() ?? 0.0;
    final List<KatagoMoveCandidate> topCandidates = _extractTopCandidates(
      response,
    );
    List<double>? ownership;
    final Object? rawOwnership = response['ownership'];
    if (rawOwnership is List) {
      ownership = rawOwnership
          .map((dynamic e) => (e is num) ? e.toDouble() : 0.0)
          .toList();
    }
    return KatagoAnalyzeResult(
      queryId: response['queryId'] as String? ?? '',
      winrate: winrate,
      scoreLead: scoreLead,
      bestMove: bestMove,
      turnNumber: (response['turnNumber'] as num?)?.toInt(),
      topCandidates: topCandidates,
      topMoves: topCandidates.map((KatagoMoveCandidate c) => c.move).toList(),
      ownership: ownership,
    );
  }

  List<KatagoMoveCandidate> _extractTopCandidates(
    Map<dynamic, dynamic> response,
  ) {
    final Object? raw = response['rawResponse'];
    if (raw == null) {
      return const <KatagoMoveCandidate>[];
    }
    dynamic obj = raw;
    if (raw is String && raw.isNotEmpty) {
      try {
        obj = jsonDecode(raw);
      } catch (_) {
        return const <KatagoMoveCandidate>[];
      }
    }
    if (obj is! Map) {
      return const <KatagoMoveCandidate>[];
    }
    final dynamic moveInfos = obj['moveInfos'];
    if (moveInfos is! List || moveInfos.isEmpty) {
      return const <KatagoMoveCandidate>[];
    }
    final List<KatagoMoveCandidate> candidates = <KatagoMoveCandidate>[];
    for (final dynamic item in moveInfos) {
      if (item is! Map) {
        continue;
      }
      final String move = (item['move']?.toString() ?? '').trim();
      if (move.isEmpty || move.toLowerCase() == 'pass') {
        continue;
      }
      if (candidates.any((KatagoMoveCandidate c) => c.move == move)) {
        continue;
      }
      final double? wr = (item['winrate'] as num?)?.toDouble();
      candidates.add(KatagoMoveCandidate(move: move, blackWinrate: wr ?? 0.5));
      if (candidates.length >= 16) {
        break;
      }
    }
    return candidates;
  }

  @override
  Future<void> shutdown() async {
    appLog('[MasterGo/KatagoAdapter] shutdown');
    await _channel.invokeMethod<void>('shutdownEngine');
    _started = false;
  }
}

class MockKatagoAdapter implements KatagoAdapter {
  @override
  Future<KatagoPreparationStatus> getPreparationStatus({
    bool requestDownload = false,
  }) async {
    return const KatagoPreparationStatus(ready: true, downloading: false);
  }

  @override
  Future<KatagoAnalyzeResult> analyze(KatagoAnalyzeRequest request) async {
    return KatagoAnalyzeResult(
      queryId: request.queryId,
      winrate: 0.5,
      scoreLead: 0,
      bestMove: 'D4',
      turnNumber: request.analyzeTurns.isEmpty
          ? request.moves.length
          : request.analyzeTurns.first,
    );
  }

  @override
  Future<List<KatagoAnalyzeResult>> analyzeSequence(
    KatagoAnalyzeRequest request,
  ) async {
    if (request.analyzeTurns.isEmpty) {
      return <KatagoAnalyzeResult>[await analyze(request)];
    }
    return request.analyzeTurns
        .map(
          (int turn) => KatagoAnalyzeResult(
            queryId: '${request.queryId}-t$turn',
            winrate: 0.5,
            scoreLead: 0,
            bestMove: 'D4',
            turnNumber: turn,
          ),
        )
        .toList();
  }

  @override
  Future<void> ensureStarted() async {}

  @override
  Future<void> shutdown() async {}
}
