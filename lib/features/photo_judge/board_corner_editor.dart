import 'dart:typed_data';

import 'package:flutter/material.dart';

/// 角点调整页：显示图片 + 四角覆盖层，支持拖动。
class BoardCornerEditorPage extends StatefulWidget {
  const BoardCornerEditorPage({
    super.key,
    required this.imageBytes,
    required this.initialCorners,
    required this.imageWidth,
    required this.imageHeight,
  });

  final Uint8List imageBytes;
  final List<Offset> initialCorners; // TL, TR, BR, BL
  final int imageWidth;
  final int imageHeight;

  @override
  State<BoardCornerEditorPage> createState() => _BoardCornerEditorPageState();
}

class _BoardCornerEditorPageState extends State<BoardCornerEditorPage> {
  late List<Offset> _corners;
  int? _draggingIndex;

  @override
  void initState() {
    super.initState();
    _corners = _sanitizeCorners(
      widget.initialCorners,
      widget.imageWidth.toDouble(),
      widget.imageHeight.toDouble(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('调整棋盘四角'),
        actions: <Widget>[
          TextButton.icon(
            onPressed: _onConfirm,
            icon: const Icon(Icons.check),
            label: const Text('确认识别'),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: _ImageWithCornersOverlay(
              imageBytes: widget.imageBytes,
              imageWidth: widget.imageWidth,
              imageHeight: widget.imageHeight,
              corners: _corners,
              draggingIndex: _draggingIndex,
              onCornersChanged: (List<Offset> list) => setState(() => _corners = list),
              onDragStart: (int i) => setState(() => _draggingIndex = i),
              onDragEnd: () => setState(() => _draggingIndex = null),
            ),
          ),
        ),
      ),
    );
  }

  void _onConfirm() {
    Navigator.of(context).pop(_corners);
  }

  List<Offset> _sanitizeCorners(List<Offset> points, double w, double h) {
    return points
        .map(
          (Offset p) => Offset(
            p.dx.clamp(0.0, w),
            p.dy.clamp(0.0, h),
          ),
        )
        .toList();
  }
}

class _ImageWithCornersOverlay extends StatefulWidget {
  const _ImageWithCornersOverlay({
    required this.imageBytes,
    required this.imageWidth,
    required this.imageHeight,
    required this.corners,
    required this.draggingIndex,
    required this.onCornersChanged,
    required this.onDragStart,
    required this.onDragEnd,
  });

  final Uint8List imageBytes;
  final int imageWidth;
  final int imageHeight;
  final List<Offset> corners;
  final int? draggingIndex;
  final ValueChanged<List<Offset>> onCornersChanged;
  final ValueChanged<int> onDragStart;
  final VoidCallback onDragEnd;

  @override
  State<_ImageWithCornersOverlay> createState() => _ImageWithCornersOverlayState();
}

class _ImageWithCornersOverlayState extends State<_ImageWithCornersOverlay> {
  static const double _handleTouchRadius = 30;
  static const double _workPadding = 28;
  static const double _tipsReservedHeight = 78;
  double _scale = 1.0;
  double _dispW = 0;
  double _dispH = 0;
  double _canvasW = 0;
  double _canvasH = 0;

  void _computeLayout(BoxConstraints constraints, int imgW, int imgH) {
    if (imgW <= 0 || imgH <= 0) return;
    final double cw = (constraints.maxWidth - _workPadding * 2).clamp(1, double.infinity);
    final double ch = (constraints.maxHeight - _workPadding * 2 - _tipsReservedHeight).clamp(1, double.infinity);
    final double s = (cw / imgW) < (ch / imgH) ? (cw / imgW) : (ch / imgH);
    _scale = s;
    _dispW = imgW * s;
    _dispH = imgH * s;
    _canvasW = _dispW + _workPadding * 2;
    _canvasH = _dispH + _workPadding * 2;
  }

  Offset _imageToDisplay(Offset p) => Offset(_workPadding + p.dx * _scale, _workPadding + p.dy * _scale);

