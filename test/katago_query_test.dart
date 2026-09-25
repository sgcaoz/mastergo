import 'package:flutter_test/flutter_test.dart';
import 'package:mastergo/infra/engine/katago/katago_adapter.dart';

void main() {
  test('handicap opening asks white to move when there are no moves yet', () {
    expect(
      katagoInitialPlayer(blackToMove: false, moves: const <String>[]),
      'W',
    );
    expect(
      katagoInitialPlayer(blackToMove: true, moves: const <String>[]),
      'B',
    );
  });

  test('later queries follow the first move color', () {
    expect(
      katagoInitialPlayer(blackToMove: true, moves: const <String>['W:D4']),
      'W',
    );
  });
}
