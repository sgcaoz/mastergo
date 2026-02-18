import 'dart:typed_data';

import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'package:mastergo/domain/go/go_types.dart';

/// 基于棋盘边界与线条的识别：不依赖棋盘颜色。
/// 流程：灰度 → 边缘检测 → 轮廓 → 最大四边形即棋盘 → 透视校正 → 等分网格 → 交叉点局部采样判棋子。
RecognizedBoard? recognizeGoBoardFromBytes(Uint8List imageBytes, int boardSize) {
  if (imageBytes.isEmpty) return null;

  cv.Mat? frame;
  cv.Mat? gray;
  cv.Mat? blurred;
  cv.Mat? canny;
  cv.Mat? birdsEye;
  cv.Mat? warpedHsv;
  cv.Mat? warpedBlur;
  cv.Mat? transformM;
  try {
    frame = cv.imdecode(imageBytes, cv.IMREAD_COLOR);
    if (frame.isEmpty) return null;

    // 1) 棋盘定位：只看边缘与边界，不依赖颜色
    gray = cv.cvtColor(frame, cv.COLOR_BGR2GRAY);
    blurred = cv.gaussianBlur(gray, (5, 5), 0);
    canny = cv.canny(blurred, 50, 150);

    const int mode = 0; // RETR_EXTERNAL
    const int method = 2; // CHAIN_APPROX_SIMPLE
    final (cv.Contours contours, _) = cv.findContours(canny, mode, method);

    final int imgW = frame.cols;
    final int imgH = frame.rows;
    final double imgArea = (imgW * imgH).toDouble();
    double bestScore = -1;
    List<cv.Point>? ordered;
    for (int i = 0; i < contours.length; i++) {
      final cv.VecPoint c = contours.elementAt(i);
      final double len = cv.arcLength(c, true);
      if (len < 100) continue;
      final double epsilon = len * 0.02;
      final cv.VecPoint approx = cv.approxPolyDP(c, epsilon, true);
      if (approx.length == 4) {
        final List<cv.Point> candidate = _orderFourPoints(approx);
        final _QuadMetrics m = _quadMetrics(candidate);
        // 排除贴近整张照片边框的假四边形（常见误检）
        const int edgeMargin = 10;
        final bool nearImageEdge =
            m.minX <= edgeMargin ||
            m.minY <= edgeMargin ||
            m.maxX >= imgW - edgeMargin ||
            m.maxY >= imgH - edgeMargin;
        if (nearImageEdge) continue;
        final double areaRatio = m.area / imgArea;
        // 围棋棋盘一般接近正方形且在画面中占一定面积
        if (areaRatio < 0.08 || areaRatio > 0.95) continue;
        if (m.aspect < 0.65 || m.aspect > 1.55) continue;
        // 面积优先，形状越接近正方形得分越高
        final double squarePenalty = 1.0 - (m.aspect - 1.0).abs().clamp(0.0, 1.0);
        final double score = areaRatio * 1000 + squarePenalty * 120 + len * 0.02;
        if (score > bestScore) {
          bestScore = score;
          ordered = candidate;
        }
      }
    }

    if (ordered == null || ordered.length != 4) return null;

    // 2) 透视校正 → 正视图
    final cv.VecPoint srcPoints = cv.VecPoint.fromList(ordered);
    const int outSize = 640;
    final cv.VecPoint dstPoints = cv.VecPoint.fromList([
      cv.Point(0, 0),
      cv.Point(outSize, 0),
      cv.Point(outSize, outSize),
      cv.Point(0, outSize),
    ]);
    transformM = cv.getPerspectiveTransform(srcPoints, dstPoints);
    birdsEye = cv.warpPerspective(frame, transformM, (outSize, outSize));

    // 3) 交叉点：等分棋盘得到 19×19 网格，不依赖颜色
    warpedHsv = cv.cvtColor(birdsEye, cv.COLOR_BGR2HSV);
    // 棋子分类尽量保留局部细节，避免把“最后一手标记圈”抹开
    warpedBlur = cv.blur(warpedHsv, (5, 5));

    const int borderPx = 26;
    final int innerH = outSize - 2 * borderPx;
    final int innerW = outSize - 2 * borderPx;
    final double stepY = boardSize > 1 ? innerH / (boardSize - 1) : 0;
    final double stepX = boardSize > 1 ? innerW / (boardSize - 1) : 0;
    final double spacing = stepX < stepY ? stepX : stepY;
    int ringOuterR = (spacing * 0.33).round();
    if (ringOuterR < 3) ringOuterR = 3;
    if (ringOuterR > 10) ringOuterR = 10;
    int ringInnerR = (ringOuterR * 0.42).round();
    if (ringInnerR < 1) ringInnerR = 1;
    if (ringInnerR >= ringOuterR) ringInnerR = ringOuterR - 1;

    final List<List<GoStone?>> board = List.generate(
      boardSize,
      (_) => List.filled(boardSize, null as GoStone?),
    );
    int blackCount = 0;
    int whiteCount = 0;

    // 4) 棋子检测：在每个交叉点局部采样，亮度/HSV 判黑白空
    for (int y = 0; y < boardSize; y++) {
      for (int x = 0; x < boardSize; x++) {
        final int py = (y * stepY).round() + borderPx;
        final int px = (x * stepX).round() + borderPx;
        if (py < 0 || py >= warpedBlur.rows || px < 0 || px >= warpedBlur.cols) {
          continue;
        }
        final _StoneSampleStats stats = _sampleRingHsv(
          warpedHsv,
          px,
          py,
          ringInnerR,
          ringOuterR,
        );
        if (stats.count < 6) {
          continue;
        }
        final List<num> center = warpedHsv.atPixel(py, px);
        final double centerS = center.length >= 2 ? center[1].toDouble() : 0;
        final double centerV = center.length >= 3 ? center[2].toDouble() : 0;

        // 环带评分：以外围主色为准，中心只用于“标记圈/点”纠偏
        double blackScore =
            stats.darkRatio * 1.15 +
            stats.veryDarkRatio * 1.55 +
            ((120 - stats.meanV) / 120).clamp(0.0, 1.0) * 0.75;
        double whiteScore =
            stats.brightNeutralRatio * 1.35 +
            ((stats.meanV - 155) / 100).clamp(0.0, 1.0) * 0.70 +
            ((95 - stats.meanS) / 95).clamp(0.0, 1.0) * 0.35;

        // 黑子中心白圈（最后一手标记）: 外圈偏黑 + 中心偏亮低饱和
        if (stats.darkRatio > 0.42 && centerV > 165 && centerS < 90) {
          blackScore += 0.55;
        }
        // 白子中心黑点（最后一手标记）: 外圈偏白 + 中心偏暗
        if (stats.brightNeutralRatio > 0.42 && centerV < 95) {
          whiteScore += 0.55;
        }

        final bool isBlack = blackScore >= 0.95 && blackScore > whiteScore + 0.12;
        final bool isWhite = whiteScore >= 0.95 && whiteScore > blackScore + 0.12;
        if (isBlack) {
          board[y][x] = GoStone.black;
          blackCount++;
        } else if (isWhite) {
          board[y][x] = GoStone.white;
          whiteCount++;
        }
      }
    }

    return RecognizedBoard(
      boardSize: boardSize,
      board: board,
      blackCount: blackCount,
      whiteCount: whiteCount,
    );
  } catch (_) {
    return null;
  } finally {
    frame?.dispose();
    gray?.dispose();
    blurred?.dispose();
    canny?.dispose();
    birdsEye?.dispose();
    warpedHsv?.dispose();
    warpedBlur?.dispose();
    transformM?.dispose();
  }
}