  @override
  Widget build(BuildContext context) {
    final int imgW = widget.imageWidth;
    final int imgH = widget.imageHeight;

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 600, maxHeight: 800),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          _computeLayout(constraints, imgW, imgH);
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                '请按 1左上 / 2右上 / 3右下 / 4左下 对准棋盘四个交点。\n仅框内区域参与识别：框内更亮，框外灰暗。',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Colors.grey,
                    ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: _canvasW,
                height: _canvasH,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: <Widget>[
                    Positioned(
                      left: _workPadding,
                      top: _workPadding,
                      width: _dispW,
                      height: _dispH,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.memory(
                          widget.imageBytes,
                          fit: BoxFit.fill,
                        ),
                      ),
                    ),
                    Positioned(
                      left: _workPadding,
                      top: _workPadding,
                      width: _dispW,
                      height: _dispH,
                      child: IgnorePointer(
                        child: CustomPaint(
                          painter: _QuadOverlayPainter(
                            corners: widget.corners
                                .map((Offset p) {
                                  final Offset d = _imageToDisplay(p);
                                  return Offset(d.dx - _workPadding, d.dy - _workPadding);
                                })
                                .toList(),
                            color: Colors.green.withValues(alpha: 0.8),
                            strokeWidth: 3,
                          ),
                        ),
                      ),
                    ),
                    ...List<Widget>.generate(4, (int i) {
                      final Offset pos = _imageToDisplay(widget.corners[i]);
                      return Positioned(
                        left: pos.dx - _handleTouchRadius,
                        top: pos.dy - _handleTouchRadius,
                        width: _handleTouchRadius * 2,
                        height: _handleTouchRadius * 2,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onPanStart: (_) => widget.onDragStart(i),
                          onPanUpdate: (DragUpdateDetails d) {
                            final Offset cur = widget.corners[i];
                            final Offset newImg = Offset(
                              (cur.dx + d.delta.dx / _scale).clamp(0.0, imgW.toDouble()),
                              (cur.dy + d.delta.dy / _scale).clamp(0.0, imgH.toDouble()),
                            );
                            final List<Offset> updated = List<Offset>.from(widget.corners);
                            updated[i] = newImg;
                            widget.onCornersChanged(updated);
                          },
                          onPanEnd: (_) => widget.onDragEnd(),
                          child: Center(
                            child: Container(
                              width: 28,
                              height: 28,
                              decoration: BoxDecoration(
                                color: widget.draggingIndex == i ? Colors.blue : Colors.green,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: Colors.white,
                                  width: 2,
                                ),
                                boxShadow: <BoxShadow>[
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.3),
                                    blurRadius: 4,
                                    offset: const Offset(0, 2),
                                  ),
                                ],
                              ),
                              child: Center(
                                child: Text(
                                  '${i + 1}',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    }),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _QuadOverlayPainter extends CustomPainter {
  _QuadOverlayPainter({
    required this.corners,
    required this.color,
    this.strokeWidth = 2,
  });

  final List<Offset> corners;
  final Color color;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    if (corners.length < 4) return;
    final Path quadPath = Path()
      ..moveTo(corners[0].dx, corners[0].dy)
      ..lineTo(corners[1].dx, corners[1].dy)
      ..lineTo(corners[2].dx, corners[2].dy)
      ..lineTo(corners[3].dx, corners[3].dy)
      ..close();
    final Path fullPath = Path()..addRect(Offset.zero & size);
    final Path outsideMask = Path.combine(PathOperation.difference, fullPath, quadPath);

    // 框外灰暗，框内保持更亮，帮助用户理解“有效识别区域”。
    canvas.drawPath(
      outsideMask,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.45)
        ..style = PaintingStyle.fill,
    );
    canvas.drawPath(
      quadPath,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.08)
        ..style = PaintingStyle.fill,
    );
    canvas.drawPath(
      quadPath,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth,
    );
  }

  @override
  bool shouldRepaint(covariant _QuadOverlayPainter old) => old.corners != corners || old.color != color;
}
