import 'package:mastergo/domain/go/go_types.dart';
import 'package:mastergo/domain/sgf/sgf_parser.dart';

/// SGF 序列化：将 [SgfGame] 写回为 SGF 字符串，支持根节点属性、着法、注释与变化图。
String serializeSgf(SgfGame game) {
  final StringBuffer sb = StringBuffer();
  sb.write('(;');
  _writeRootProps(sb, game);
  _writeChildren(sb, game.root.children, game.boardSize);
  sb.write(')');
  return sb.toString();
}

void _writeRootProps(StringBuffer sb, SgfGame game) {
  sb.write('GM[1]FF[4]');
  sb.write('SZ[${game.boardSize}]');
  sb.write('KM[${game.komi}]');
  sb.write('RU[${game.rules}]');
  for (final GoPoint p in game.initialBlackStones) {
    sb.write('AB[${_pointToSgfCoord(p)}]');
  }
  for (final GoPoint p in game.initialWhiteStones) {
    sb.write('AW[${_pointToSgfCoord(p)}]');
  }
  if (game.blackName != null && game.blackName!.isNotEmpty) {
    sb.write('PB[${_escapeText(game.blackName!)}]');
  }
  if (game.whiteName != null && game.whiteName!.isNotEmpty) {
    sb.write('PW[${_escapeText(game.whiteName!)}]');
  }
  if (game.gameName != null && game.gameName!.isNotEmpty) {
    sb.write('GN[${_escapeText(game.gameName!)}]');
  }
  if (game.result != null && game.result!.isNotEmpty) {
    sb.write('RE[${_escapeText(game.result!)}]');
  }
}

void _writeNodeSequence(StringBuffer sb, SgfNode node, int boardSize) {
  sb.write(';');
  _writeNodeProps(sb, node, boardSize);
  _writeChildren(sb, node.children, boardSize);
}

void _writeChildren(StringBuffer sb, List<SgfNode> children, int boardSize) {
  if (children.isEmpty) {
    return;
  }
  if (children.length == 1) {
    _writeNodeSequence(sb, children.first, boardSize);
    return;
  }
  for (final SgfNode child in children) {
    sb.write('(');
    _writeNodeSequence(sb, child, boardSize);
    sb.write(')');
  }
}

void _writeNodeProps(StringBuffer sb, SgfNode node, int boardSize) {
  if (node.move != null) {
    final GoMove m = node.move!;
    final String color = m.player == GoStone.black ? 'B' : 'W';
    if (m.isPass || m.point == null) {
      sb.write('$color[]');
    } else {
      sb.write('$color[${_pointToSgfCoord(m.point!)}]');
    }
  }
  if (node.comment != null && node.comment!.isNotEmpty) {
    sb.write('C[${_escapeText(node.comment!)}]');
  }
}

const String _letters = 'abcdefghijklmnopqrstuvwxyz';

String _pointToSgfCoord(GoPoint p) {
  if (p.x < 0 || p.x >= 26 || p.y < 0 || p.y >= 26) {
    return 'aa';
  }
  return '${_letters[p.x]}${_letters[p.y]}';
}

String _escapeText(String s) {
  return s.replaceAll('\\', '\\\\').replaceAll(']', '\\]');
}
