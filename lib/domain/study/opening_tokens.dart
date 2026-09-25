import 'package:mastergo/domain/go/go_types.dart';
import 'package:mastergo/domain/sgf/sgf_parser.dart';

/// Protocol tokens for a main-line prefix, e.g. `B:Q16`.
List<String> openingTokensFromSgf(SgfGame game) {
  return game.mainLineNodes()
      .where((SgfNode node) => node.move != null)
      .map((SgfNode node) => node.move!.toProtocolToken(game.boardSize))
      .toList(growable: false);
}

List<String> openingTokensFromMoves(List<GoMove> moves, int boardSize) {
  return moves
      .map((GoMove move) => move.toProtocolToken(boardSize))
      .toList(growable: false);
}

int commonPrefixLength(List<String> a, List<String> b) {
  final int n = a.length < b.length ? a.length : b.length;
  int i = 0;
  while (i < n && a[i] == b[i]) {
    i += 1;
  }
  return i;
}

String prettyMoveToken(String token) {
  final int sep = token.indexOf(':');
  if (sep <= 0 || sep == token.length - 1) {
    return token;
  }
  final String color = token.substring(0, sep).toUpperCase();
  final String point = token.substring(sep + 1);
  if (color == 'B') {
    return '$point 黑';
  }
  if (color == 'W') {
    return '$point 白';
  }
  return '$point $color';
}
