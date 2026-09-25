import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mastergo/app/app.dart';
import 'package:mastergo/features/photo_judge/photo_judge_page.dart';
import 'package:mastergo/infra/engine/katago/katago_adapter.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('app loads home tabs', (WidgetTester tester) async {
    await tester.pumpWidget(MasterGoApp(engineAdapter: MockKatagoAdapter()));
    await tester.pump();
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byIcon(Icons.info_outline), findsNothing);
    expect(find.byIcon(Icons.extension_outlined), findsNothing);
    expect(find.byIcon(Icons.photo_camera_outlined), findsOneWidget);
  });

  testWidgets('photo tab controls fit a narrow phone', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(MasterGoApp(engineAdapter: MockKatagoAdapter()));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.photo_camera_outlined));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(tester.takeException(), isNull);
    expect(find.byType(PhotoJudgePage), findsOneWidget);
    expect(find.byType(SegmentedButton<int>), findsWidgets);
    expect(find.byType(DropdownButtonFormField<String>), findsWidgets);
  });

}