class _StoneSampleStats {
  const _StoneSampleStats({
    required this.count,
    required this.meanS,
    required this.meanV,
    required this.darkRatio,
    required this.veryDarkRatio,
    required this.brightNeutralRatio,
  });

  final int count;
  final double meanS;
  final double meanV;
  final double darkRatio;
  final double veryDarkRatio;
  final double brightNeutralRatio;
}

_StoneSampleStats _sampleRingHsv(
  cv.Mat hsv,
  int cx,
  int cy,
  int innerR,
  int outerR,
) {
  final int h = hsv.rows;
  final int w = hsv.cols;
  final int inner2 = innerR * innerR;
  final int outer2 = outerR * outerR;

  int count = 0;
  double sumS = 0;
  double sumV = 0;
  int dark = 0;
  int veryDark = 0;
  int brightNeutral = 0;

  for (int dy = -outerR; dy <= outerR; dy++) {
    for (int dx = -outerR; dx <= outerR; dx++) {
      final int d2 = dx * dx + dy * dy;
      if (d2 < inner2 || d2 > outer2) continue;
      final int px = cx + dx;
      final int py = cy + dy;
      if (px < 0 || px >= w || py < 0 || py >= h) continue;
      final List<num> pixel = hsv.atPixel(py, px);
      if (pixel.length < 3) continue;
      final double s = pixel[1].toDouble();
      final double v = pixel[2].toDouble();
      count++;
      sumS += s;
      sumV += v;
      if (v < 85) dark++;
      if (v < 65) veryDark++;
      if (v > 175 && s < 80) brightNeutral++;
    }
  }

  if (count == 0) {
    return const _StoneSampleStats(
      count: 0,
      meanS: 0,
      meanV: 0,
      darkRatio: 0,
      veryDarkRatio: 0,
      brightNeutralRatio: 0,
    );
  }

  return _StoneSampleStats(
    count: count,
    meanS: sumS / count,
    meanV: sumV / count,
    darkRatio: dark / count,
    veryDarkRatio: veryDark / count,
    brightNeutralRatio: brightNeutral / count,
  );
}

