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
    this.highlightTurnWinrate,
    this.onTurnSelected,
  });

  /// 最大手数（X 轴范围 0..maxTurn）
  final int maxTurn;
  /// 单条曲线（与 [winrateSeries] 二选一，兼容旧用法）
  final Map<int, double>? winrates;
  /// 多条曲线，每条不同颜色（主战线 + 变化图分支）；非空时优先于 [winrates]
  final List<WinrateSeries>? winrateSeries;
  final int? highlightTurn;
  /// 当前手黑方胜率（0..1），用于在竖线侧面显示，打谱时更清楚
  final double? highlightTurnWinrate;
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
        highlightTurnWinrate: highlightTurnWinrate,
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
            final turn = (w > 0 ? (dx / w * maxTurn).round() : 0).clamp(0, maxTurn);
            onTurnSelected!(turn);
          },
          onTapDown: (TapDownDetails d) {
            final dx = d.localPosition.dx.clamp(0.0, w);
            final turn = (w > 0 ? (dx / w * maxTurn).round() : 0).clamp(0, maxTurn);
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
    this.highlightTurnWinrate,
  });

  final List<WinrateSeries> series;
  final int maxTurn;
  final int? highlightTurn;
  final double? highlightTurnWinrate;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    final double chartWidth = size.width;
    final double chartHeight = size.height;
    final Paint axisPaint = Paint()
      ..color = Colors.black26
      ..strokeWidth = 1;

    // X 轴、Y 轴（保持原位置，不右移）
    canvas.drawLine(
      Offset(0, chartHeight),
      Offset(chartWidth, chartHeight),
      axisPaint,
    );
    canvas.drawLine(const Offset(0, 0), Offset(0, chartHeight), axisPaint);

    // 胜率 50% 画条虚线
    final double y50 = chartHeight * 0.5;
    const double dashLength = 6;
    const double gapLength = 4;
    final Paint dashPaint = Paint()
      ..color = Colors.black38
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    for (double x = 0; x < chartWidth; x += dashLength + gapLength) {
      final double xEnd = (x + dashLength).clamp(0, chartWidth);
      if (xEnd > x) {
        canvas.drawLine(Offset(x, y50), Offset(xEnd, y50), dashPaint);
      }
    }

    // Y 轴百分比标注叠在左侧（100% 50% 0%），不改变图表区域
    const List<double> yPcts = <double>[1.0, 0.5, 0.0];
    const List<String> yLabels = <String>['100%', '50%', '0%'];
    final TextPainter labelPainter = TextPainter(
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.right,
    );
    for (int i = 0; i < yPcts.length; i++) {
      final double y = chartHeight * (1 - yPcts[i]);
      if (y < 0 || y > chartHeight) continue;
      labelPainter.text = TextSpan(
        text: yLabels[i],
        style: const TextStyle(
          color: Colors.black54,
          fontSize: 10,
        ),
      );
      labelPainter.layout();
      final double labelY = (y - labelPainter.height / 2).clamp(0, chartHeight - labelPainter.height);
      labelPainter.paint(
        canvas,
        Offset(2, labelY.clamp(0, size.height - labelPainter.height)),
      );
    }

    final int safeHighlightTurn = (highlightTurn ?? 0).clamp(0, maxTurn);
    if (maxTurn > 0) {
      final double x = chartWidth * (safeHighlightTurn / maxTurn);
      final double lineX = x.clamp(0, size.width - 1);
      canvas.drawLine(
        Offset(lineX, 0),
        Offset(lineX, chartHeight),
        Paint()
          ..color = Colors.black54
          ..strokeWidth = 1
          ..style = PaintingStyle.stroke,
      );

      // 竖线侧面显示当前手胜率（打谱更清楚），避免越界
      if (highlightTurnWinrate != null) {
        final double wr = highlightTurnWinrate!.clamp(0.0, 1.0);
        final String pct = '${(wr * 100).toStringAsFixed(1)}%';
        final TextPainter tp = TextPainter(
          text: TextSpan(text: pct, style: const TextStyle(color: Colors.black87, fontSize: 11)),
          textDirection: TextDirection.ltr,
        );
        tp.layout();
        final double tx = lineX + 4;
        final double textRight = tx + tp.width;
        final double yPos = chartHeight * (1 - wr);
        final double ty = (yPos - tp.height / 2).clamp(0, chartHeight - tp.height);
        double drawX = tx;
        if (textRight > size.width - 2) {
          drawX = (lineX - 4 - tp.width).clamp(2, size.width - tp.width - 2);
        } else if (tx < 2) {
          drawX = 2;
        }
        tp.paint(canvas, Offset(drawX.clamp(0, size.width - tp.width), ty.clamp(0, size.height - tp.height)));
      }
    }

    if (series.isEmpty || maxTurn <= 0) return;

    for (final WinrateSeries s in series) {
      if (s.winrates.length < 2) continue;
      final List<int> turns = s.winrates.keys
          .where((int t) => t <= maxTurn)
          .toList()
        ..sort();
      if (turns.length < 2) continue;
      final Path path = Path();
      for (int i = 0; i < turns.length; i++) {
        final int t = turns[i];
        final double wr = s.winrates[t]!.clamp(0.0, 1.0);
        final double x = chartWidth * (t / maxTurn);
        final double y = chartHeight * (1 - wr);
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
        oldDelegate.highlightTurn != highlightTurn ||
        oldDelegate.highlightTurnWinrate != highlightTurnWinrate;
  }
}
