import 'package:flutter/material.dart';

class WinrateChart extends StatelessWidget {
  const WinrateChart({
    super.key,
    required this.winrates,
    required this.maxTurn,
  });

  final Map<int, double> winrates;
  final int maxTurn;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _WinratePainter(
        winrates: winrates,
        maxTurn: maxTurn,
        lineColor: Theme.of(context).colorScheme.primary,
      ),
      child: Container(
        decoration: BoxDecoration(border: Border.all(color: Colors.black12)),
      ),
    );
  }
}

class _WinratePainter extends CustomPainter {
  const _WinratePainter({
    required this.winrates,
    required this.maxTurn,
    required this.lineColor,
  });

  final Map<int, double> winrates;
  final int maxTurn;
  final Color lineColor;

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
    return oldDelegate.winrates != winrates || oldDelegate.maxTurn != maxTurn;
  }
}
