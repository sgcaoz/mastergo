import 'package:mastergo/domain/entities/game_setup.dart';

class MoveNode {
  const MoveNode({
    required this.turn,
    required this.player,
    required this.move,
    this.comment,
    this.winrate,
    this.scoreLead,
    this.pv = const <String>[],
  });

  final int turn;
  final StoneColor player;
  final String move;
  final String? comment;
  final double? winrate;
  final double? scoreLead;
  final List<String> pv;
}
