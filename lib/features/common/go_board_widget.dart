import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mastergo/domain/go/go_types.dart';

/// 台面绒布色，衬出榧木棋盘。
const Color kGoTableFelt = Color(0xFF2A5340);

/// 默认棋盘底色（榧木）；可通过 [GoBoardWidget.boardBackgroundColor] 覆盖。
const Color kDefaultBoardBackgroundColor = Color(0xFFD7A85A);

/// GTP 字母：跳过 I。
const String kGoFileLetters = 'ABCDEFGHJKLMNOPQRST';

String goFileLabel(int x) {
  if (x < 0 || x >= kGoFileLetters.length) {
    return '';
  }
  return kGoFileLetters[x];
}

/// 路数：画面上方为最大路，左下为 A1。
int goRankNumber(int y, int boardSize) => boardSize - y;

class GoBoardStage extends StatelessWidget {
  const GoBoardStage({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(color: kGoTableFelt, child: child);
  }
}

class GoBoardWidget extends StatefulWidget {
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
    this.showCoordinates = true,
    this.enableHover = true,
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
  final bool showCoordinates;
  final bool enableHover;

  @override
  State<GoBoardWidget> createState() => _GoBoardWidgetState();
}

class _GoBoardWidgetState extends State<GoBoardWidget> {
  static const double _minScale = 1;
  static const double _maxScale = 3.5;

  GoPoint? _hoverPoint;
  double _scale = 1;
  Offset _offset = Offset.zero;
  double _startScale = 1;
  Offset _startOffset = Offset.zero;
  Offset _focalStart = Offset.zero;
  Offset _lastFocal = Offset.zero;
  bool _pinching = false;
  double _moved = 0;

  double _inset() {
    const double frame = 5;
    final double coord = widget.showCoordinates ? 11 : 0;
    return math.max(widget.padding, frame + coord + 2);
  }

  void _setHover(GoPoint? point) {
    if (_hoverPoint == point) {
      return;
    }
    setState(() {
      _hoverPoint = point;
    });
  }

