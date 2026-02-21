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
  static const double _tipsReservedHeight = 78;
  static const double _targetHandleSizePx = 28;
  static const double _targetHitRadiusPx = 32;

  final TransformationController _transformController =
      TransformationController();
  Size? _lastViewportSize;
  int? _activeCornerIndex;
  int? _activePointer;

  double get _currentScale =>
      _transformController.value.getMaxScaleOnAxis().clamp(0.1, 20.0);

  double get _handleSizeInImage => _targetHandleSizePx / _currentScale;
  double get _hitRadiusInImage => _targetHitRadiusPx / _currentScale;

  @override
  void initState() {
    super.initState();
    _transformController.addListener(_onTransformChanged);
  }

  void _onTransformChanged() {
    if (!mounted) return;
    // 刷新角点可视大小与命中半径，避免缩放后拖动手感变化。
    setState(() {});
  }

  @override
  void dispose() {
    _transformController.removeListener(_onTransformChanged);
    _transformController.dispose();
    super.dispose();
  }

  void _ensureFitTransform(Size viewport, int imgW, int imgH) {
    if (imgW <= 0 || imgH <= 0) return;
    if (_lastViewportSize == viewport) return;
    _lastViewportSize = viewport;
    final double fitScale = (viewport.width / imgW) < (viewport.height / imgH)
        ? (viewport.width / imgW)
        : (viewport.height / imgH);
    final double dx = (viewport.width - imgW * fitScale) / 2;
    final double dy = (viewport.height - imgH * fitScale) / 2;
    _transformController.value = Matrix4.identity()
      ..translate(dx, dy)
      ..scale(fitScale);
  }

  Offset _toImagePoint(Offset localPoint) =>
      _transformController.toScene(localPoint);

  int? _hitCorner(Offset imagePoint) {
    int? index;
    double best = double.infinity;
    for (int i = 0; i < widget.corners.length; i++) {
      final double d = (widget.corners[i] - imagePoint).distance;
      if (d <= _hitRadiusInImage && d < best) {
        best = d;
        index = i;
      }
    }
    return index;
  }

  void _onPointerDown(PointerDownEvent event, int imgW, int imgH) {
    if (_activePointer != null) return;
    final Offset imagePoint = _toImagePoint(event.localPosition);
    final int? hitIndex = _hitCorner(imagePoint);
    if (hitIndex == null) return;
    _activePointer = event.pointer;
    _activeCornerIndex = hitIndex;
    widget.onDragStart(hitIndex);
    setState(() {});
  }

  void _onPointerMove(PointerMoveEvent event, int imgW, int imgH) {
    if (_activePointer != event.pointer || _activeCornerIndex == null) return;
    final Offset imagePoint = _toImagePoint(event.localPosition);
    final Offset clamped = Offset(
      imagePoint.dx.clamp(0.0, imgW.toDouble()),
      imagePoint.dy.clamp(0.0, imgH.toDouble()),
    );
    final List<Offset> updated = List<Offset>.from(widget.corners);
    updated[_activeCornerIndex!] = clamped;
    widget.onCornersChanged(updated);
  }

  void _onPointerUpOrCancel(PointerEvent event) {
    if (_activePointer != event.pointer) return;
    _activePointer = null;
    _activeCornerIndex = null;
    widget.onDragEnd();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final int imgW = widget.imageWidth;
    final int imgH = widget.imageHeight;

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 600, maxHeight: 800),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final double viewportW = constraints.maxWidth.clamp(1.0, 600.0);
          final double viewportH =
              (constraints.maxHeight - _tipsReservedHeight).clamp(1.0, 760.0);
          _ensureFitTransform(Size(viewportW, viewportH), imgW, imgH);
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
                width: viewportW,
                height: viewportH,
                child: Listener(
                  behavior: HitTestBehavior.translucent,
                  onPointerDown: (PointerDownEvent e) =>
                      _onPointerDown(e, imgW, imgH),
                  onPointerMove: (PointerMoveEvent e) =>
                      _onPointerMove(e, imgW, imgH),
                  onPointerUp: _onPointerUpOrCancel,
                  onPointerCancel: _onPointerUpOrCancel,
                  child: InteractiveViewer(
                    transformationController: _transformController,
                    panEnabled: _activePointer == null,
                    scaleEnabled: _activePointer == null,
                    minScale: 0.3,
                    maxScale: 8.0,
                    boundaryMargin: const EdgeInsets.all(240),
                    constrained: false,
                    child: SizedBox(
                      width: imgW.toDouble(),
                      height: imgH.toDouble(),
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: <Widget>[
                          Positioned.fill(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: Image.memory(
                                widget.imageBytes,
                                fit: BoxFit.fill,
                              ),
                            ),
                          ),
                          Positioned.fill(
                            child: IgnorePointer(
                              child: CustomPaint(
                                painter: _QuadOverlayPainter(
                                  corners: widget.corners,
                                  color: Colors.green.withValues(alpha: 0.8),
                                  strokeWidth: 3 / _currentScale,
                                ),
                              ),
                            ),
                          ),
                          ...List<Widget>.generate(4, (int i) {
                            final Offset pos = widget.corners[i];
                            final double handleSize = _handleSizeInImage;
                            return Positioned(
                              left: pos.dx - handleSize / 2,
                              top: pos.dy - handleSize / 2,
                              width: handleSize,
                              height: handleSize,
                              child: IgnorePointer(
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: widget.draggingIndex == i
                                        ? Colors.blue
                                        : Colors.green,
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: Colors.white,
                                      width: 2 / _currentScale,
                                    ),
                                    boxShadow: <BoxShadow>[
                                      BoxShadow(
                                        color: Colors.black.withValues(alpha: 0.3),
                                        blurRadius: 4 / _currentScale,
                                        offset: Offset(0, 2 / _currentScale),
                                      ),
                                    ],
                                  ),
                                  child: Center(
                                    child: Text(
                                      '${i + 1}',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 12 / _currentScale,
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
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '双指缩放，单指拖角点（命中后锁定画布）',
                  style: Theme.of(context).textTheme.bodySmall,
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
