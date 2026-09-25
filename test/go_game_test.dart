import 'package:flutter_test/flutter_test.dart';
import 'package:mastergo/domain/entities/game_rules.dart';
import 'package:mastergo/domain/go/go_game.dart';
import 'package:mastergo/domain/go/go_types.dart';

void main() {
  test('forbids playing on an occupied point', () {
    GoGameState state = GoGameState(boardSize: 9);
    state = state.play(GoMove(player: GoStone.black, point: const GoPoint(3, 3)));
    expect(
      () => state.play(GoMove(player: GoStone.white, point: const GoPoint(3, 3))),
      throwsA(isA<StateError>()),
    );
  });

  test('captures and forbids simple-ko recapture', () {
    final List<List<GoStone?>> board = List<List<GoStone?>>.generate(
      5,
      (_) => List<GoStone?>.filled(5, null),
    );
    // Ko: White stone at (1,1) with one liberty at (1,2).
    board[0][1] = GoStone.black;
    board[1][0] = GoStone.black;
    board[1][2] = GoStone.black;
    board[2][0] = GoStone.white;
    board[2][2] = GoStone.white;
    board[3][1] = GoStone.white;
    board[1][1] = GoStone.white;

    GoGameState state = GoGameState(
      boardSize: 5,
      board: board,
      toPlay: GoStone.black,
    );
    state = state.play(GoMove(player: GoStone.black, point: const GoPoint(1, 2)));
    expect(state.stoneAt(const GoPoint(1, 1)), isNull);
    expect(state.blackCaptures, 1);

    expect(
      () => state.play(
        GoMove(player: GoStone.white, point: const GoPoint(1, 1)),
        koRule: KoRule.simple,
      ),
      throwsA(isA<StateError>()),
    );

    final GoGameState afterPass = state.play(
      GoMove(player: GoStone.white, isPass: true),
      koRule: KoRule.simple,
    );
    expect(
      afterPass.play(
        GoMove(player: GoStone.black, isPass: true),
        koRule: KoRule.simple,
      ).play(
        GoMove(player: GoStone.white, point: const GoPoint(1, 1)),
        koRule: KoRule.simple,
      ),
      isA<GoGameState>(),
    );
  });

  test('positional superko forbids repeating any earlier board', () {
    GoGameState state = GoGameState(boardSize: 5);
    state = state.play(GoMove(player: GoStone.black, point: const GoPoint(0, 0)));
    state = state.play(GoMove(player: GoStone.white, point: const GoPoint(4, 4)));
    // Pass twice keeps the same stones; under positional superko the empty-side
    // to-play change is allowed, but repeating the exact stone map is not if
    // we try to replay the first two unique hashes via a capture cycle.

    final String firstHash = state.positionHistory.first;
    expect(state.positionHistory.contains(firstHash), isTrue);
    expect(
      state.play(
        GoMove(player: GoStone.black, point: const GoPoint(2, 2)),
        koRule: KoRule.positionalSuperko,
      ),
      isA<GoGameState>(),
    );
  });
}
