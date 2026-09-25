import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mastergo/domain/go/go_types.dart';
import 'package:mastergo/features/common/go_board_widget.dart';
import 'package:mastergo/features/record_review/record_review_page.dart';

void main() {
  test('download names cannot leave the download folder', () {
    expect(sgfDownloadFileName('../../secret.sgf'), 'secret.sgf');
    expect(sgfDownloadFileName('notes'), 'notes.sgf');
    expect(sgfDownloadFileName('..'), 'imported.sgf');
  });

  test('go coordinates skip I and put 1 at the bottom', () {
    expect(goFileLabel(0), 'A');
    expect(goFileLabel(8), 'J');
    expect(goFileLabel(18), 'T');
    expect(goRankNumber(0, 19), 19);
    expect(goRankNumber(18, 19), 1);
  });

  testWidgets('board paints on a felt stage', (WidgetTester tester) async {
    final List<List<GoStone?>> board = List<List<GoStone?>>.generate(
      9,
      (_) => List<GoStone?>.filled(9, null),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            height: 320,
            child: GoBoardStage(
              child: GoBoardWidget(boardSize: 9, board: board),
            ),
          ),
        ),
      ),
    );
    expect(find.byType(GoBoardWidget), findsOneWidget);
    expect(find.byType(GoBoardStage), findsOneWidget);
  });
}
