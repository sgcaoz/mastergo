import 'package:mastergo/domain/go/go_types.dart';

class SgfGame {
  const SgfGame({
    required this.boardSize,
    required this.komi,
    required this.rules,
    required this.root,
    this.initialBlackStones = const <GoPoint>[],
    this.initialWhiteStones = const <GoPoint>[],
    this.blackName,
    this.whiteName,
    this.gameName,
    this.result,
    this.playerToMove,
    this.comment,
  });

  final int boardSize;
  final double komi;
  final String rules;
  final SgfNode root;
  final List<GoPoint> initialBlackStones;
  final List<GoPoint> initialWhiteStones;
  final String? blackName;
  final String? whiteName;
  final String? gameName;
  final String? result;

  /// Root `PL[]` if present.
  final GoStone? playerToMove;

  /// Root comment (`C[]` on the first node).
  final String? comment;

  SgfGame copyWith({double? komi, String? rules}) {
    return SgfGame(
      boardSize: boardSize,
      komi: komi ?? this.komi,
      rules: rules ?? this.rules,
      root: root,
      initialBlackStones: initialBlackStones,
      initialWhiteStones: initialWhiteStones,
      blackName: blackName,
      whiteName: whiteName,
      gameName: gameName,
      result: result,
      playerToMove: playerToMove,
      comment: comment,
    );
  }

  List<SgfNode> mainLineNodes() {
    final List<SgfNode> nodes = <SgfNode>[];
    SgfNode cur = root;
    while (cur.children.isNotEmpty) {
      cur = cur.children.first;
      nodes.add(cur);
    }
    return nodes;
  }
}

class SgfNode {
  SgfNode({this.move, this.comment, this.moveNumber = 0});

  final GoMove? move;

  /// 节点注释（打谱笔记）。可写，保存时写回 SGF 的 C[]。
  String? comment;
  final int moveNumber;
  final List<SgfNode> children = <SgfNode>[];
}

class SgfParser {
  const SgfParser();

  SgfGame parse(String content) {
    final _SgfCursor cursor = _SgfCursor(content);
    final SgfNode root = SgfNode(moveNumber: 0);
    _SgfMeta meta = _SgfMeta();
    _parseTree(cursor, root, 0, meta, (m) => meta = m);
    return SgfGame(
      boardSize: meta.boardSize,
      komi: meta.komi,
      rules: meta.rules,
      root: root,
      initialBlackStones: meta.initialBlackStones,
      initialWhiteStones: meta.initialWhiteStones,
      blackName: meta.blackName,
      whiteName: meta.whiteName,
      gameName: meta.gameName,
      result: meta.result,
      playerToMove: meta.playerToMove,
      comment: root.comment ?? meta.comment,
    );
  }

  /// Collection files nest one problem per child tree. Each child inherits
  /// board size from the outer root when it has no `SZ`.
  List<SgfGame> parseCollection(String content) {
    final _SgfCursor cursor = _SgfCursor(content);
    cursor.skipUntil('(');
    if (!cursor.tryRead('(')) {
      return const <SgfGame>[];
    }
    while (!cursor.isEnd && cursor.peek != ';') {
      if (cursor.peek == '(') {
        break;
      }
      cursor.read();
    }
    Map<String, List<String>> collectionProps = <String, List<String>>{};
    if (!cursor.isEnd && cursor.peek == ';') {
      cursor.read();
      collectionProps = _readNodeProps(cursor);
    }
    final int inheritedSize =
        int.tryParse(
          collectionProps['SZ']?.isNotEmpty == true
              ? collectionProps['SZ']!.first
              : '',
        ) ??
        19;
    final List<SgfGame> games = <SgfGame>[];
    while (!cursor.isEnd) {
      if (cursor.peek == ')') {
        cursor.read();
        break;
      }
      if (cursor.peek == '(') {
        final String tree = _readBalancedTree(cursor);
        if (tree.trim().isEmpty) {
          continue;
        }
        final String injectable = _ensureBoardSize(tree, inheritedSize);
        try {
          games.add(parse(injectable));
        } catch (_) {
          // Skip a malformed problem; keep the rest of the collection.
        }
        continue;
      }
      cursor.read();
    }
    if (games.isEmpty) {
      final SgfGame single = parse(content);
      if (single.initialBlackStones.isNotEmpty ||
          single.initialWhiteStones.isNotEmpty) {
        return <SgfGame>[single];
      }
    }
    return games;
  }

