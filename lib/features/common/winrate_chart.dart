import 'package:flutter/material.dart';

/// 单条胜率曲线：手数 -> 黑方胜率，及绘制颜色。
class WinrateSeries {
  const WinrateSeries({
    required this.winrates,
    required this.color,
    this.label,
  });

  final Map<int, double> winrates;
  final Color color;
  /// 可选标签（如「主战线」「变化1」），用于图例等。
  final String? label;
}

class WinrateChart extends StatelessWidget {
  const WinrateChart({
    super.key,
    required this.maxTurn,
    this.winrates,
    this.winrateSeries,
    this.highlightTurn,
    this.onTurnSelected,
  });

  /// 最大手数（X 轴范围 0..maxTurn）
  final int maxTurn;
  /// 单条曲线（与 [winrateSeries] 二选一，兼容旧用法）
  final Map<int, double>? winrates;
  /// 多条曲线，每条不同颜色（主战线 + 变化图分支）；非空时优先于 [winrates]
  final List<WinrateSeries>? winrateSeries;
  final int? highlightTurn;
  /// 拖动竖线时回调，用于快速跳转手数
  final ValueChanged<int>? onTurnSelected;

  @override
  Widget build(BuildContext context) {
    final List<WinrateSeries> series = _effectiveSeries(context);
    final chart = CustomPaint(
      painter: _WinratePainter(
        series: series,
        maxTurn: maxTurn,
        highlightTurn: highlightTurn,
      ),
      child: Container(
        decoration: BoxDecoration(border: Border.all(color: Colors.black12)),
      ),
    );
    if (onTurnSelected == null || maxTurn <= 0) {
      return chart;
    }
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final w = constraints.maxWidth;
        return GestureDetector(
          onHorizontalDragUpdate: (DragUpdateDetails d) {
            final dx = d.localPosition.dx.clamp(0.0, w);
            final turn = (dx / w * maxTurn).round().clamp(0, maxTurn);
            onTurnSelected!(turn);
          },
          onTapDown: (TapDownDetails d) {
            final dx = d.localPosition.dx.clamp(0.0, w);
            final turn = (dx / w * maxTurn).round().clamp(0, maxTurn);
            onTurnSelected!(turn);
          },
          child: chart,
        );
      },
    );
  }

  List<WinrateSeries> _effectiveSeries(BuildContext context) {
    if (winrateSeries != null && winrateSeries!.isNotEmpty) {
      return winrateSeries!;
    }
    if (winrates != null && winrates!.isNotEmpty) {
      return <WinrateSeries>[
        WinrateSeries(
          winrates: winrates!,
          color: Theme.of(context).colorScheme.primary,
        ),
      ];
    }
    return <WinrateSeries>[];
  }
}

class _WinratePainter extends CustomPainter {
  const _WinratePainter({
    required this.series,
    required this.maxTurn,
    this.highlightTurn,
  });

  final List<WinrateSeries> series;
  final int maxTurn;
  final int? highlightTurn;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint axisPaint = Paint()
      ..color = Colors.black26
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(0, size.height),
      Offset(size.width, size.height),
      axisPaint,
    );
    canvas.drawLine(const Offset(0, 0), Offset(0, size.height), axisPaint);

    if (highlightTurn != null && maxTurn > 0) {
      final double x = size.width * (highlightTurn! / maxTurn);
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, size.height),
        Paint()
          ..color = Colors.black54
          ..strokeWidth = 1
          ..style = PaintingStyle.stroke,
      );
    }

    if (series.isEmpty || maxTurn <= 0) {
      return;
    }
    for (final WinrateSeries s in series) {
      if (s.winrates.length < 2) {
        continue;
      }
      final List<int> turns = s.winrates.keys
          .where((int t) => t <= maxTurn)
          .toList()
        ..sort();
      if (turns.length < 2) continue;
      final Path path = Path();
      for (int i = 0; i < turns.length; i++) {
        final int t = turns[i];
        final double wr = s.winrates[t]!.clamp(0.0, 1.0);
        final double x = size.width * (t / maxTurn);
        final double y = size.height * (1 - wr);
        if (i == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = s.color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _WinratePainter oldDelegate) {
    if (oldDelegate.series.length != series.length) return true;
    for (int i = 0; i < series.length; i++) {
      if (oldDelegate.series[i].winrates != series[i].winrates ||
          oldDelegate.series[i].color != series[i].color) {
        return true;
      }
    }
    return oldDelegate.maxTurn != maxTurn ||
        oldDelegate.highlightTurn != highlightTurn;
  }
}
