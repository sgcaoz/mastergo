import 'package:mastergo/domain/entities/analysis_profile.dart';
import 'package:mastergo/domain/entities/game_setup.dart';
import 'package:mastergo/domain/entities/rule_presets.dart';
import 'package:mastergo/domain/go/go_types.dart';
import 'package:mastergo/infra/engine/katago/katago_adapter.dart';

enum HintKind { brilliant, blunder }

class MoveHint {
  const MoveHint({
    required this.turn,
    required this.deltaPlayerWinrate,
    required this.kind,
  });

  final int turn;
  final double deltaPlayerWinrate;
  final HintKind kind;
}

class GameAnalysisService {
  const GameAnalysisService();

  Future<Map<int, double>> analyzeTurns({
    required KatagoAdapter adapter,
    required List<String> moveTokens,
    required int boardSize,
    required String ruleset,
    required double komi,
    required AnalysisProfile profile,
    List<String> initialStones = const <String>[],
    StoneColor startingPlayer = StoneColor.black,
    int? timeoutMs,
    void Function(int turn, int total)? onProgress,
    int startTurn = 0,
    int? maxTurnsToAnalyze,
  }) async {
    await adapter.ensureStarted();
    final Map<int, double> winrates = <int, double>{};
    final rules = rulePresetFromString(ruleset).toGameRules(komi: komi);
    final int endTurn = maxTurnsToAnalyze == null
        ? moveTokens.length
        : (startTurn + maxTurnsToAnalyze - 1).clamp(0, moveTokens.length);

    for (int turn = startTurn; turn <= endTurn; turn++) {
      final KatagoAnalyzeResult res = await adapter.analyze(
        KatagoAnalyzeRequest(
          queryId: 'ana-$turn-${DateTime.now().millisecondsSinceEpoch}',
          moves: moveTokens.take(turn).toList(),
          initialStones: initialStones,
          gameSetup: GameSetup(
            boardSize: boardSize,
            startingPlayer: startingPlayer,
          ),
          rules: rules,
          profile: profile,
          timeoutMs: timeoutMs,
        ),
      );
      winrates[turn] = res.winrate;
      onProgress?.call(turn, moveTokens.length);
    }
    return winrates;
  }

  /// 前期（手数<=50）恶手：胜率跌 10%；后期：胜率跌 20%。
  static const int blunderEarlyCutoff = 50;
  static const double blunderEarlyThreshold = 0.10;
  static const double blunderLateThreshold = 0.20;

  /// [firstMoveIsBlack] 若为 false 表示让子/白先（turn 1 为白），则黑在 2,4,6… 手；为 true 表示无让子（turn 1 为黑）。
  List<MoveHint> buildHints(
    Map<int, double> blackWinrateByTurn, {
    required GoStone playerStone,
    bool firstMoveIsBlack = true,
    double blunderThreshold = 0.20,
    double brilliantEpsilon = 0.05,
    int? blunderEarlyTurnCutoff,
    double? blunderEarlyThresholdParam,
    double? blunderLateThresholdParam,
  }) {
    final int earlyCutoff = blunderEarlyTurnCutoff ?? blunderEarlyCutoff;
    final double earlyTh = blunderEarlyThresholdParam ?? blunderEarlyThreshold;
    final double lateTh = blunderLateThresholdParam ?? blunderLateThreshold;
    final List<int> turns = blackWinrateByTurn.keys.toList()..sort();
    final List<MoveHint> hints = <MoveHint>[];
    for (int i = 1; i < turns.length; i++) {
      final int prevTurn = turns[i - 1];
      final int turn = turns[i];
      final double deltaBlack =
          blackWinrateByTurn[turn]! - blackWinrateByTurn[prevTurn]!;
      // 该手是谁下的：无让子时 turn 1=黑(odd)，让子时 turn 1=白，2=黑(even)
      final bool isBlackTurn = firstMoveIsBlack ? turn.isOdd : turn.isEven;
      final bool isPlayerTurn = (playerStone == GoStone.black) == isBlackTurn;
      if (!isPlayerTurn) {
        continue;
      }
      final double deltaPlayer = playerStone == GoStone.black
          ? deltaBlack
          : -deltaBlack;
      if (deltaPlayer >= brilliantEpsilon) {
        hints.add(
          MoveHint(
            turn: turn,
            deltaPlayerWinrate: deltaPlayer,
            kind: HintKind.brilliant,
          ),
        );
      } else {
        final double th = turn <= earlyCutoff ? earlyTh : lateTh;
        if (deltaPlayer <= -th) {
          hints.add(
            MoveHint(
              turn: turn,
              deltaPlayerWinrate: deltaPlayer,
              kind: HintKind.blunder,
            ),
          );
        }
      }
    }
    return hints;
  }
}
