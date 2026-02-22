import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset;

import 'package:mastergo/domain/go/go_types.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;

const int _maxImageDim = 1280;

enum BoardRecognitionStrategy {
  noClahe,
  withClahe,
}

extension BoardRecognitionStrategyLabel on BoardRecognitionStrategy {
  String get label => this == BoardRecognitionStrategy.noClahe
      ? 'Default (No CLAHE)'
      : 'Alternative (CLAHE)';
}

/// 解码并预缩放大图，降低移动端内存压力。
(Uint8List, int, int)? prepareImageBytes(Uint8List imageBytes) {
  cv.Mat? img;
  try {
    img = cv.imdecode(imageBytes, cv.IMREAD_COLOR);
    int w = img.cols;
    int h = img.rows;
    if (w <= 0 || h <= 0) {
      img.dispose();
      return null;
    }
    if (w > _maxImageDim || h > _maxImageDim) {
      final double scale = _maxImageDim / (w > h ? w : h);
      final int nw = (w * scale).round().clamp(1, 4096);
      final int nh = (h * scale).round().clamp(1, 4096);
      final cv.Mat resized = cv.resize(img, (nw, nh));
      img.dispose();
      img = resized;
      w = nw;
      h = nh;
    }
    final (bool ok, Uint8List out) = cv.imencode('.jpg', img);
    img.dispose();
    if (!ok) return null;
    return (out, w, h);
  } catch (_) {
    img?.dispose();
    return null;
  }
}

List<Offset> defaultBoardCorners(int imgWidth, int imgHeight) {
  const double marginRatio = 0.05;
  final double x0 = imgWidth * marginRatio;
  final double y0 = imgHeight * marginRatio;
  final double x1 = imgWidth - x0;
  final double y1 = imgHeight - y0;
  return <Offset>[
    Offset(x0, y0),
    Offset(x1, y0),
    Offset(x1, y1),
    Offset(x0, y1),
  ];
}

List<Offset>? detectBoardCorners(Uint8List imageBytes) {
  final cv.Mat img = cv.imdecode(imageBytes, cv.IMREAD_COLOR);
  if (img.rows <= 0 || img.cols <= 0) {
    img.dispose();
    return null;
  }
  final double w = img.cols.toDouble();
  final double h = img.rows.toDouble();
  try {
    final List<cv.Point>? pts = _findBoardCornersHSV(img);
    if (pts == null || pts.isEmpty) return null;
    final cv.VecPoint ordered = _orderQuadPoints(pts);
    final List<cv.Point> list = ordered.toList();
    ordered.dispose();
    return list
        .map(
          (cv.Point p) => Offset(
            p.x.toDouble().clamp(0.0, w),
            p.y.toDouble().clamp(0.0, h),
          ),
        )
        .toList();
  } catch (_) {
    return null;
  } finally {
    img.dispose();
  }
}

RecognizedBoard? recognizeGoBoardWithCorners(
  Uint8List imageBytes,
  List<Offset> corners, {
  int boardSize = 19,
  int warpedSize = 760,
  BoardRecognitionStrategy strategy = BoardRecognitionStrategy.noClahe,
}) {
  if (corners.length != 4) return null;
  final cv.Mat img = cv.imdecode(imageBytes, cv.IMREAD_COLOR);
  if (img.rows <= 0 || img.cols <= 0) return null;
  try {
    final cv.VecPoint srcPts = cv.VecPoint.fromList(<cv.Point>[
      cv.Point(corners[0].dx.round(), corners[0].dy.round()),
      cv.Point(corners[1].dx.round(), corners[1].dy.round()),
      cv.Point(corners[2].dx.round(), corners[2].dy.round()),
      cv.Point(corners[3].dx.round(), corners[3].dy.round()),
    ]);
    final cv.VecPoint dstPts = cv.VecPoint.fromList(<cv.Point>[
      cv.Point(0, 0),
      cv.Point(warpedSize, 0),
      cv.Point(warpedSize, warpedSize),
      cv.Point(0, warpedSize),
    ]);
    final cv.Mat h = cv.getPerspectiveTransform(srcPts, dstPts);
    final cv.Mat boardMat = cv.warpPerspective(img, h, (warpedSize, warpedSize));
    h.dispose();
    srcPts.dispose();
    dstPts.dispose();
    img.dispose();

    cv.Mat gray = cv.cvtColor(boardMat, cv.COLOR_BGR2GRAY);
    if (strategy == BoardRecognitionStrategy.withClahe) {
      try {
        final cv.CLAHE clahe = cv.CLAHE.create();
        clahe.clipLimit = 2.0;
        final cv.Mat enhanced = clahe.apply(gray);
        clahe.dispose();
        gray.dispose();
        gray = enhanced;
      } catch (_) {}
    }
    final cv.Mat blurred = cv.gaussianBlur(gray, (7, 7), 1.5);
    gray.dispose();

    final _HoughResult? hough = _recognizeByHoughOtsu(blurred, boardSize, warpedSize);
    blurred.dispose();
    boardMat.dispose();
    if (hough == null) return null;

    return RecognizedBoard(
      boardSize: boardSize,
      board: hough.board,
      blackCount: hough.blackCount,
      whiteCount: hough.whiteCount,
      corners: corners.map((Offset p) => GoPointF(p.dx, p.dy)).toList(),
    );
  } catch (_) {
    img.dispose();
    return null;
  }
}

