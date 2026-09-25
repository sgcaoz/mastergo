import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mastergo/features/common/go_board_widget.dart';
import 'package:mastergo/main.dart' as app;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('iOS product walkthrough', (WidgetTester tester) async {
    app.main();
    await _pumpFor(tester, const Duration(seconds: 2));

    await _waitForAny(tester, <String>['围棋大师', 'MasterGo']);
    await _waitForAny(tester, <String>['打谱', 'Review']);
    expect(_any(<String>['AI 对弈', 'AI Play']), findsWidgets);
    expect(_any(<String>['拍照识谱', 'Scan Board']), findsWidgets);
    expect(tester.takeException(), isNull);

    await tester.tap(_any(<String>['名局', 'Master Games']));
    await tester.pump();
    await _waitUntil(
      tester,
      () =>
          _any(<String>[
            '暂无名局',
            'No master games',
            '加载名局失败',
            'Failed to load master games',
          ]).evaluate().isEmpty &&
          find.byType(ListTile).evaluate().isNotEmpty,
      const Duration(seconds: 30),
      '名局列表没有出来',
    );
    expect(tester.takeException(), isNull);

    await tester.tap(_any(<String>['本机对局', 'Local Games']));
    await tester.pump();
    await _pumpFor(tester, const Duration(seconds: 2));
    expect(_any(<String>['棋谱加载失败', 'Failed to load records']), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.tap(_any(<String>['AI 对弈', 'AI Play']));
    await tester.pump();
    await _waitForAny(tester, <String>[
      '开始对弈',
      '继续对局',
      'Start Game',
      'Continue',
    ]);
    expect(_any(<String>['路数', 'Board Size']), findsWidgets);
    expect(tester.takeException(), isNull);

    final bool continuing = _any(<String>[
      '继续对局',
      'Continue',
    ]).evaluate().isNotEmpty;
    await tester.tap(
      continuing
          ? _any(<String>['继续对局', 'Continue'])
          : _any(<String>['开始对弈', 'Start Game']),
    );
    await tester.pump();
    await _waitForAny(tester, <String>[
      '轮到你落子',
      '请落子',
      'AI先行',
      '启动引擎中',
      '引擎启动失败',
      'Your move',
      'Engine failed to start',
    ], timeout: const Duration(seconds: 20));
    expect(find.byType(GoBoardWidget), findsWidgets);

    final Finder engineFailed = _any(<String>[
      '引擎启动失败',
      'Engine failed to start',
      'AI分析失败',
      'AI analysis failed',
    ]);
    final Finder ready = _any(<String>[
      '轮到你',
      '请落子',
      'AI先行',
      'AI落子完成',
      'Your move',
      'AI moved',
    ]);
    await _waitUntil(
      tester,
      () => engineFailed.evaluate().isNotEmpty || ready.evaluate().isNotEmpty,
      const Duration(seconds: 90),
      '引擎既没有就绪，也没有给出失败\n${_visibleText(tester)}',
    );
    expect(
      engineFailed,
      findsNothing,
      reason: 'AI 引擎启动失败\n${_visibleText(tester)}',
    );
    expect(tester.takeException(), isNull);

    final Offset boardCenter = tester.getCenter(find.byType(GoBoardWidget));
    await tester.tapAt(boardCenter);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tapAt(boardCenter);
    await tester.pump();
    await _waitForAny(tester, <String>[
      '你已落子',
      'AI思考中',
      '非法落子',
      'AI moved',
      'AI is thinking',
    ], timeout: const Duration(seconds: 20));

    await tester.tap(find.byType(BackButton));
    await tester.pump();
    await _waitForAny(tester, <String>[
      '开始对弈',
      '继续对局',
      '重开',
      'Start Game',
      'Continue',
      'New game',
    ]);

    await tester.tap(_any(<String>['打谱', 'Review']));
    await tester.pump();
    await tester.tap(_any(<String>['本机对局', 'Local Games']));
    await tester.pump();
    await _waitForAny(tester, <String>[
      '暂无棋谱',
      '未下完',
      '恢复对局',
      'No records',
      'Unfinished',
      'Resume',
    ], timeout: const Duration(seconds: 15));

    await tester.tap(_any(<String>['拍照识谱', 'Scan Board']));
    await tester.pump();
    await _waitForAny(tester, <String>['拍照', 'Camera']);
    expect(_any(<String>['相册', 'Gallery']), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}

String _visibleText(WidgetTester tester) {
  final StringBuffer buffer = StringBuffer();
  for (final Element element in find.byType(Text).evaluate()) {
    final Text text = element.widget as Text;
    final String? value = text.data ?? text.textSpan?.toPlainText();
    if (value != null && value.trim().isNotEmpty) {
      buffer.writeln(value);
    }
  }
  return buffer.toString();
}

Finder _any(List<String> labels) {
  return find.byWidgetPredicate((Widget widget) {
    if (widget is Text) {
      final Object? data = widget.data;
      if (data is String && labels.any(data.contains)) {
        return true;
      }
    }
    return false;
  });
}

Future<void> _waitForAny(
  WidgetTester tester,
  List<String> labels, {
  Duration timeout = const Duration(seconds: 15),
}) {
  return _waitUntil(
    tester,
    () => _any(labels).evaluate().isNotEmpty,
    timeout,
    '没找到: ${labels.join(' / ')}',
  );
}

Future<void> _waitUntil(
  WidgetTester tester,
  bool Function() ready,
  Duration timeout,
  String reason,
) async {
  final DateTime end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 200));
    if (ready()) {
      return;
    }
  }
  fail(reason);
}

Future<void> _pumpFor(WidgetTester tester, Duration duration) async {
  final DateTime end = DateTime.now().add(duration);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}
