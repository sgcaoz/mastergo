import 'dart:async';

import 'package:mastergo/domain/go/go_types.dart';

/// 落子双击确认 + 3 秒无操作自动确认的通用逻辑。
/// 用于：AI 对弈落子、打谱试下、复盘试下。
class PendingConfirmTimer {
  PendingConfirmTimer({this.autoConfirmDelay = const Duration(seconds: 3)});

  final Duration autoConfirmDelay;
  Timer? _timer;

  /// 处理一次点击：若与当前待确认点相同则立即确认；否则设为待确认并启动自动确认计时。
  /// [currentPending] 当前待确认点，无则为 null。
  /// [setPending] 将 [point] 设为待确认点（仅更新 UI 状态）。
  /// [confirmWithPoint] 确认落子 [point]（调用方内部需判断当前待确认点是否仍为该点再执行落子）。
  void handleTap(
    GoPoint point,
    GoPoint? currentPending,
    void Function(GoPoint point) setPending,
    void Function(GoPoint point) confirmWithPoint,
  ) {
    _timer?.cancel();
    _timer = null;
    if (currentPending == point) {
      confirmWithPoint(point);
      return;
    }
    setPending(point);
    final pointToConfirm = point;
    _timer = Timer(autoConfirmDelay, () {
      _timer = null;
      confirmWithPoint(pointToConfirm);
    });
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
  }
}
