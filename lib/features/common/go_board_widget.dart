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
  /// Per-point ownership in this project runtime: row-major, 1 = black, -1 = white. Length boardSize².
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

    const double threshold = 0.35;
    const Color blackFill = Color(0xFF2D2D2D);
    const Color blackStroke = Color(0xFF161616);
    const Color whiteFill = Color(0xFFECECEC);
    const Color whiteStroke = Color(0xFF9E9E9E);
    const double strokeWidth = 1.0;
    final double halfS = (spacing * 0.11).clamp(2.2, 5.5);
    final double halfM = (spacing * 0.16).clamp(3.0, 7.5);
    final double halfL = (spacing * 0.22).clamp(4.0, 10.0);

    double markerHalf(double strength) {
      if (strength < 0.55) return halfS;
      if (strength < 0.8) return halfM;
      return halfL;
    }

    if (ownership != null && ownership!.length >= boardSize * boardSize) {
      for (int y = 0; y < boardSize; y++) {
        for (int x = 0; x < boardSize; x++) {
          final int idx = y * boardSize + x;
          final double v = ownership![idx].clamp(-1.0, 1.0);
          if (v >= -threshold && v <= threshold) {
            continue;
          }
          final double cx = padding + x * spacing;
          final double cy = padding + y * spacing;
          // Runtime verification in this project: positive ownership = black territory.
          final bool isBlack = v > 0;
          final double strength = isBlack ? v : -v;
          double useHalf = markerHalf(strength);
          // 白方格可覆盖交叉线/星位，视觉上更贴近参考图
          if (!isBlack) {
            useHalf *= 1.12;
          }
          final Rect rect = Rect.fromCenter(
            center: Offset(cx, cy),
            width: useHalf * 2,
            height: useHalf * 2,
          );
          canvas.drawRect(rect, Paint()..color = isBlack ? blackFill : whiteFill);
          canvas.drawRect(
            rect,
            Paint()
              ..color = isBlack ? blackStroke : whiteStroke
              ..style = PaintingStyle.stroke
              ..strokeWidth = strokeWidth,
          );
        }
      }
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

    if (ownership != null && ownership!.length >= boardSize * boardSize) {
      for (int y = 0; y < boardSize; y++) {
        for (int x = 0; x < boardSize; x++) {
          final GoStone? s = board[y][x];
          if (s == null) {
            continue;
          }
          final int idx = y * boardSize + x;
          final double v = ownership![idx].clamp(-1.0, 1.0);
          final bool territoryIsBlack = v > threshold;
          final bool territoryIsWhite = v < -threshold;
          final bool dead = (s == GoStone.black && territoryIsWhite) ||
              (s == GoStone.white && territoryIsBlack);
          if (!dead) {
            continue;
          }
          final double cx = padding + x * spacing;
          final double cy = padding + y * spacing;
          final bool isBlack = v > 0;
          final double strength = isBlack ? -v : v;
          final double deadHalf = markerHalf(strength).clamp(2.6, 8.2);
          final Rect rect = Rect.fromCenter(
            center: Offset(cx, cy),
            width: deadHalf * 2,
            height: deadHalf * 2,
          );
          canvas.drawRect(rect, Paint()..color = isBlack ? blackFill : whiteFill);
          canvas.drawRect(
            rect,
            Paint()
              ..color = isBlack ? blackStroke : whiteStroke
              ..style = PaintingStyle.stroke
              ..strokeWidth = strokeWidth,
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
      // 黑子立体感：左上高光、右下暗部，再加小高光点
      final RadialGradient blackGrad = RadialGradient(
        center: const Alignment(-0.45, -0.45),
        radius: 1.35,
        colors: const <Color>[
          Color(0xFF6A6A6A),
          Color(0xFF3A3A3A),
          Color(0xFF1A1A1A),
          Color(0xFF080808),
        ],
        stops: const <double>[0.0, 0.25, 0.65, 1.0],
      );
      canvas.drawCircle(center, radius, Paint()..shader = blackGrad.createShader(rect));
      final double specRadius = radius * 0.32;
      final Offset specCenter = center + Offset(-radius * 0.35, -radius * 0.35);
      final Rect specRect = Rect.fromCircle(center: specCenter, radius: specRadius);
      final RadialGradient specGrad = RadialGradient(
        center: Alignment.center,
        radius: 1.0,
        colors: const <Color>[Color(0xFF9A9A9A), Color(0x00000000)],
        stops: const <double>[0.0, 1.0],
      );
      canvas.drawCircle(specCenter, specRadius, Paint()..shader = specGrad.createShader(specRect));
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..color = const Color(0xFF0A0A0A)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.8,
      );
    } else {
      // 白子立体感：左上高光、右下微灰阴影，加清晰轮廓与小高光点
      final RadialGradient whiteGrad = RadialGradient(
        center: const Alignment(-0.5, -0.5),
        radius: 1.4,
        colors: const <Color>[
          Color(0xFFFFFFFF),
          Color(0xFFF8F8F8),
          Color(0xFFE8E8E8),
          Color(0xFFD0D0D0),
        ],
        stops: const <double>[0.0, 0.2, 0.6, 1.0],
      );
      canvas.drawCircle(center, radius, Paint()..shader = whiteGrad.createShader(rect));
      final double specRadius = radius * 0.28;
      final Offset specCenter = center + Offset(-radius * 0.4, -radius * 0.4);
      final Rect specRect = Rect.fromCircle(center: specCenter, radius: specRadius);
      final RadialGradient specGrad = RadialGradient(
        center: Alignment.center,
        radius: 1.0,
        colors: const <Color>[Color(0xFFFFFFFF), Color(0x00FFFFFF)],
        stops: const <double>[0.0, 1.0],
      );
      canvas.drawCircle(specCenter, specRadius, Paint()..shader = specGrad.createShader(specRect));
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..color = const Color(0xFF707070)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2,
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
