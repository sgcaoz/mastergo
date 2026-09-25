import 'dart:convert';

import 'package:mastergo/domain/entities/game_record.dart';

/// 开局时用来对齐「同策略」：路数、让子、规则、贴目、难度。
class BattleStrategy {
  const BattleStrategy({
    required this.boardSize,
    required this.handicap,
    required this.ruleset,
    required this.komi,
    required this.profileId,
  });

  final int boardSize;
  final int handicap;
  final String ruleset;
  final double komi;
  final String profileId;
}

Map<String, dynamic>? battleSessionOf(GameRecord record) {
  if (record.sessionJson.trim().isEmpty) {
    return null;
  }
  try {
    final Object decoded = jsonDecode(record.sessionJson);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    if (decoded is Map) {
      return Map<String, dynamic>.from(decoded);
    }
  } catch (_) {}
  return null;
}

/// 不足 21 手不进本机棋谱，也不能当成没下完的对局接着下。
const int kMinRecordedBattleMoves = 21;

/// 下过足够的子、还没终局。不足 21 手和空记录都不算。
bool battleRecordIsResumable(GameRecord record) {
  if (record.status == 'finished') {
    return false;
  }
  final Map<String, dynamic>? session = battleSessionOf(record);
  if (session == null) {
    return false;
  }
  if (session['finalScore'] != null) {
    return false;
  }
  final Object? resign = session['resignResult'];
  if (resign is String && resign.isNotEmpty) {
    return false;
  }
  final Object? moves = session['moves'];
  return moves is List && moves.length >= kMinRecordedBattleMoves;
}

bool battleRecordMatchesStrategy(GameRecord record, BattleStrategy strategy) {
  final Map<String, dynamic>? session = battleSessionOf(record);
  if (session == null) {
    return false;
  }
  final int boardSize =
      (session['boardSize'] as num?)?.toInt() ?? record.boardSize;
  final int handicap = (session['handicap'] as num?)?.toInt() ?? 0;
  final String ruleset = (session['ruleset'] as String?) ?? record.ruleset;
  final double komi = (session['komi'] as num?)?.toDouble() ?? record.komi;
  final String profileId = (session['profileId'] as String?) ?? '';
  if (boardSize != strategy.boardSize || handicap != strategy.handicap) {
    return false;
  }
  if (ruleset != strategy.ruleset || (komi - strategy.komi).abs() >= 0.01) {
    return false;
  }
  if (profileId.isNotEmpty && profileId != strategy.profileId) {
    return false;
  }
  return true;
}

/// 同策略下，最近一盘没下完的。已结束的更新记录不能把更早的未完成对局挡住。
GameRecord? pickLatestUnfinishedBattle(
  Iterable<GameRecord> records,
  BattleStrategy strategy,
) {
  GameRecord? best;
  for (final GameRecord record in records) {
    if (!battleRecordIsResumable(record) ||
        !battleRecordMatchesStrategy(record, strategy)) {
      continue;
    }
    if (best == null || record.updatedAtMs > best.updatedAtMs) {
      best = record;
    }
  }
  return best;
}