  String _readBalancedTree(_SgfCursor cursor) {
    if (cursor.isEnd || cursor.peek != '(') {
      return '';
    }
    final int start = cursor._idx;
    int depth = 0;
    bool inBracket = false;
    bool escape = false;
    while (!cursor.isEnd) {
      final String ch = cursor.read();
      if (escape) {
        escape = false;
        continue;
      }
      if (ch == '\\') {
        escape = true;
        continue;
      }
      if (ch == '[') {
        inBracket = true;
        continue;
      }
      if (ch == ']') {
        inBracket = false;
        continue;
      }
      if (inBracket) {
        continue;
      }
      if (ch == '(') {
        depth++;
      } else if (ch == ')') {
        depth--;
        if (depth == 0) {
          return cursor._text.substring(start, cursor._idx);
        }
      }
    }
    return cursor._text.substring(start);
  }

  String _ensureBoardSize(String tree, int boardSize) {
    final String trimmed = tree.trim();
    if (RegExp(r'SZ\s*\[').hasMatch(trimmed)) {
      return trimmed;
    }
    final int semi = trimmed.indexOf(';');
    if (semi < 0) {
      return trimmed;
    }
    return '${trimmed.substring(0, semi + 1)}SZ[$boardSize]${trimmed.substring(semi + 1)}';
  }

  void _parseTree(
    _SgfCursor cursor,
    SgfNode attachTo,
    int baseMoveNumber,
    _SgfMeta meta,
    void Function(_SgfMeta) setMeta,
  ) {
    cursor.skipUntil('(');
    if (!cursor.tryRead('(')) {
      return;
    }

    SgfNode current = attachTo;
    int moveNumber = baseMoveNumber;
    while (!cursor.isEnd) {
      if (cursor.peek == ';') {
        cursor.read();
        final Map<String, List<String>> props = _readNodeProps(cursor);
        if (!meta.rootSeen) {
          meta = meta.withRootProps(props);
          setMeta(meta);
          if (props['C']?.isNotEmpty == true && current.comment == null) {
            current.comment = props['C']!.first;
          }
        }
        final GoMove? move = _moveFromProps(props, meta.boardSize);
        if (move != null) {
          moveNumber += 1;
          final SgfNode node = SgfNode(
            move: move,
            comment: props['C']?.isNotEmpty == true ? props['C']!.first : null,
            moveNumber: moveNumber,
          );
          current.children.add(node);
          current = node;
        }
        continue;
      }
      if (cursor.peek == '(') {
        _parseTree(cursor, current, moveNumber, meta, setMeta);
        continue;
      }
      if (cursor.peek == ')') {
        cursor.read();
        return;
      }
      cursor.read();
    }
  }

  Map<String, List<String>> _readNodeProps(_SgfCursor cursor) {
    final Map<String, List<String>> props = <String, List<String>>{};
    while (!cursor.isEnd) {
      if (cursor.peek == ';' || cursor.peek == '(' || cursor.peek == ')') {
        break;
      }
      if (!_isUpperAlpha(cursor.peek)) {
        cursor.read();
        continue;
      }
      final String key = cursor.readWhile(_isUpperAlpha);
      final List<String> values = <String>[];
      while (!cursor.isEnd && cursor.peek == '[') {
        cursor.read();
        final StringBuffer sb = StringBuffer();
        while (!cursor.isEnd && cursor.peek != ']') {
          final String ch = cursor.read();
          if (ch == '\\' && !cursor.isEnd) {
            sb.write(cursor.read());
          } else {
            sb.write(ch);
          }
        }
        cursor.tryRead(']');
        values.add(sb.toString());
      }
      // 同一属性多次出现（如 AB[dd]AB[pd]）需合并，否则让子等只保留最后一个
      final List<String> existing = props[key] ?? <String>[];
      existing.addAll(values);
      props[key] = existing;
    }
    return props;
  }

  GoMove? _moveFromProps(Map<String, List<String>> props, int boardSize) {
    if (props.containsKey('B')) {
      return _moveFromRaw(
        GoStone.black,
        props['B']!.isNotEmpty ? props['B']!.first : '',
        boardSize,
      );
    }
    if (props.containsKey('W')) {
      return _moveFromRaw(
        GoStone.white,
        props['W']!.isNotEmpty ? props['W']!.first : '',
        boardSize,
      );
    }
    return null;
  }

