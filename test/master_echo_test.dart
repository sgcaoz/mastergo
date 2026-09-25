import 'package:flutter_test/flutter_test.dart';
import 'package:mastergo/application/study/master_echo.dart';
import 'package:mastergo/domain/go/go_types.dart';
import 'package:mastergo/domain/sgf/sgf_parser.dart';
import 'package:mastergo/domain/study/opening_tokens.dart';

void main() {
  const SgfParser parser = SgfParser();

  test('commonPrefixLength stops at first difference', () {
    expect(
      commonPrefixLength(const <String>['B:Q16', 'W:D16', 'B:Q4'], const <String>[
        'B:Q16',
        'W:D16',
        'B:C4',
      ]),
      2,
    );
  });

  test('lookup returns the next master move at the longest shared opening', () {
    const String shared =
        '(;GM[1]FF[4]SZ[19]PB[Alpha]PW[Beta];B[pd];W[dp];B[pq];W[dd];B[oc])';
    const String fork =
        '(;GM[1]FF[4]SZ[19]PB[Go Seigen]PW[Kitani];B[pd];W[dp];B[pq];W[dd];B[cq])';
    final MasterEchoIndex index = MasterEchoIndex();
    index.replaceGames(<MasterEchoGame>[
      MasterEchoGame(
        id: 'g1',
        title: 'Alpha vs Beta',
        players: 'Alpha vs Beta',
        year: 2017,
        category: 'ai',
        boardSize: 19,
        tokens: openingTokensFromSgf(parser.parse(shared)),
      ),
      MasterEchoGame(
        id: 'g2',
        title: 'Wu vs Kitani',
        players: 'Go Seigen vs Kitani',
        year: 1933,
        category: 'classic',
        boardSize: 19,
        tokens: openingTokensFromSgf(parser.parse(fork)),
      ),
    ]);

    final List<String> query = openingTokensFromSgf(
      parser.parse(
        '(;GM[1]FF[4]SZ[19];B[pd];W[dp];B[pq];W[dd])',
      ),
    );
    final List<MasterEchoHit> hits = index.lookup(query, excludeId: 'g1');
    expect(hits, hasLength(1));
    expect(hits.single.game.id, 'g2');
    expect(hits.single.matchedDepth, 4);
    expect(hits.single.nextMoveToken, 'B:C3');
  });

  test('daily pick is stable for the same UTC day', () {
    final MasterEchoIndex index = MasterEchoIndex();
    index.replaceGames(
      List<MasterEchoGame>.generate(11, (int i) {
        return MasterEchoGame(
          id: 'g$i',
          title: 'G$i',
          players: 'P$i',
          year: 2000 + i,
          category: 'classic',
          boardSize: 19,
          tokens: const <String>['B:Q16'],
        );
      }),
    );
    final DateTime day = DateTime.utc(2026, 9, 14);
    expect(index.dailyPick(day)?.id, index.dailyPick(day.add(const Duration(hours: 5)))?.id);
    expect(index.dailyPick(day)?.id, isNot(index.dailyPick(day.add(const Duration(days: 1)))?.id));
  });

  test('prettyMoveToken keeps color readable', () {
    expect(prettyMoveToken('B:Q16'), 'Q16 黑');
    expect(
      prettyMoveToken(GoMove(player: GoStone.white, point: const GoPoint(3, 3)).toProtocolToken(19)),
      'D16 白',
    );
  });
}
