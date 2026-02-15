enum StoneColor { black, white }

class BoardCoordinate {
  const BoardCoordinate({required this.x, required this.y});

  final int x;
  final int y;
}

class HandicapStone {
  const HandicapStone({required this.position, this.color = StoneColor.black});

  final BoardCoordinate position;
  final StoneColor color;
}

class GameSetup {
  const GameSetup({
    required this.boardSize,
    required this.startingPlayer,
    this.handicapStones = const <HandicapStone>[],
  });

  final int boardSize;
  final StoneColor startingPlayer;
  final List<HandicapStone> handicapStones;
}