class _CircleSnap {
  _CircleSnap({
    required this.row,
    required this.col,
    required this.gMean,
    required this.dist,
  });

  final int row;
  final int col;
  final double gMean;
  final double dist;
}

class _HoughResult {
  _HoughResult({
    required this.board,
    required this.blackCount,
    required this.whiteCount,
  });

  final List<List<GoStone?>> board;
  final int blackCount;
  final int whiteCount;
}

_HoughResult? _recognizeByHoughOtsu(
  cv.Mat blurredGray,
  int boardSize,
  int warpedSize,
) {
  final double mar = warpedSize * (20.0 / 760.0);
  final double cell = (warpedSize - mar * 2) / (boardSize - 1);
  final double expectedR = cell * 0.44;
  final int minR = (expectedR * 0.5).round().clamp(4, 80);
  final int maxR = (expectedR * 1.5).round().clamp(minR + 1, 100);
  final double minDist = cell * 0.65;

  final cv.Mat circles = cv.HoughCircles(
    blurredGray,
    cv.HOUGH_GRADIENT,
    1.0,
    minDist,
    param1: 80.0,
    param2: 22.0,
    minRadius: minR,
    maxRadius: maxR,
  );

  if (circles.rows * circles.cols <= 0 || circles.channels < 3) {
    circles.dispose();
    return null;
  }

  final Map<String, _CircleSnap> snaps = <String, _CircleSnap>{};
  final double snapR = cell * 0.70;
  final int total = circles.rows * circles.cols;
  final cv.Mat flat = circles.reshape(1, total);
  for (int i = 0; i < total; i++) {
    final double cx = flat.atF32(i, i1: 0);
    final double cy = flat.atF32(i, i1: 1);
    final double r = flat.atF32(i, i1: 2).abs();

    final int col0 = ((cx - mar) / cell).floor();
    final int row0 = ((cy - mar) / cell).floor();

    double bestDist = 1e18;
    int bestRow = -1;
    int bestCol = -1;
    for (int dr = 0; dr <= 1; dr++) {
      for (int dc = 0; dc <= 1; dc++) {
        final int row = row0 + dr;
        final int col = col0 + dc;
        if (row < 0 || row >= boardSize || col < 0 || col >= boardSize) continue;
        final double gx = mar + col * cell;
        final double gy = mar + row * cell;
        final double d = math.sqrt((cx - gx) * (cx - gx) + (cy - gy) * (cy - gy));
        if (d < bestDist) {
          bestDist = d;
          bestRow = row;
          bestCol = col;
        }
      }
    }
    if (bestRow < 0 || bestDist > snapR) continue;
    final double gMean = _sampleCircleMean(blurredGray, cx, cy, r);
    final String key = '$bestRow:$bestCol';
    final _CircleSnap? prev = snaps[key];
    if (prev == null || bestDist < prev.dist) {
      snaps[key] = _CircleSnap(
        row: bestRow,
        col: bestCol,
        gMean: gMean,
        dist: bestDist,
      );
    }
  }
  flat.dispose();
  circles.dispose();

  if (snaps.isEmpty) return null;

  final double split = _otsuSplit(snaps.values.map((e) => e.gMean).toList());
  final List<List<GoStone?>> board = List<List<GoStone?>>.generate(
    boardSize,
    (_) => List<GoStone?>.filled(boardSize, null),
  );
  int blackCount = 0;
  int whiteCount = 0;
  for (final _CircleSnap s in snaps.values) {
    if (s.gMean < split) {
      board[s.row][s.col] = GoStone.black;
      blackCount++;
    } else {
      board[s.row][s.col] = GoStone.white;
      whiteCount++;
    }
  }
  return _HoughResult(
    board: board,
    blackCount: blackCount,
    whiteCount: whiteCount,
  );
}

double _sampleCircleMean(cv.Mat gray, double cx, double cy, double r) {
  final int rr = (r * 0.60).round().clamp(2, 24);
  double sum = 0;
  int count = 0;
  final int x0 = cx.round();
  final int y0 = cy.round();
  for (int dy = -rr; dy <= rr; dy++) {
    for (int dx = -rr; dx <= rr; dx++) {
      if (dx * dx + dy * dy > rr * rr) continue;
      final int x = x0 + dx;
      final int y = y0 + dy;
      if (x < 0 || y < 0 || x >= gray.cols || y >= gray.rows) continue;
      sum += gray.at<int>(y, x).toDouble();
      count++;
    }
  }
  return count > 0 ? sum / count : 128.0;
}