  GoMove _moveFromRaw(GoStone stone, String raw, int boardSize) {
    if (raw.length < 2) {
      return GoMove(player: stone, isPass: true);
    }
    final int x = raw.codeUnitAt(0) - 'a'.codeUnitAt(0);
    final int y = raw.codeUnitAt(1) - 'a'.codeUnitAt(0);
    // 棋盘外的坐标是停着。19 路常见写法是 tt，不能收成角落上的子。
    if (x < 0 || y < 0 || x >= boardSize || y >= boardSize) {
      return GoMove(player: stone, isPass: true);
    }
    return GoMove(player: stone, point: GoPoint(x, y));
  }

  bool _isUpperAlpha(String c) {
    final int v = c.codeUnitAt(0);
    return v >= 65 && v <= 90;
  }
}

class _SgfMeta {
  _SgfMeta({
    this.rootSeen = false,
    this.boardSize = 19,
    this.komi = 7.5,
    this.rules = 'chinese',
    this.initialBlackStones = const <GoPoint>[],
    this.initialWhiteStones = const <GoPoint>[],
    this.blackName,
    this.whiteName,
    this.gameName,
    this.result,
    this.playerToMove,
    this.comment,
  });

  final bool rootSeen;
  final int boardSize;
  final double komi;
  final String rules;
  final List<GoPoint> initialBlackStones;
  final List<GoPoint> initialWhiteStones;
  final String? blackName;
  final String? whiteName;
  final String? gameName;
  final String? result;
  final GoStone? playerToMove;
  final String? comment;

  _SgfMeta withRootProps(Map<String, List<String>> props) {
    String? first(String key) =>
        props[key]?.isNotEmpty == true ? props[key]!.first : null;
    final int parsedBoardSize = int.tryParse(first('SZ') ?? '19') ?? 19;

    List<GoPoint> parseCoords(String key) {
      final List<String> raw = props[key] ?? const <String>[];
      final List<GoPoint> points = <GoPoint>[];
      for (final String s in raw) {
        if (s.length < 2) {
          continue;
        }
        final int x = s.codeUnitAt(0) - 'a'.codeUnitAt(0);
        final int y = s.codeUnitAt(1) - 'a'.codeUnitAt(0);
        if (x < 0 || y < 0 || x >= parsedBoardSize || y >= parsedBoardSize) {
          continue;
        }
        points.add(GoPoint(x, y));
      }
      return points;
    }

    return _SgfMeta(
      rootSeen: true,
      boardSize: parsedBoardSize,
      komi: double.tryParse(first('KM') ?? '7.5') ?? 7.5,
      rules: (first('RU') ?? 'chinese').toLowerCase(),
      initialBlackStones: parseCoords('AB'),
      initialWhiteStones: parseCoords('AW'),
      blackName: first('PB'),
      whiteName: first('PW'),
      gameName: first('GN'),
      result: first('RE'),
      playerToMove: _playerToMoveFromRaw(first('PL')),
      comment: first('C'),
    );
  }
}

GoStone? _playerToMoveFromRaw(String? raw) {
  if (raw == null || raw.isEmpty) {
    return null;
  }
  final String token = raw.trim().toUpperCase();
  if (token.startsWith('W')) {
    return GoStone.white;
  }
  if (token.startsWith('B')) {
    return GoStone.black;
  }
  return null;
}

class _SgfCursor {
  _SgfCursor(this._text);

  final String _text;
  int _idx = 0;

  bool get isEnd => _idx >= _text.length;
  String get peek => _text[_idx];

  String read() => _text[_idx++];

  bool tryRead(String ch) {
    if (isEnd || _text[_idx] != ch) {
      return false;
    }
    _idx++;
    return true;
  }

  void skipUntil(String ch) {
    while (!isEnd && _text[_idx] != ch) {
      _idx++;
    }
  }

  String readWhile(bool Function(String) predicate) {
    final StringBuffer sb = StringBuffer();
    while (!isEnd && predicate(_text[_idx])) {
      sb.write(_text[_idx]);
      _idx++;
    }
    return sb.toString();
  }
}