  void _place(GoPoint? point) {
    if (point == null || widget.onTapPoint == null) {
      return;
    }
    HapticFeedback.lightImpact();
    widget.onTapPoint!(point);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double maxW = constraints.maxWidth;
        final double maxH = constraints.maxHeight;
        final double side = math.min(maxW, maxH);
        final Size viewport = Size(maxW, maxH);
        final bool canPlay = widget.onTapPoint != null;
        final bool hoverOn = canPlay && widget.enableHover && _scale <= 1.01;
        return ColoredBox(
          color: kGoTableFelt,
          child: RawGestureDetector(
            gestures: <Type, GestureRecognizerFactory>{
              _BoardScaleRecognizer: GestureRecognizerFactoryWithHandlers<_BoardScaleRecognizer>(
                () => _BoardScaleRecognizer(),
                (_BoardScaleRecognizer instance) {
                  instance.allowOneFinger = canPlay;
                  instance.onStart = (ScaleStartDetails details) {
              _startScale = _scale;
              _startOffset = _offset;
              _focalStart = details.localFocalPoint;
              _lastFocal = details.localFocalPoint;
              _pinching = false;
              _moved = 0;
            };
                  instance.onUpdate = (ScaleUpdateDetails details) {
              _lastFocal = details.localFocalPoint;
              _moved += details.focalPointDelta.distance;
              final Offset pan = details.localFocalPoint - _focalStart;
              if (details.pointerCount >= 2) {
                _pinching = true;
                setState(() {
                  _scale = (_startScale * details.scale).clamp(_minScale, _maxScale);
                  _offset = _clampOffset(_startOffset + pan, side);
                });
                return;
              }
              if (_scale > 1.01) {
                setState(() {
                  _offset = _clampOffset(_startOffset + pan, side);
                });
                return;
              }
              if (hoverOn) {
                _setHover(
                  _toPoint(_boardLocal(details.localFocalPoint, viewport, side), side),
                );
              }
            };
                  instance.onEnd = (ScaleEndDetails details) {
              final bool pinched = _pinching;
              final GoPoint? aimed = _hoverPoint ??
                  _toPoint(_boardLocal(_lastFocal, viewport, side), side);
              _setHover(null);
              _pinching = false;
              if (_scale <= 1.001) {
                setState(() {
                  _scale = 1;
                  _offset = Offset.zero;
                });
              }
              if (pinched || !canPlay) {
                return;
              }
              if (_scale <= 1.01) {
                _place(aimed);
                return;
              }
              if (_moved < 18) {
                _place(aimed);
              }
            };
                },
              ),
            },
            child: Center(
              child: Transform.translate(
                offset: _offset,
                child: Transform.scale(
                  scale: _scale,
                  child: SizedBox(
                    width: side,
                    height: side,
                    child: CustomPaint(
                      painter: _GoBoardPainter(
                        boardSize: widget.boardSize,
                        board: widget.board,
                        inset: _inset(),
                        lastMovePoint: widget.lastMovePoint,
                        tentativePoint: widget.tentativePoint,
                        tentativeStone: widget.tentativeStone,
                        hoverPoint: hoverOn ? _hoverPoint : null,
                        hintPoints: widget.hintPoints,
                        ownership: widget.ownership,
                        boardBackgroundColor:
                            widget.boardBackgroundColor ?? kDefaultBoardBackgroundColor,
                        showCoordinates: widget.showCoordinates,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Offset _clampOffset(Offset next, double side) {
    final double limit = side * (_scale - 1) / 2 + 24;
    return Offset(next.dx.clamp(-limit, limit), next.dy.clamp(-limit, limit));
  }

  Offset _boardLocal(Offset viewportPoint, Size viewport, double side) {
    final Offset center = viewport.center(Offset.zero);
    final Offset child = (viewportPoint - _offset - center) / _scale + center;
    return child - center + Offset(side / 2, side / 2);
  }

  GoPoint? _toPoint(Offset offset, double boardPixelSize) {
    final double inset = _inset();
    final double gridSize = boardPixelSize - inset * 2;
    if (gridSize <= 0 || widget.boardSize <= 1) {
      return null;
    }
    final double spacing = gridSize / (widget.boardSize - 1);
    final int x = ((offset.dx - inset) / spacing).round();
    final int y = ((offset.dy - inset) / spacing).round();
    if (x < 0 || x >= widget.boardSize || y < 0 || y >= widget.boardSize) {
      return null;
    }
    return GoPoint(x, y);
  }
}

class _BoardScaleRecognizer extends ScaleGestureRecognizer {
  bool allowOneFinger = true;

  @override
  void handleEvent(PointerEvent event) {
    if (!allowOneFinger && pointerCount < 2 && event is PointerMoveEvent) {
      resolve(GestureDisposition.rejected);
      return;
    }
    super.handleEvent(event);
  }
}

class _WoodCache {
  static ui.Picture? picture;
  static Size? size;
  static int? colorValue;
}

class _LabelCache {
  static final Map<String, TextPainter> _painters = <String, TextPainter>{};

  static TextPainter of(String text, TextStyle style) {
    final String key = '${style.fontSize}|$text';
    final TextPainter? cached = _painters[key];
    if (cached != null) {
      return cached;
    }
    final TextPainter painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    _painters[key] = painter;
    return painter;
  }
}

class _GoBoardPainter extends CustomPainter {
  _GoBoardPainter({
    required this.boardSize,
    required this.board,
    required this.inset,
    required this.lastMovePoint,
    required this.tentativePoint,
    required this.tentativeStone,
    required this.hoverPoint,
    required this.hintPoints,
    required this.boardBackgroundColor,
    required this.showCoordinates,
    this.ownership,
  });

  final int boardSize;
  final List<List<GoStone?>> board;
  final double inset;
  final GoPoint? lastMovePoint;
  final GoPoint? tentativePoint;
  final GoStone? tentativeStone;
  final GoPoint? hoverPoint;
  final List<GoPoint> hintPoints;
  final Color boardBackgroundColor;
  final bool showCoordinates;
  final List<double>? ownership;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect boardRect = Offset.zero & size;
    _paintCachedWood(canvas, size, boardBackgroundColor);
    _paintFrame(canvas, boardRect);

    if (boardSize <= 1) {
      return;
    }
    final double gridSize = size.width - inset * 2;
    final double spacing = gridSize / (boardSize - 1);

    _paintGrid(canvas, size, spacing);
    if (showCoordinates) {
      _paintCoordinates(canvas, size, spacing);
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
      if (strength < 0.55) {
        return halfS;
      }
      if (strength < 0.8) {
        return halfM;
      }
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
          final double cx = inset + x * spacing;
          final double cy = inset + y * spacing;
          final bool isBlack = v > 0;
          final double strength = isBlack ? v : -v;
          double useHalf = markerHalf(strength);
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
        final Offset c = Offset(inset + x * spacing, inset + y * spacing);
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
          final bool dead =
              (s == GoStone.black && territoryIsWhite) ||
              (s == GoStone.white && territoryIsBlack);
          if (!dead) {
            continue;
          }
          final double cx = inset + x * spacing;
          final double cy = inset + y * spacing;
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
        inset + tentativePoint!.x * spacing,
        inset + tentativePoint!.y * spacing,
      );
      _drawDashedLine(
        canvas,
        Offset(0, c.dy),
        Offset(size.width, c.dy),
        const Color(0xCC1B4F72),
      );
      _drawDashedLine(
        canvas,
        Offset(c.dx, 0),
        Offset(c.dx, size.height),
        const Color(0xCC1B4F72),
      );
      _drawStone(canvas, c, stoneRadius, tentativeStone!, ghost: true);
    }

    if (hoverPoint != null &&
        (tentativePoint == null ||
            hoverPoint!.x != tentativePoint!.x ||
            hoverPoint!.y != tentativePoint!.y)) {
      final Offset c = Offset(
        inset + hoverPoint!.x * spacing,
        inset + hoverPoint!.y * spacing,
      );
      canvas.drawCircle(
        c,
        spacing * 0.22,
        Paint()
          ..color = const Color(0x663E2723)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6,
      );
    }

    if (lastMovePoint != null) {
      final Offset c = Offset(
        inset + lastMovePoint!.x * spacing,
        inset + lastMovePoint!.y * spacing,
      );
      final GoStone? stone = _stoneAt(lastMovePoint!);
      final Color mark = stone == GoStone.white
          ? const Color(0xFF3E2723)
          : const Color(0xFFF3E6C8);
      canvas.drawCircle(c, spacing * 0.14, Paint()..color = mark);
    }

    for (final GoPoint p in hintPoints) {
      final Offset c = Offset(inset + p.x * spacing, inset + p.y * spacing);
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

  GoStone? _stoneAt(GoPoint p) {
    if (p.y < 0 || p.y >= board.length) {
      return null;
    }
    if (p.x < 0 || p.x >= board[p.y].length) {
      return null;
    }
    return board[p.y][p.x];
  }

  void _paintCachedWood(Canvas canvas, Size size, Color base) {
    final int value = base.toARGB32();
    if (_WoodCache.picture == null ||
        _WoodCache.size != size ||
        _WoodCache.colorValue != value) {
      final ui.PictureRecorder recorder = ui.PictureRecorder();
      _paintWoodGrain(Canvas(recorder), Offset.zero & size, base);
      _WoodCache.picture = recorder.endRecording();
      _WoodCache.size = size;
      _WoodCache.colorValue = value;
    }
    canvas.drawPicture(_WoodCache.picture!);
  }

  void _paintWoodGrain(Canvas canvas, Rect rect, Color base) {
    canvas.drawRect(rect, Paint()..color = base);
    final math.Random rng = math.Random(2026);

    for (int i = 0; i < 9; i++) {
      final double t = (i + 1) / 10;
      final double x =
          rect.left + rect.width * t + (rng.nextDouble() - 0.5) * 10;
      final Path path = Path()..moveTo(x, rect.top);
      for (int s = 1; s <= 10; s++) {
        final double y = rect.top + rect.height * s / 10;
        path.lineTo(x + math.sin(s * 0.62 + i) * 7, y);
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = Color.fromRGBO(92, 50, 16, 0.055 + rng.nextDouble() * 0.04)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 11 + rng.nextDouble() * 16
          ..strokeCap = StrokeCap.round,
      );
    }

    final int lines = (rect.width / 5).round().clamp(24, 72);
    for (int i = 0; i < lines; i++) {
      final double x0 = rect.left + (i + 0.5) * (rect.width / lines);
      final bool dark = i.isEven;
      final Path path = Path()..moveTo(x0, rect.top);
      const int segs = 12;
      for (int s = 1; s <= segs; s++) {
        final double y = rect.top + rect.height * s / segs;
        final double dx =
            math.sin(s * 0.45 + i * 0.31) * 2.1 + math.sin(s * 1.25 + i) * 0.7;
        path.lineTo(x0 + dx, y);
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = dark
              ? Color.fromRGBO(90, 48, 16, 0.10 + rng.nextDouble() * 0.07)
              : Color.fromRGBO(255, 232, 176, 0.08 + rng.nextDouble() * 0.05)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.7 + rng.nextDouble() * 1.1,
      );
    }

    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            Color(0x24FFFFFF),
            Color(0x00FFFFFF),
            Color(0x1A4E2A0C),
          ],
          stops: <double>[0, 0.46, 1],
        ).createShader(rect),
    );
  }

  void _paintFrame(Canvas canvas, Rect rect) {
    canvas.drawRect(
      rect.deflate(0.6),
      Paint()
        ..color = const Color(0xFF5A3318)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.2,
    );
    canvas.drawRect(
      rect.deflate(3.4),
      Paint()
        ..color = const Color(0x66FFE6B0)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4,
    );
    canvas.drawRect(
      rect.deflate(5.2),
      Paint()
        ..color = const Color(0x335A3318)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.1,
    );
  }

  void _paintGrid(Canvas canvas, Size size, double spacing) {
    final Paint inner = Paint()
      ..color = const Color(0xFF5B3A29)
      ..strokeWidth = 0.9
      ..isAntiAlias = true;
    final Paint outer = Paint()
      ..color = const Color(0xFF4A2C1A)
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.square;

    for (int i = 0; i < boardSize; i++) {
      final double p = inset + i * spacing;
      final Paint paint = (i == 0 || i == boardSize - 1) ? outer : inner;
      canvas.drawLine(Offset(inset, p), Offset(size.width - inset, p), paint);
      canvas.drawLine(Offset(p, inset), Offset(p, size.height - inset), paint);
    }

    final Paint starPaint = Paint()..color = const Color(0xFF4A2C1A);
    for (final GoPoint p in _starPoints()) {
      final Offset c = Offset(inset + p.x * spacing, inset + p.y * spacing);
      canvas.drawCircle(c, math.max(2.2, spacing * 0.095), starPaint);
    }
  }

  void _paintCoordinates(Canvas canvas, Size size, double spacing) {
    final double fontSize = (spacing * 0.38).clamp(8.0, 12.0);
    final TextStyle style = TextStyle(
      color: const Color(0xFF5B3A29),
      fontSize: fontSize,
      fontWeight: FontWeight.w600,
      height: 1,
    );
    for (int i = 0; i < boardSize; i++) {
      final double p = inset + i * spacing;
      _drawLabel(canvas, goFileLabel(i), Offset(p, inset - 10), style);
      _drawLabel(
        canvas,
        goFileLabel(i),
        Offset(p, size.height - inset + 10),
        style,
      );
      final String rank = '${goRankNumber(i, boardSize)}';
      _drawLabel(canvas, rank, Offset(inset - 10, p), style);
      _drawLabel(canvas, rank, Offset(size.width - inset + 10, p), style);
    }
  }

  void _drawLabel(Canvas canvas, String text, Offset center, TextStyle style) {
    final TextPainter painter = _LabelCache.of(text, style);
    painter.paint(
      canvas,
      Offset(center.dx - painter.width / 2, center.dy - painter.height / 2),
    );
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

  void _drawStone(
    Canvas canvas,
    Offset center,
    double radius,
    GoStone stone, {
    bool ghost = false,
  }) {
    final double shadowRx = radius * 0.92;
    final double shadowRy = radius * 0.28;
    canvas.drawOval(
      Rect.fromCenter(
        center: center + Offset(radius * 0.12, radius * 0.28),
        width: shadowRx * 2,
        height: shadowRy * 2,
      ),
      Paint()..color = Color.fromRGBO(40, 22, 8, ghost ? 0.12 : 0.28),
    );

    final Rect rect = Rect.fromCircle(center: center, radius: radius);
    if (stone == GoStone.black) {
      final RadialGradient blackGrad = RadialGradient(
        center: const Alignment(-0.42, -0.42),
        radius: 1.28,
        colors: <Color>[
          Color.fromRGBO(90, 90, 90, ghost ? 0.42 : 1),
          Color.fromRGBO(42, 42, 42, ghost ? 0.42 : 1),
          Color.fromRGBO(16, 16, 16, ghost ? 0.42 : 1),
          Color.fromRGBO(6, 6, 6, ghost ? 0.42 : 1),
        ],
        stops: const <double>[0.0, 0.28, 0.68, 1.0],
      );
      canvas.drawCircle(
        center,
        radius,
        Paint()..shader = blackGrad.createShader(rect),
      );
      final double specRadius = radius * 0.30;
      final Offset specCenter = center + Offset(-radius * 0.34, -radius * 0.34);
      canvas.drawCircle(
        specCenter,
        specRadius,
        Paint()
          ..shader = RadialGradient(
            colors: <Color>[
              Color.fromRGBO(170, 170, 170, ghost ? 0.35 : 0.85),
              const Color(0x00000000),
            ],
          ).createShader(Rect.fromCircle(center: specCenter, radius: specRadius)),
      );
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..color = Color.fromRGBO(8, 8, 8, ghost ? 0.35 : 1)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.8,
      );
    } else {
      final RadialGradient whiteGrad = RadialGradient(
        center: const Alignment(-0.48, -0.48),
        radius: 1.32,
        colors: <Color>[
          Color.fromRGBO(255, 252, 246, ghost ? 0.55 : 1),
          Color.fromRGBO(244, 236, 220, ghost ? 0.55 : 1),
          Color.fromRGBO(226, 214, 194, ghost ? 0.55 : 1),
          Color.fromRGBO(204, 188, 164, ghost ? 0.55 : 1),
        ],
        stops: const <double>[0.0, 0.22, 0.62, 1.0],
      );
      canvas.drawCircle(
        center,
        radius,
        Paint()..shader = whiteGrad.createShader(rect),
      );
      final double specRadius = radius * 0.26;
      final Offset specCenter = center + Offset(-radius * 0.38, -radius * 0.38);
      canvas.drawCircle(
        specCenter,
        specRadius,
        Paint()
          ..shader = RadialGradient(
            colors: <Color>[
              Color.fromRGBO(255, 255, 255, ghost ? 0.4 : 0.95),
              const Color(0x00FFFFFF),
            ],
          ).createShader(Rect.fromCircle(center: specCenter, radius: specRadius)),
      );
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..color = Color.fromRGBO(110, 92, 70, ghost ? 0.4 : 1)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.1,
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
      canvas.drawLine(start + dir * t, start + dir * next, paint);
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
        oldDelegate.hoverPoint != hoverPoint ||
        oldDelegate.hintPoints != hintPoints ||
        oldDelegate.ownership != ownership ||
        oldDelegate.boardBackgroundColor != boardBackgroundColor ||
        oldDelegate.showCoordinates != showCoordinates ||
        oldDelegate.inset != inset;
  }
}