double _otsuSplit(List<double> values) {
  if (values.length < 2) return 128.0;
  final List<double> arr = List<double>.from(values)..sort();
  double bestVar = -1;
  double best = (arr.first + arr.last) * 0.5;
  for (int t = 0; t < arr.length - 1; t++) {
    final List<double> lo = arr.sublist(0, t + 1);
    final List<double> hi = arr.sublist(t + 1);
    if (lo.isEmpty || hi.isEmpty) continue;
    final double mLo = lo.reduce((double a, double b) => a + b) / lo.length;
    final double mHi = hi.reduce((double a, double b) => a + b) / hi.length;
    final double between = lo.length * hi.length * (mLo - mHi) * (mLo - mHi) / ((lo.length + hi.length) * (lo.length + hi.length));
    if (between > bestVar) {
      bestVar = between;
      best = (arr[t] + arr[t + 1]) * 0.5;
    }
  }
  return best;
}

List<cv.Point>? _findBoardCornersHSV(cv.Mat img) {
  final double scale = 640.0 / img.cols;
  final int smallW = 640;
  final int smallH = (img.rows * scale).round();
  final cv.Mat small = cv.resize(img, (smallW, smallH));
  final cv.Mat hsv = cv.cvtColor(small, cv.COLOR_BGR2HSV);
  small.dispose();

  final cv.Scalar lower = cv.Scalar(10, 15, 100, 0);
  final cv.Scalar upper = cv.Scalar(40, 160, 245, 0);
  final cv.Mat mask = cv.inRangebyScalar(hsv, lower, upper);
  hsv.dispose();

  final cv.Mat kClose = cv.getStructuringElement(cv.MORPH_RECT, (25, 25));
  final cv.Mat closed = cv.morphologyEx(mask, cv.MORPH_CLOSE, kClose);
  mask.dispose();
  kClose.dispose();

  final (cv.Contours contours, _) = cv.findContours(closed, cv.RETR_EXTERNAL, cv.CHAIN_APPROX_SIMPLE);
  closed.dispose();
  if (contours.isEmpty) return null;

  final int imgArea = smallW * smallH;
  double bestScore = -1;
  int bestIdx = -1;
  for (int i = 0; i < contours.length; i++) {
    final double area = cv.contourArea(contours[i]);
    if (area < imgArea * 0.15) continue;
    final cv.RotatedRect rect = cv.minAreaRect(contours[i]);
    final double w = rect.size.width;
    final double h = rect.size.height;
    final double aspect = w > h ? h / w : w / h;
    final double score = aspect * math.sqrt(area / imgArea);
    if (score > bestScore) {
      bestScore = score;
      bestIdx = i;
    }
  }
  if (bestIdx < 0) return null;

  final double peri = cv.arcLength(contours[bestIdx], true);
  for (final double factor in <double>[0.02, 0.03, 0.05, 0.08]) {
    final cv.VecPoint approx = cv.approxPolyDP(contours[bestIdx], peri * factor, true);
    if (approx.length == 4) {
      final List<cv.Point> list = approx.toList();
      approx.dispose();
      return list.map((cv.Point p) => cv.Point((p.x / scale).round(), (p.y / scale).round())).toList();
    }
    approx.dispose();
  }

  final cv.RotatedRect minRect = cv.minAreaRect(contours[bestIdx]);
  final cv.VecPoint2f boxPts = cv.boxPoints(minRect);
  final List<cv.Point2f> pts = boxPts.toList();
  boxPts.dispose();
  return pts.map((cv.Point2f p) => cv.Point((p.x / scale).round(), (p.y / scale).round())).toList();
}

cv.VecPoint _orderQuadPoints(List<cv.Point> pts) {
  final List<cv.Point> list = List<cv.Point>.from(pts);
  list.sort((cv.Point a, cv.Point b) => (a.y + a.x).compareTo(b.y + b.x));
  final cv.Point tl = list[0];
  final cv.Point br = list[3];
  final List<cv.Point> mid = list.sublist(1, 3);
  mid.sort((cv.Point a, cv.Point b) => (a.x - a.y).compareTo(b.x - b.y));
  final cv.Point bl = mid[0];
  final cv.Point tr = mid[1];
  return cv.VecPoint.fromList(<cv.Point>[
    cv.Point(tl.x, tl.y),
    cv.Point(tr.x, tr.y),
    cv.Point(br.x, br.y),
    cv.Point(bl.x, bl.y),
  ]);
}

class RecognizedBoard {
  const RecognizedBoard({
    required this.boardSize,
    required this.board,
    required this.blackCount,
    required this.whiteCount,
    this.corners = const <GoPointF>[],
  });

  final int boardSize;
  final List<List<GoStone?>> board;
  final int blackCount;
  final int whiteCount;
  final List<GoPointF> corners;
}

class GoPointF {
  const GoPointF(this.x, this.y);
  final double x;
  final double y;
}