class _QuadMetrics {
  const _QuadMetrics({
    required this.area,
    required this.minX,
    required this.maxX,
    required this.minY,
    required this.maxY,
    required this.aspect,
  });

  final double area;
  final int minX;
  final int maxX;
  final int minY;
  final int maxY;
  final double aspect;
}

_QuadMetrics _quadMetrics(List<cv.Point> pts) {
  if (pts.length != 4) {
    return const _QuadMetrics(
      area: 0,
      minX: 0,
      maxX: 0,
      minY: 0,
      maxY: 0,
      aspect: 0,
    );
  }
  final List<int> xs = pts.map((cv.Point p) => p.x).toList();
  final List<int> ys = pts.map((cv.Point p) => p.y).toList();
  final int minX = xs.reduce((int a, int b) => a < b ? a : b);
  final int maxX = xs.reduce((int a, int b) => a > b ? a : b);
  final int minY = ys.reduce((int a, int b) => a < b ? a : b);
  final int maxY = ys.reduce((int a, int b) => a > b ? a : b);
  final double w = (maxX - minX).toDouble().abs();
  final double h = (maxY - minY).toDouble().abs();
  final double aspect = h <= 1e-6 ? 0 : (w / h);
  // Shoelace 多边形面积
  double area2 = 0;
  for (int i = 0; i < 4; i++) {
    final cv.Point a = pts[i];
    final cv.Point b = pts[(i + 1) % 4];
    area2 += (a.x * b.y - b.x * a.y);
  }
  final double area = area2.abs() * 0.5;
  return _QuadMetrics(
    area: area,
    minX: minX,
    maxX: maxX,
    minY: minY,
    maxY: maxY,
    aspect: aspect,
  );
}

/// 四角点顺序：左上、右上、右下、左下，用于透视目标 (0,0),(W,0),(W,H),(0,H)。
List<cv.Point> _orderFourPoints(cv.VecPoint pts) {
  final List<cv.Point> list = pts.toList();
  if (list.length != 4) return list;
  list.sort((cv.Point a, cv.Point b) {
    if (a.y != b.y) return a.y.compareTo(b.y);
    return a.x.compareTo(b.x);
  });
  final cv.Point topLeft = list[0].x < list[1].x ? list[0] : list[1];
  final cv.Point topRight = list[0].x < list[1].x ? list[1] : list[0];
  final cv.Point bottomLeft = list[2].x < list[3].x ? list[2] : list[3];
  final cv.Point bottomRight = list[2].x < list[3].x ? list[3] : list[2];
  return [topLeft, topRight, bottomRight, bottomLeft];
}

class RecognizedBoard {
  const RecognizedBoard({
    required this.boardSize,
    required this.board,
    required this.blackCount,
    required this.whiteCount,
  });

  final int boardSize;
  final List<List<GoStone?>> board;
  final int blackCount;
  final int whiteCount;
}
