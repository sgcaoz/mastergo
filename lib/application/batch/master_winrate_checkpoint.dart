import 'dart:convert';
import 'dart:io';

import 'package:mastergo/application/batch/master_winrate_rules.dart';

class MasterWinrateGameCheckpoint {
  MasterWinrateGameCheckpoint({
    required this.id,
    required this.presetId,
    required this.kataGoRules,
    required this.komi,
    required this.category,
    required this.totalMoves,
    required this.winrates,
  });

  final String id;
  final String presetId;
  final String kataGoRules;
  final double komi;
  final String category;
  final int totalMoves;
  final Map<int, double> winrates;

  bool matches(MasterWinrateEngineRules rules, int totalMoves) {
    return presetId == rules.presetId &&
        kataGoRules == rules.kataGoRules &&
        (komi - rules.komi).abs() < 1e-9 &&
        this.totalMoves == totalMoves;
  }

  bool get isComplete => winrateTurnsComplete(winrates, totalMoves);

  Map<String, dynamic> toJson() {
    final List<String> keys = winrates.keys.map((int k) => '$k').toList()
      ..sort((String a, String b) => (int.tryParse(a) ?? 0).compareTo(int.tryParse(b) ?? 0));
    return <String, dynamic>{
      'id': id,
      'ruleset': presetId,
      'kataGoRules': kataGoRules,
      'komi': komi,
      'category': category,
      'totalMoves': totalMoves,
      'winrates': <String, double>{
        for (final String k in keys) k: winrates[int.parse(k)]!,
      },
    };
  }

  static MasterWinrateGameCheckpoint? tryLoad(File file) {
    if (!file.existsSync()) {
      return null;
    }
    try {
      final Object decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map<String, dynamic>) {
        return null;
      }
      if (!decoded.containsKey('ruleset') || !decoded.containsKey('winrates')) {
        return null;
      }
      final Object? rawWinrates = decoded['winrates'];
      if (rawWinrates is! Map) {
        return null;
      }
      final Map<int, double> winrates = <int, double>{};
      for (final MapEntry<dynamic, dynamic> e in rawWinrates.entries) {
        final int? turn = int.tryParse(e.key.toString());
        final num? wr = e.value as num?;
        if (turn == null || wr == null) {
          continue;
        }
        winrates[turn] = wr.toDouble();
      }
      return MasterWinrateGameCheckpoint(
        id: decoded['id'] as String? ?? '',
        presetId: decoded['ruleset'] as String? ?? '',
        kataGoRules: decoded['kataGoRules'] as String? ?? '',
        komi: (decoded['komi'] as num?)?.toDouble() ?? 0,
        category: decoded['category'] as String? ?? '',
        totalMoves: (decoded['totalMoves'] as num?)?.toInt() ?? 0,
        winrates: winrates,
      );
    } catch (_) {
      return null;
    }
  }
}

class MasterWinrateProgress {
  MasterWinrateProgress({
    Set<String>? completedGameIds,
    Map<String, String>? failed,
    this.currentGameId,
    this.currentTurn = 0,
  }) : completedGameIds = completedGameIds ?? <String>{},
       failed = failed ?? <String, String>{};

  static const int schemaVersion = 2;

  final Set<String> completedGameIds;
  final Map<String, String> failed;
  String? currentGameId;
  int currentTurn;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'schemaVersion': schemaVersion,
      'completedGameIds': completedGameIds.toList()..sort(),
      'failed': failed,
      'currentGameId': currentGameId,
      'currentTurn': currentTurn,
      'updatedAt': DateTime.now().toIso8601String(),
    };
  }

  static MasterWinrateProgress load(File file) {
    if (!file.existsSync()) {
      return MasterWinrateProgress();
    }
    try {
      final Object decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map<String, dynamic>) {
        return MasterWinrateProgress();
      }
      final int version = (decoded['schemaVersion'] as num?)?.toInt() ?? 1;
      if (version < schemaVersion) {
        // v1 used SGF KM/RU (古谱会被当成中国 7.5)，不能接着用。
        return MasterWinrateProgress();
      }
      return MasterWinrateProgress(
        completedGameIds: <String>{
          ...((decoded['completedGameIds'] as List<dynamic>? ?? const <dynamic>[])
              .map((dynamic e) => e.toString())),
        },
        failed: <String, String>{
          for (final MapEntry<dynamic, dynamic> e
              in ((decoded['failed'] as Map?) ?? const <dynamic, dynamic>{}).entries)
            e.key.toString(): e.value.toString(),
        },
        currentGameId: decoded['currentGameId'] as String?,
        currentTurn: (decoded['currentTurn'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      return MasterWinrateProgress();
    }
  }
}

/// DB payload the app already understands: main-line map under "".
String winrateJsonForDb(Map<int, double> winrates) {
  final Map<String, double> main = <String, double>{};
  final List<int> turns = winrates.keys.where((int t) => t > 0).toList()..sort();
  for (final int turn in turns) {
    main['$turn'] = winrates[turn]!;
  }
  return jsonEncode(<String, dynamic>{'': main});
}
