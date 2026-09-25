import 'package:flutter/widgets.dart';
import 'package:mastergo/infra/engine/katago/katago_adapter.dart';

/// App-scoped KataGo adapter. Feature pages must read this instead of
/// constructing [PlatformKatagoAdapter] so they cannot shut down a shared engine.
class KatagoEngineScope extends InheritedWidget {
  const KatagoEngineScope({
    super.key,
    required this.adapter,
    required super.child,
  });

  final KatagoAdapter adapter;

  static KatagoAdapter of(BuildContext context) {
    final KatagoEngineScope? scope = context
        .dependOnInheritedWidgetOfExactType<KatagoEngineScope>();
    assert(
      scope != null,
      'KatagoEngineScope not found. Wrap the app with KatagoEngineScope.',
    );
    return scope!.adapter;
  }

  static KatagoAdapter? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<KatagoEngineScope>()
        ?.adapter;
  }

  @override
  bool updateShouldNotify(KatagoEngineScope oldWidget) =>
      oldWidget.adapter != adapter;
}
