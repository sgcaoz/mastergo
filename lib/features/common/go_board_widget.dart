import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:mastergo/domain/go/go_types.dart';

/// 默认棋盘背景色（木色）；可通过 [GoBoardWidget.boardBackgroundColor] 覆盖。
const Color kDefaultBoardBackgroundColor = Color(0xFFDEB877);

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
    this.hintPoints = const <GoPoint>[],
    this.ownership,
    this.boardBackgroundColor,
  });

  final int boardSize;
  final List<List<GoStone?>> board;
  final ValueChanged<GoPoint>? onTapPoint;
  final double padding;
  final GoPoint? lastMovePoint;
  final GoPoint? tentativePoint;
  final GoStone? tentativeStone;
  final List<GoPoint> hintPoints;
  /// Per-point ownership from KataGo: row-major, -1 = black, 1 = white. Length boardSize². Drawn as tint overlay.
  final List<double>? ownership;
  final Color? boardBackgroundColor;

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
                  hintPoints: hintPoints,
                  ownership: ownership,
                  boardBackgroundColor: boardBackgroundColor ?? kDefaultBoardBackgroundColor,
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
    required this.hintPoints,
    required this.boardBackgroundColor,
    this.ownership,
  });

  final int boardSize;
  final List<List<GoStone?>> board;
  final double padding;
  final GoPoint? lastMovePoint;
  final GoPoint? tentativePoint;
  final GoStone? tentativeStone;
  final List<GoPoint> hintPoints;
  final Color boardBackgroundColor;
  final List<double>? ownership;

  @override
  void paint(Canvas canvas, Size size) {
    // 棋盘立体感：木纹底色 + 线性渐变（左上略亮、右下略暗）+ 内凹边框
    final Rect boardRect = Offset.zero & size;
    final LinearGradient boardGradient = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: <Color>[
        _lighten(boardBackgroundColor, 0.08),
        boardBackgroundColor,
        _darken(boardBackgroundColor, 0.06),
      ],
      stops: const <double>[0.0, 0.5, 1.0],
    );
    canvas.drawRect(boardRect, Paint()..shader = boardGradient.createShader(boardRect));
    final Paint framePaint = Paint()
      ..color = _darken(boardBackgroundColor, 0.2)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawRect(boardRect.deflate(1), framePaint);

    if (boardSize <= 1) {
      return;
    }
    final double gridSize = size.width - padding * 2;
    final double spacing = gridSize / (boardSize - 1);

    // 四种势力色 + 不明（黄）：|v|<=0.2 不明，否则 非常黑/浅黑/非常白/浅白
    if (ownership != null && ownership!.length >= boardSize * boardSize) {
      const Color veryBlack = Color(0xF0181818);   // 非常贴近黑
      const Color lightBlack = Color(0xF0606060); // 浅色贴近黑
      const Color lightWhite = Color(0xF0C8C8C8); // 浅色贴近白
      const Color veryWhite = Color(0xF0F0F0F0);  // 非常接近白
      const Color uncertain = Color(0xF0E8C840);  // 不明：黄色
      const double uncertainThreshold = 0.2;

      for (int y = 0; y < boardSize; y++) {
        for (int x = 0; x < boardSize; x++) {
          final int idx = y * boardSize + x;
          final double v = ownership![idx].clamp(-1.0, 1.0);
          final Color color;
          if (v.abs() <= uncertainThreshold) {
            color = uncertain;
          } else if (v > 0.5) {
            color = veryBlack;
          } else if (v > uncertainThreshold) {
            color = lightBlack;
          } else if (v < -0.5) {
            color = veryWhite;
          } else {
            color = lightWhite;
          }
          final double left = x == 0 ? 0 : padding + (x - 0.5) * spacing;
          final double top = y == 0 ? 0 : padding + (y - 0.5) * spacing;
          final double right = x == boardSize - 1 ? size.width : padding + (x + 0.5) * spacing;
          final double bottom = y == boardSize - 1 ? size.height : padding + (y + 0.5) * spacing;
          final Paint paint = Paint()..color = color;
          canvas.drawRect(Rect.fromLTRB(left, top, right, bottom), paint);
        }
      }
    }

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
        _drawStone(canvas, c, stoneRadius, s);
      }
    }

    if (tentativePoint != null && tentativeStone != null) {
      final Offset c = Offset(
        padding + tentativePoint!.x * spacing,
        padding + tentativePoint!.y * spacing,
      );
      _drawDashedLine(
        canvas,
        Offset(0, c.dy),
        Offset(size.width, c.dy),
        const Color(0xCC0D47A1),
      );
      _drawDashedLine(
        canvas,
        Offset(c.dx, 0),
        Offset(c.dx, size.height),
        const Color(0xCC0D47A1),
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

    for (final GoPoint p in hintPoints) {
      final Offset c = Offset(padding + p.x * spacing, padding + p.y * spacing);
      canvas.drawCircle(
        c,
        spacing * 0.34,
        Paint()..color = const Color(0x6643A047),
      );
      canvas.drawCircle(
        c,
        spacing * 0.28,
        Paint()
          ..color = const Color(0xFFFFC107)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.6,
      );
      canvas.drawCircle(
        c,
        spacing * 0.1,
        Paint()..color = const Color(0xFFFFC107),
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

  Color _lighten(Color c, double amount) {
    return Color.fromRGBO(
      ((c.r + (1 - c.r) * amount) * 255).round().clamp(0, 255),
      ((c.g + (1 - c.g) * amount) * 255).round().clamp(0, 255),
      ((c.b + (1 - c.b) * amount) * 255).round().clamp(0, 255),
      c.a,
    );
  }

  Color _darken(Color c, double amount) {
    return Color.fromRGBO(
      (c.r * (1 - amount) * 255).round().clamp(0, 255),
      (c.g * (1 - amount) * 255).round().clamp(0, 255),
      (c.b * (1 - amount) * 255).round().clamp(0, 255),
      c.a,
    );
  }

  void _drawStone(Canvas canvas, Offset center, double radius, GoStone stone) {
    final Rect rect = Rect.fromCircle(center: center, radius: radius);
    if (stone == GoStone.black) {
      final RadialGradient blackGrad = RadialGradient(
        center: const Alignment(-0.35, -0.35),
        radius: 1.2,
        colors: const <Color>[
          Color(0xFF505050),
          Color(0xFF2A2A2A),
          Color(0xFF0A0A0A),
        ],
        stops: const <double>[0.0, 0.6, 1.0],
      );
      canvas.drawCircle(center, radius, Paint()..shader = blackGrad.createShader(rect));
    } else {
      final RadialGradient whiteGrad = RadialGradient(
        center: const Alignment(-0.4, -0.4),
        radius: 1.15,
        colors: const <Color>[
          Color(0xFFFFFFFF),
          Color(0xFFF0F0F0),
          Color(0xFFD8D8D8),
        ],
        stops: const <double>[0.0, 0.5, 1.0],
      );
      canvas.drawCircle(center, radius, Paint()..shader = whiteGrad.createShader(rect));
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..color = const Color(0xFF404040)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    }
  }

  void _drawDashedLine(Canvas canvas, Offset start, Offset end, Color color) {
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
        oldDelegate.tentativeStone != tentativeStone ||
        oldDelegate.hintPoints != hintPoints ||
        oldDelegate.ownership != ownership ||
        oldDelegate.boardBackgroundColor != boardBackgroundColor;
  }
}
