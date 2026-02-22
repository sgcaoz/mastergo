import 'dart:collection';

import 'package:mastergo/domain/entities/game_rules.dart';
import 'package:mastergo/domain/go/go_types.dart';

class GoGameState {
  GoGameState({
    required this.boardSize,
    List<List<GoStone?>>? board,
    this.toPlay = GoStone.black,
    List<GoMove>? moves,
    this.previousBoardHash = '',
    this.consecutivePasses = 0,
    this.blackCaptures = 0,
    this.whiteCaptures = 0,
  }) : board =
           board ??
           List<List<GoStone?>>.generate(
             boardSize,
             (_) => List<GoStone?>.filled(boardSize, null),
           ),
       moves = moves ?? <GoMove>[];

  final int boardSize;
  final List<List<GoStone?>> board;
  final GoStone toPlay;
  final List<GoMove> moves;
  final String previousBoardHash;
  final int consecutivePasses;
  final int blackCaptures;
  final int whiteCaptures;

  bool inBounds(GoPoint p) =>
      p.x >= 0 && p.x < boardSize && p.y >= 0 && p.y < boardSize;

  GoStone? stoneAt(GoPoint p) => board[p.y][p.x];

  GoGameState play(GoMove move) {
    if (move.player != toPlay) {
      throw StateError('Not ${move.player} turn');
    }
    if (move.isPass) {
      return GoGameState(
        boardSize: boardSize,
        board: _copyBoard(board),
        toPlay: toPlay.opposite(),
        moves: <GoMove>[...moves, move],
        previousBoardHash: boardHash(board),
        consecutivePasses: consecutivePasses + 1,
        blackCaptures: blackCaptures,
        whiteCaptures: whiteCaptures,
      );
    }

    final GoPoint point = move.point!;
    if (!inBounds(point)) {
      throw StateError('Point out of board');
    }
    if (stoneAt(point) != null) {
      throw StateError('Occupied point');
    }

    final List<List<GoStone?>> nextBoard = _copyBoard(board);
    nextBoard[point.y][point.x] = move.player;
    int capturedStones = 0;

    final GoStone enemy = move.player.opposite();
    for (final GoPoint n in _neighbors(point)) {
      if (!inBounds(n) || nextBoard[n.y][n.x] != enemy) {
        continue;
      }
      final _Group group = _collectGroup(nextBoard, n);
      if (group.liberties.isEmpty) {
        capturedStones += group.stones.length;
        for (final GoPoint gp in group.stones) {
          nextBoard[gp.y][gp.x] = null;
        }
      }
    }

    final _Group selfGroup = _collectGroup(nextBoard, point);
    if (selfGroup.liberties.isEmpty) {
      throw StateError('Suicide move');
    }

    final String nextHash = boardHash(nextBoard);
    if (nextHash == previousBoardHash) {
      throw StateError('Ko violation');
    }

    return GoGameState(
      boardSize: boardSize,
      board: nextBoard,
      toPlay: toPlay.opposite(),
      moves: <GoMove>[...moves, move],
      previousBoardHash: boardHash(board),
      consecutivePasses: 0,
      blackCaptures: move.player == GoStone.black
          ? blackCaptures + capturedStones
          : blackCaptures,
      whiteCaptures: move.player == GoStone.white
          ? whiteCaptures + capturedStones
          : whiteCaptures,
    );
  }

  GoScore scoreByRules(GameRules rules) {
    return rules.scoringRule == ScoringRule.area
        ? scoreChineseArea(komi: rules.komi)
        : scoreTerritory(komi: rules.komi);
  }

  GoScore scoreChineseArea({double komi = 7.5}) {
    int blackStones = 0;
    int whiteStones = 0;
    int blackTerritory = 0;
    int whiteTerritory = 0;
    final Set<GoPoint> visited = <GoPoint>{};

    for (int y = 0; y < boardSize; y++) {
      for (int x = 0; x < boardSize; x++) {
        final GoStone? s = board[y][x];
        if (s == GoStone.black) {
          blackStones++;
          continue;
        }
        if (s == GoStone.white) {
          whiteStones++;
          continue;
        }
        final GoPoint p = GoPoint(x, y);
        if (visited.contains(p)) {
          continue;
        }
        final _Region region = _collectEmptyRegion(p, visited);
        if (region.borderColors.length == 1) {
          if (region.borderColors.contains(GoStone.black)) {
            blackTerritory += region.points.length;
          } else {
            whiteTerritory += region.points.length;
          }
        }
      }
    }

    final double blackArea = blackStones + blackTerritory.toDouble();
    final double whiteArea = whiteStones + whiteTerritory + komi;
    return GoScore(
      blackStones: blackStones,
      whiteStones: whiteStones,
      blackTerritory: blackTerritory,
      whiteTerritory: whiteTerritory,
      komi: komi,
      blackArea: blackArea,
      whiteArea: whiteArea,
      blackCaptures: blackCaptures,
      whiteCaptures: whiteCaptures,
    );
  }

