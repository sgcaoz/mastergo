import 'package:flutter/material.dart';

class WinrateChart extends StatelessWidget {
  const WinrateChart({
    super.key,
    required this.winrates,
    required this.maxTurn,
    this.highlightTurn,
    this.onTurnSelected,
  });

  final Map<int, double> winrates;
  final int maxTurn;
  final int? highlightTurn;
  /// 拖动竖线时回调，用于快速跳转手数
  final ValueChanged<int>? onTurnSelected;

  @override
  Widget build(BuildContext context) {
    final chart = CustomPaint(
      painter: _WinratePainter(
        winrates: winrates,
        maxTurn: maxTurn,
        lineColor: Theme.of(context).colorScheme.primary,
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
}

class _WinratePainter extends CustomPainter {
  const _WinratePainter({
    required this.winrates,
    required this.maxTurn,
    required this.lineColor,
    this.highlightTurn,
  });

  final Map<int, double> winrates;
  final int maxTurn;
  final Color lineColor;
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

    if (winrates.length < 2 || maxTurn <= 0) {
      return;
    }
    final List<int> turns = winrates.keys.toList()..sort();
    final Path path = Path();
    for (int i = 0; i < turns.length; i++) {
      final int t = turns[i];
      final double wr = winrates[t]!.clamp(0.0, 1.0);
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
        ..color = lineColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(covariant _WinratePainter oldDelegate) {
    return oldDelegate.winrates != winrates ||
        oldDelegate.maxTurn != maxTurn ||
        oldDelegate.highlightTurn != highlightTurn;
  }
}
