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
            startingPlayer: StoneColor.black,
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

  List<MoveHint> buildHints(
    Map<int, double> blackWinrateByTurn, {
    required GoStone playerStone,
    double blunderThreshold = 0.20,
    double brilliantEpsilon = 0.05,
  }) {
    final List<int> turns = blackWinrateByTurn.keys.toList()..sort();
    final List<MoveHint> hints = <MoveHint>[];
    for (int i = 1; i < turns.length; i++) {
      final int prevTurn = turns[i - 1];
      final int turn = turns[i];
      final double deltaBlack =
          blackWinrateByTurn[turn]! - blackWinrateByTurn[prevTurn]!;
      final bool isPlayerTurn = playerStone == GoStone.black
          ? turn.isOdd
          : turn.isEven;
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
      } else if (deltaPlayer <= -blunderThreshold) {
        hints.add(
          MoveHint(
            turn: turn,
            deltaPlayerWinrate: deltaPlayer,
            kind: HintKind.blunder,
          ),
        );
      }
    }
    return hints;
  }
}
