import 'package:flutter_test/flutter_test.dart';
import 'package:mastergo/domain/entities/game_record.dart';
import 'package:mastergo/features/ai_play/unfinished_battle.dart';

GameRecord _record({
  required String id,
  required int updatedAtMs,
  required String status,
  required String sessionJson,
  String source = 'battle_local',
}) {
  return GameRecord(
    id: id,
    source: source,
    title: id,
    boardSize: 19,
    ruleset: 'chinese',
    komi: 7.5,
    sgf: '(;FF[4]SZ[19])',
    status: status,
    sessionJson: sessionJson,
    winrateJson: '{}',
    createdAtMs: updatedAtMs,
    updatedAtMs: updatedAtMs,
  );
}

String _session({
  required int moves,
  String profileId = 'challenge',
  int handicap = 0,
  double komi = 7.5,
  bool finished = false,
}) {
  return '''
{
  "boardSize": 19,
  "handicap": $handicap,
  "profileId": "$profileId",
  "ruleset": "chinese",
  "komi": $komi,
  "moves": ${List<String>.generate(moves, (int i) => '{"player":"black","isPass":false,"x":3,"y":3}').toString()},
  "finalScore": ${finished ? '{"komi": 7.5}' : 'null'},
  "resignResult": null
}
''';
}

void main() {
  const BattleStrategy strategy = BattleStrategy(
    boardSize: 19,
    handicap: 0,
    ruleset: 'chinese',
    komi: 7.5,
    profileId: 'challenge',
  );

  test('newer finished game does not hide an older unfinished game', () {
    final GameRecord unfinished = _record(
      id: 'old',
      updatedAtMs: 10,
      status: 'active',
      sessionJson: _session(moves: 24),
    );
    final GameRecord finished = _record(
      id: 'new',
      updatedAtMs: 20,
      status: 'finished',
      sessionJson: _session(moves: 40, finished: true),
    );
    expect(
      pickLatestUnfinishedBattle(<GameRecord>[
        finished,
        unfinished,
      ], strategy)?.id,
      'old',
    );
  });

  test('empty shell does not replace a real unfinished game', () {
    final GameRecord unfinished = _record(
      id: 'real',
      updatedAtMs: 10,
      status: 'active',
      sessionJson: _session(moves: 22),
      source: 'battle_temp',
    );
    final GameRecord empty = _record(
      id: 'shell',
      updatedAtMs: 30,
      status: 'active',
      sessionJson: _session(moves: 0),
    );
    expect(
      pickLatestUnfinishedBattle(<GameRecord>[empty, unfinished], strategy)?.id,
      'real',
    );
  });

  test('different difficulty is not the same strategy', () {
    final GameRecord other = _record(
      id: 'master',
      updatedAtMs: 50,
      status: 'active',
      sessionJson: _session(moves: 30, profileId: 'master'),
    );
    final GameRecord same = _record(
      id: 'challenge',
      updatedAtMs: 40,
      status: 'active',
      sessionJson: _session(moves: 21),
    );
    expect(
      pickLatestUnfinishedBattle(<GameRecord>[other, same], strategy)?.id,
      'challenge',
    );
  });

  test('fewer than 21 moves is not resumed', () {
    final GameRecord short = _record(
      id: 'short',
      updatedAtMs: 50,
      status: 'active',
      sessionJson: _session(moves: 8),
    );
    expect(battleRecordIsResumable(short), isFalse);
    expect(pickLatestUnfinishedBattle(<GameRecord>[short], strategy), isNull);
  });

  test('no unfinished game means start fresh', () {
    final GameRecord finished = _record(
      id: 'done',
      updatedAtMs: 20,
      status: 'finished',
      sessionJson: _session(moves: 40, finished: true),
    );
    expect(
      pickLatestUnfinishedBattle(<GameRecord>[finished], strategy),
      isNull,
    );
  });
}