  GoScore scoreTerritory({double komi = 6.5}) {
    int blackStones = 0;
    int whiteStones = 0;
    int blackTerritory = 0;
    int whiteTerritory = 0;
    final Set<GoPoint> visited = <GoPoint>{};

    for (int y = 0; y < boardSize; y++) {
      for (int x = 0; x < boardSize; x++) {
        final GoStone? s = board[y][x];
        if (s == GoStone.black) {
          blackStones++;
          continue;
        }
        if (s == GoStone.white) {
          whiteStones++;
          continue;
        }
        final GoPoint p = GoPoint(x, y);
        if (visited.contains(p)) {
          continue;
        }
        final _Region region = _collectEmptyRegion(p, visited);
        if (region.borderColors.length == 1) {
          if (region.borderColors.contains(GoStone.black)) {
            blackTerritory += region.points.length;
          } else {
            whiteTerritory += region.points.length;
          }
        }
      }
    }

    final double blackScore = blackTerritory + blackCaptures.toDouble();
    final double whiteScore = whiteTerritory + whiteCaptures + komi;
    return GoScore(
      blackStones: blackStones,
      whiteStones: whiteStones,
      blackTerritory: blackTerritory,
      whiteTerritory: whiteTerritory,
      komi: komi,
      blackArea: blackScore,
      whiteArea: whiteScore,
      blackCaptures: blackCaptures,
      whiteCaptures: whiteCaptures,
    );
  }

  String boardHash(List<List<GoStone?>> src) {
    final StringBuffer sb = StringBuffer();
    for (int y = 0; y < boardSize; y++) {
      for (int x = 0; x < boardSize; x++) {
        final GoStone? s = src[y][x];
        if (s == null) {
          sb.write('.');
        } else {
          sb.write(s == GoStone.black ? 'B' : 'W');
        }
      }
      sb.write('|');
    }
    return sb.toString();
  }

  Iterable<GoPoint> legalMovesForCurrentPlayer() sync* {
    for (int y = 0; y < boardSize; y++) {
      for (int x = 0; x < boardSize; x++) {
        final GoPoint p = GoPoint(x, y);
        if (stoneAt(p) != null) {
          continue;
        }
        try {
          play(GoMove(player: toPlay, point: p));
          yield p;
        } catch (_) {
          // illegal
        }
      }
    }
  }

  Iterable<GoPoint> _neighbors(GoPoint p) sync* {
    yield GoPoint(p.x + 1, p.y);
    yield GoPoint(p.x - 1, p.y);
    yield GoPoint(p.x, p.y + 1);
    yield GoPoint(p.x, p.y - 1);
  }

  _Group _collectGroup(List<List<GoStone?>> src, GoPoint start) {
    final GoStone? color = src[start.y][start.x];
    if (color == null) {
      return _Group(const <GoPoint>{}, const <GoPoint>{});
    }

    final Queue<GoPoint> queue = Queue<GoPoint>()..add(start);
    final Set<GoPoint> stones = <GoPoint>{};
    final Set<GoPoint> liberties = <GoPoint>{};

    while (queue.isNotEmpty) {
      final GoPoint cur = queue.removeFirst();
      if (stones.contains(cur)) {
        continue;
      }
      stones.add(cur);
      for (final GoPoint n in _neighbors(cur)) {
        if (!inBounds(n)) {
          continue;
        }
        final GoStone? ns = src[n.y][n.x];
        if (ns == null) {
          liberties.add(n);
        } else if (ns == color && !stones.contains(n)) {
          queue.add(n);
        }
      }
    }
    return _Group(stones, liberties);
  }

  _Region _collectEmptyRegion(GoPoint start, Set<GoPoint> visited) {
    final Queue<GoPoint> queue = Queue<GoPoint>()..add(start);
    final Set<GoPoint> points = <GoPoint>{};
    final Set<GoStone> borderColors = <GoStone>{};
    while (queue.isNotEmpty) {
      final GoPoint cur = queue.removeFirst();
      if (visited.contains(cur)) {
        continue;
      }
      visited.add(cur);
      if (board[cur.y][cur.x] != null) {
        continue;
      }
      points.add(cur);
      for (final GoPoint n in _neighbors(cur)) {
        if (!inBounds(n)) {
          continue;
        }
        final GoStone? s = board[n.y][n.x];
        if (s == null) {
          if (!visited.contains(n)) {
            queue.add(n);
          }
        } else {
          borderColors.add(s);
        }
      }
    }
    return _Region(points, borderColors);
  }

  static List<List<GoStone?>> _copyBoard(List<List<GoStone?>> src) =>
      src.map((List<GoStone?> row) => List<GoStone?>.from(row)).toList();
}

class _Group {
  const _Group(this.stones, this.liberties);

  final Set<GoPoint> stones;
  final Set<GoPoint> liberties;
}

class _Region {
  const _Region(this.points, this.borderColors);

  final Set<GoPoint> points;
  final Set<GoStone> borderColors;
}

class GoScore {
  const GoScore({
    required this.blackStones,
    required this.whiteStones,
    required this.blackTerritory,
    required this.whiteTerritory,
    required this.komi,
    required this.blackArea,
    required this.whiteArea,
    this.blackCaptures = 0,
    this.whiteCaptures = 0,
  });

  final int blackStones;
  final int whiteStones;
  final int blackTerritory;
  final int whiteTerritory;
  final double komi;
  final double blackArea;
  final double whiteArea;
  final int blackCaptures;
  final int whiteCaptures;

  double get leadForBlack => blackArea - whiteArea;

  String winnerText() {
    final double lead = leadForBlack;
    if (lead > 0) {
      return 'Black wins by ${lead.toStringAsFixed(1)}';
    }
    if (lead < 0) {
      return 'White wins by ${(-lead).toStringAsFixed(1)}';
    }
    return 'Draw';
  }
}
