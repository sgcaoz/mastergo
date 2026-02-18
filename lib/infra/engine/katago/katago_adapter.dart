import 'dart:convert';

import 'package:mastergo/domain/entities/analysis_profile.dart';
import 'package:mastergo/domain/entities/game_rules.dart';
import 'package:mastergo/domain/entities/game_setup.dart';
import 'package:mastergo/domain/entities/katago_model.dart';
import 'package:mastergo/infra/config/katago_model_repository.dart';
import 'package:flutter/services.dart';

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
}

class KatagoAnalyzeResult {
  const KatagoAnalyzeResult({
    required this.queryId,
    required this.winrate,
    required this.scoreLead,
    required this.bestMove,
    this.topCandidates = const <KatagoMoveCandidate>[],
    this.topMoves = const <String>[],
    this.ownership,
  });

  final String queryId;
  final double winrate;
  final double scoreLead;
  final String bestMove;
  final List<KatagoMoveCandidate> topCandidates;
  final List<String> topMoves;
  /// Per-point ownership from KataGo: row-major, -1 = black territory, 1 = white. Length boardSize².
  final List<double>? ownership;
}

class KatagoMoveCandidate {
  const KatagoMoveCandidate({required this.move, required this.blackWinrate});

  final String move;
  final double blackWinrate;
}

abstract class KatagoAdapter {
  Future<void> ensureStarted();
  Future<KatagoAnalyzeResult> analyze(KatagoAnalyzeRequest request);
  Future<void> shutdown();
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

  @override
  Future<void> ensureStarted() async {
    if (_started) {
      return;
    }

    final KatagoModel model = await _modelRepository.loadDefaultModel();
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

    await _channel.invokeMethod<void>('startEngine', <String, Object?>{
      'modelPath': preparedModelPath,
      'configAssetPath': 'assets/config/katago_analysis.cfg',
    });

    // Warm up once so the first real user query is not penalized by model cold start.
    await _channel
        .invokeMapMethod<dynamic, dynamic>('analyzeOnce', <String, Object?>{
          'queryId': 'warmup-${DateTime.now().millisecondsSinceEpoch}',
          'boardSize': 9,
          'ruleset': 'chinese',
          'komi': 7.5,
          'maxVisits': 1,
          'thinkingTimeMs': 50,
          'moves': const <String>[],
          'initialStones': const <String>[],
          'modelId': model.id,
          'timeoutMs': 30000,
        });

    _activeModel = model;
    _started = true;
  }

  @override
  Future<KatagoAnalyzeResult> analyze(KatagoAnalyzeRequest request) async {
    await ensureStarted();
    final Map<dynamic, dynamic>? response = await _channel
        .invokeMapMethod<dynamic, dynamic>('analyzeOnce', <String, Object?>{
          'queryId': request.queryId,
          'boardSize': request.gameSetup.boardSize,
          'ruleset': request.rules.ruleset,
          'komi': request.rules.komi,
          'maxVisits': request.profile.maxVisits,
          'thinkingTimeMs': request.profile.thinkingTimeMs,
          'moves': request.moves,
          'initialStones': request.initialStones,
          'modelId': _activeModel?.id,
          'timeoutMs': request.timeoutMs,
          'includeOwnership': request.includeOwnership,
        });
    if (response == null) {
      throw StateError('KataGo analyzeOnce returned null');
    }

    final List<KatagoMoveCandidate> topCandidates = _extractTopCandidates(
      response,
    );
    final List<String> topMoves = topCandidates
        .map((KatagoMoveCandidate c) => c.move)
        .toList();

    List<double>? ownership;
    final Object? rawOwnership = response['ownership'];
    if (rawOwnership is List) {
      ownership = rawOwnership
          .map((dynamic e) => (e is num) ? e.toDouble() : 0.0)
          .toList();
    }

    return KatagoAnalyzeResult(
      queryId: response['queryId'] as String,
      winrate: (response['winrate'] as num).toDouble(),
      scoreLead: (response['scoreLead'] as num).toDouble(),
      bestMove: response['bestMove'] as String,
      topCandidates: topCandidates,
      topMoves: topMoves,
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
    double? bestWinrate;
    final List<KatagoMoveCandidate> candidates = <KatagoMoveCandidate>[];
    for (final dynamic item in moveInfos) {
      if (item is! Map) {
        continue;
      }
      final String move = (item['move']?.toString() ?? '').trim();
      if (move.isEmpty || move.toLowerCase() == 'pass') {
        continue;
      }
      final double? wr = (item['winrate'] as num?)?.toDouble();
      if (bestWinrate == null && wr != null) {
        bestWinrate = wr;
      }
      // If multiple moves are effectively tied, expose up to 3 hints.
      final bool nearBest =
          bestWinrate == null || wr == null || (bestWinrate - wr).abs() <= 0.01;
      if (nearBest &&
          !candidates.any((KatagoMoveCandidate c) => c.move == move)) {
        candidates.add(
          KatagoMoveCandidate(move: move, blackWinrate: wr ?? 0.5),
        );
      }
      if (candidates.length >= 3) {
        break;
      }
    }
    if (candidates.isEmpty) {
      return const <KatagoMoveCandidate>[];
    }
    return candidates.length > 1
        ? candidates.take(3).toList()
        : <KatagoMoveCandidate>[candidates.first];
  }

  @override
  Future<void> shutdown() async {
    await _channel.invokeMethod<void>('shutdownEngine');
    _started = false;
  }
}

class MockKatagoAdapter implements KatagoAdapter {
  @override
  Future<KatagoAnalyzeResult> analyze(KatagoAnalyzeRequest request) async {
    return KatagoAnalyzeResult(
      queryId: request.queryId,
      winrate: 0.5,
      scoreLead: 0,
      bestMove: 'D4',
    );
  }

  @override
  Future<void> ensureStarted() async {}

  @override
  Future<void> shutdown() async {}
}
