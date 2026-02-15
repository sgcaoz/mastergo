import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:mastergo/domain/go/go_types.dart';

class GoBoardWidget extends StatelessWidget {
  const GoBoardWidget({
    super.key,
    required this.boardSize,
    required this.board,
    this.onTapPoint,
    this.padding = 16,
    this.lastMovePoint,
    this.tentativePoint,
    this.tentativeStone,
  });

  final int boardSize;
  final List<List<GoStone?>> board;
  final ValueChanged<GoPoint>? onTapPoint;
  final double padding;
  final GoPoint? lastMovePoint;
  final GoPoint? tentativePoint;
  final GoStone? tentativeStone;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double size = math.min(
          constraints.maxWidth,
          constraints.maxHeight,
        );
        return Center(
          child: SizedBox(
            width: size,
            height: size,
            child: GestureDetector(
              onTapUp: onTapPoint == null
                  ? null
                  : (TapUpDetails details) {
                      final GoPoint? point = _toPoint(
                        details.localPosition,
                        size,
                      );
                      if (point != null) {
                        onTapPoint!(point);
                      }
                    },
              child: CustomPaint(
                painter: _GoBoardPainter(
                  boardSize: boardSize,
                  board: board,
                  padding: padding,
                  lastMovePoint: lastMovePoint,
                  tentativePoint: tentativePoint,
                  tentativeStone: tentativeStone,
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  GoPoint? _toPoint(Offset offset, double boardPixelSize) {
    final double gridSize = boardPixelSize - padding * 2;
    if (gridSize <= 0 || boardSize <= 1) {
      return null;
    }
    final double spacing = gridSize / (boardSize - 1);
    final int x = ((offset.dx - padding) / spacing).round();
    final int y = ((offset.dy - padding) / spacing).round();
    if (x < 0 || x >= boardSize || y < 0 || y >= boardSize) {
      return null;
    }
    return GoPoint(x, y);
  }
}

class _GoBoardPainter extends CustomPainter {
  _GoBoardPainter({
    required this.boardSize,
    required this.board,
    required this.padding,
    required this.lastMovePoint,
    required this.tentativePoint,
    required this.tentativeStone,
  });

  final int boardSize;
  final List<List<GoStone?>> board;
  final double padding;
  final GoPoint? lastMovePoint;
  final GoPoint? tentativePoint;
  final GoStone? tentativeStone;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint bgPaint = Paint()..color = const Color(0xFFDEB877);
    canvas.drawRect(Offset.zero & size, bgPaint);

    if (boardSize <= 1) {
      return;
    }
    final double gridSize = size.width - padding * 2;
    final double spacing = gridSize / (boardSize - 1);
    final Paint linePaint = Paint()
      ..color = const Color(0xFF5B3A29)
      ..strokeWidth = 1;

    for (int i = 0; i < boardSize; i++) {
      final double p = padding + i * spacing;
      canvas.drawLine(
        Offset(padding, p),
        Offset(size.width - padding, p),
        linePaint,
      );
      canvas.drawLine(
        Offset(p, padding),
        Offset(p, size.height - padding),
        linePaint,
      );
    }

    final Paint starPaint = Paint()..color = const Color(0xFF5B3A29);
    for (final GoPoint p in _starPoints()) {
      final Offset c = Offset(padding + p.x * spacing, padding + p.y * spacing);
      canvas.drawCircle(c, spacing * 0.09, starPaint);
    }

    final double stoneRadius = spacing * 0.42;
    for (int y = 0; y < boardSize; y++) {
      for (int x = 0; x < boardSize; x++) {
        final GoStone? s = board[y][x];
        if (s == null) {
          continue;
        }
        final Offset c = Offset(padding + x * spacing, padding + y * spacing);
        final Paint stonePaint = Paint()
          ..color = s == GoStone.black ? Colors.black : Colors.white;
        canvas.drawCircle(c, stoneRadius, stonePaint);
        if (s == GoStone.white) {
          canvas.drawCircle(
            c,
            stoneRadius,
            Paint()
              ..color = Colors.black26
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1,
          );
        }
      }
    }

    if (tentativePoint != null && tentativeStone != null) {
      final Offset c = Offset(
        padding + tentativePoint!.x * spacing,
        padding + tentativePoint!.y * spacing,
      );
      _drawDashedLine(
        canvas,
        Offset(padding, c.dy),
        Offset(size.width - padding, c.dy),
        const Color(0xAA1F4E79),
      );
      _drawDashedLine(
        canvas,
        Offset(c.dx, padding),
        Offset(c.dx, size.height - padding),
        const Color(0xAA1F4E79),
      );
      final Paint ghostPaint = Paint()
        ..color = tentativeStone == GoStone.black
            ? Colors.black.withValues(alpha: 0.45)
            : Colors.white.withValues(alpha: 0.85);
      canvas.drawCircle(c, stoneRadius, ghostPaint);
      canvas.drawCircle(
        c,
        stoneRadius,
        Paint()
          ..color = Colors.black26
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    }

    if (lastMovePoint != null) {
      final Offset c = Offset(
        padding + lastMovePoint!.x * spacing,
        padding + lastMovePoint!.y * spacing,
      );
      canvas.drawCircle(
        c,
        spacing * 0.16,
        Paint()..color = const Color(0xFFE53935),
      );
      canvas.drawCircle(
        c,
        spacing * 0.18,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2,
      );
    }
  }

  List<GoPoint> _starPoints() {
    if (boardSize == 19) {
      return _crossPoints(const <int>[3, 9, 15]);
    }
    if (boardSize == 13) {
      return _crossPoints(const <int>[3, 6, 9]);
    }
    if (boardSize == 9) {
      return _crossPoints(const <int>[2, 4, 6]);
    }
    if (boardSize.isOdd && boardSize >= 7) {
      final int mid = boardSize ~/ 2;
      return <GoPoint>[GoPoint(mid, mid)];
    }
    return const <GoPoint>[];
  }

  List<GoPoint> _crossPoints(List<int> indices) {
    final List<GoPoint> points = <GoPoint>[];
    for (final int x in indices) {
      for (final int y in indices) {
        points.add(GoPoint(x, y));
      }
    }
    return points;
  }

  void _drawDashedLine(
    Canvas canvas,
    Offset start,
    Offset end,
    Color color,
  ) {
    final Paint paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    const double dash = 6;
    const double gap = 4;
    final double total = (end - start).distance;
    if (total <= 0) {
      return;
    }
    final Offset dir = (end - start) / total;
    double t = 0;
    while (t < total) {
      final double next = math.min(t + dash, total);
      final Offset a = start + dir * t;
      final Offset b = start + dir * next;
      canvas.drawLine(a, b, paint);
      t = next + gap;
    }
  }

  @override
  bool shouldRepaint(covariant _GoBoardPainter oldDelegate) {
    return oldDelegate.board != board ||
        oldDelegate.boardSize != boardSize ||
        oldDelegate.lastMovePoint != lastMovePoint ||
        oldDelegate.tentativePoint != tentativePoint ||
        oldDelegate.tentativeStone != tentativeStone;
  }
}
