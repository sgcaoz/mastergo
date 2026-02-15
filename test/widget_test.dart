// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter_test/flutter_test.dart';
import 'package:mastergo/app/app.dart';

void main() {
  testWidgets('shows app shell tabs', (WidgetTester tester) async {
    await tester.pumpWidget(const MasterGoApp());
    await tester.pumpAndSettle();

    expect(find.text('打谱'), findsWidgets);
    expect(find.text('AI 对弈'), findsWidgets);
    expect(find.text('名局'), findsWidgets);
  });
}
