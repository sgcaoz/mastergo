enum GoStone { black, white }

extension GoStoneExt on GoStone {
  GoStone opposite() => this == GoStone.black ? GoStone.white : GoStone.black;
  String get sgfColor => this == GoStone.black ? 'B' : 'W';
}

class GoPoint {
  const GoPoint(this.x, this.y);

  final int x;
  final int y;

  @override
  bool operator ==(Object other) =>
      other is GoPoint && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);

  /// GTP like `D4`; `I` is skipped. Pass tokens return null.
  static GoPoint? tryParseGtp(String gtp, int boardSize) {
    final String token = gtp.trim();
    if (token.isEmpty || token.toLowerCase() == 'pass') {
      return null;
    }
    const String columns = 'ABCDEFGHJKLMNOPQRSTUVWXYZ';
    if (token.length < 2) {
      return null;
    }
    final int x = columns.indexOf(token.substring(0, 1).toUpperCase());
    final int row = int.tryParse(token.substring(1)) ?? 0;
    if (x < 0 || row <= 0) {
      return null;
    }
    final int y = boardSize - row;
    if (y < 0 || y >= boardSize) {
      return null;
    }
    return GoPoint(x, y);
  }
}

class GoMove {
  const GoMove({required this.player, this.point, this.isPass = false});

  final GoStone player;
  final GoPoint? point;
  final bool isPass;

  String toGtp(int boardSize) {
    if (isPass || point == null) {
      return 'pass';
    }
    const String columns = 'ABCDEFGHJKLMNOPQRSTUVWXYZ';
    final String col = columns[point!.x];
    final int row = boardSize - point!.y;
    return '$col$row';
  }

  String toProtocolToken(int boardSize) =>
      '${player.sgfColor}:${toGtp(boardSize)}';
}
