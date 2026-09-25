import 'package:flutter_test/flutter_test.dart';
import 'package:mastergo/domain/sgf/sgf_parser.dart';
import 'package:mastergo/domain/sgf/sgf_writer.dart';
import 'package:mastergo/domain/go/go_types.dart';

void main() {
  const SgfParser parser = SgfParser();

  test('parses a simple SGF and round-trips moves', () {
    const String raw =
        '(;GM[1]FF[4]SZ[9]KM[7.5]RU[chinese]PB[Black]PW[White];B[dd];W[gg];B[])';
    final SgfGame game = parser.parse(raw);
    expect(game.boardSize, 9);
    expect(game.komi, 7.5);
    expect(game.blackName, 'Black');
    final List<SgfNode> line = game.mainLineNodes();
    expect(line.length, 3);
    expect(line[0].move?.player, GoStone.black);
    expect(line[0].move?.point, const GoPoint(3, 3));
    expect(line[2].move?.isPass, isTrue);

    final String written = serializeSgf(game);
    final SgfGame again = parser.parse(written);
    expect(again.boardSize, game.boardSize);
    expect(again.komi, game.komi);
    expect(again.mainLineNodes().length, line.length);
    expect(again.mainLineNodes()[0].move?.point, line[0].move?.point);
  });

  test('19x19 tt is a pass and ss stays the corner', () {
    const String raw = '(;GM[1]FF[4]SZ[19];B[pd];W[tt];B[ss])';
    final SgfGame game = parser.parse(raw);
    final List<SgfNode> line = game.mainLineNodes();
    expect(line[1].move?.isPass, isTrue);
    expect(line[1].move?.point, isNull);
    expect(line[1].move?.toGtp(19), 'pass');
    expect(line[2].move?.isPass, isFalse);
    expect(line[2].move?.point, const GoPoint(18, 18));
    expect(line[2].move?.toGtp(19), 'T1');
  });
}
