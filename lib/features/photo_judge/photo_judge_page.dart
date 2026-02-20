import 'dart:async';
import 'dart:typed_data';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mastergo/domain/entities/analysis_profile.dart';
import 'package:mastergo/domain/entities/game_setup.dart';
import 'package:mastergo/domain/entities/rule_presets.dart';
import 'package:mastergo/domain/go/go_types.dart';
import 'package:mastergo/features/common/go_board_widget.dart';
import 'package:mastergo/features/photo_judge/go_board_recognizer_opencv.dart';
import 'package:mastergo/infra/engine/katago/katago_adapter.dart';
import 'package:mastergo/infra/storage/game_record_repository.dart';

class PhotoJudgePage extends StatefulWidget {
  const PhotoJudgePage({super.key});

  @override
  State<PhotoJudgePage> createState() => _PhotoJudgePageState();
}

class _PhotoJudgePageState extends State<PhotoJudgePage> {
  final ImagePicker _picker = ImagePicker();
  final KatagoAdapter _adapter = PlatformKatagoAdapter();
  final GameRecordRepository _recordRepository = GameRecordRepository();
  final TextRecognizer _textRecognizer = TextRecognizer(
    script: TextRecognitionScript.latin,
  );
  static const AnalysisProfile _analysisProfile = AnalysisProfile(
    id: 'photo-judge',
    name: '拍照判断',
    description: '轻量分析',
    maxVisits: 2,
    thinkingTimeMs: 400,
    includeOwnership: true,
  );
  /// 用 ownership 判断终局：必须所有点 |ownership| 都大于此阈值才是终局。
  static const double _ownershipEndgameThreshold = 0.5;

  XFile? _photo;
  Uint8List? _photoBytes;
  RecognizedBoard? _recognized;
  String _ruleset = 'chinese';
  GoStone _toPlay = GoStone.black;
  bool _loading = false;
  String? _status;
  List<GoPoint> _hintPoints = <GoPoint>[];
  String? _hintSummary;
  String? _judgeText;

  @override
  void dispose() {
    unawaited(_adapter.shutdown());
    _textRecognizer.close();
    super.dispose();
  }

  Future<void> _takePhoto() async {
    final XFile? x = await _picker.pickImage(source: ImageSource.camera);
    if (x == null) {
      return;
    }
    final Uint8List bytes = await x.readAsBytes();
    setState(() {
      _photo = x;
      _photoBytes = bytes;
      _recognized = null;
      _hintPoints = <GoPoint>[];
      _hintSummary = null;
      _judgeText = null;
      _status = '已拍照，正在识别棋盘...';
    });
    await _recognizeBoard();
  }

  Future<void> _pickFromGallery() async {
    final XFile? x = await _picker.pickImage(source: ImageSource.gallery);
    if (x == null) {
      return;
    }
    final Uint8List bytes = await x.readAsBytes();
    setState(() {
      _photo = x;
      _photoBytes = bytes;
      _recognized = null;
      _hintPoints = <GoPoint>[];
      _hintSummary = null;
      _judgeText = null;
      _status = '已选择图片，正在识别棋盘...';
    });
    await _recognizeBoard();
  }

  Future<void> _recognizeBoard() async {
    final Uint8List? bytes = _photoBytes ?? (_photo != null ? await _photo!.readAsBytes() : null);
    if (bytes == null) {
      return;
    }
    if (_photo != null && _photoBytes == null) {
      setState(() => _photoBytes = bytes);
    }
    setState(() {
      _loading = true;
    });
    try {
      final RecognizedBoard? board = recognizeGoBoardFromBytesAutoSize(bytes);
      if (board == null) {
        setState(() {
          _recognized = null;
          _status = '未能检测到棋盘，请确保画面包含完整棋盘并重试';
        });
        return;
      }
      setState(() {
        _recognized = board;
        _status = '识别完成：黑${board.blackCount}，白${board.whiteCount}';
      });
    } catch (e) {
      setState(() {
        _recognized = null;
        _status = '识别失败: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  /// 分析局面：始终基于当前选择的规则（_ruleset）和先后手（_toPlay），
  /// 与拍照/相册时机无关。流程为：拍照识别 → 可选调整规则与先后手 → 点击分析。
  Future<void> _analyzePosition() async {
    final RecognizedBoard? r = _recognized;
    if (r == null) {
      return;
    }
    setState(() {
      _loading = true;
      _status = '正在分析局面...';
      _hintPoints = <GoPoint>[];
      _hintSummary = null;
      _judgeText = null;
    });
    try {
      final List<String> initialStones = <String>[];
      for (int y = 0; y < r.boardSize; y++) {
        for (int x = 0; x < r.boardSize; x++) {
          final GoStone? s = r.board[y][x];
          if (s == null) {
            continue;
          }
          final GoMove m = GoMove(player: s, point: GoPoint(x, y));
          initialStones.add('${s.sgfColor}:${m.toGtp(r.boardSize)}');
        }
      }
      // 使用当前界面选择的规则与先后手，非拍照时固定
      final RulePreset preset = rulePresetFromString(_ruleset);
      final KatagoAnalyzeResult res = await _adapter.analyze(
        KatagoAnalyzeRequest(
          queryId: 'photo-${DateTime.now().millisecondsSinceEpoch}',
          moves: const <String>[],
          initialStones: initialStones,
          gameSetup: GameSetup(
            boardSize: r.boardSize,
            startingPlayer: _toPlay == GoStone.black
                ? StoneColor.black
                : StoneColor.white,
          ),
          rules: preset.toGameRules(),
          profile: _analysisProfile,
          includeOwnership: true,
          timeoutMs: 60000,
        ),
      );
      final double blackWin = res.winrate.clamp(0.0, 1.0);
      final double toPlayWin = _toPlay == GoStone.black
          ? blackWin
          : (1.0 - blackWin);
      final String winner = blackWin >= 0.5 ? '黑优' : '白优';
      final String lead = res.scoreLead >= 0
          ? '黑领先约${res.scoreLead.abs().toStringAsFixed(1)}目'
          : '白领先约${res.scoreLead.abs().toStringAsFixed(1)}目';
      final List<_HintItem> hints = res.topCandidates
          .map(_toHintItem(r.boardSize))
          .whereType<_HintItem>()
          .take(res.topCandidates.length > 1 ? 3 : 1)
          .toList();
      setState(() {
        _hintPoints = hints.map((_HintItem h) => h.point).toList();
        _hintSummary = hints.isEmpty
            ? null
            : hints
                  .map(
                    (_HintItem h) =>
                        '${h.move}:${(h.playerWin * 100).toStringAsFixed(1)}%',
                  )
                  .join('  ');
        final bool likelyEndgame = _isEndgameByOwnership(res.ownership, r.boardSize);
        _judgeText = likelyEndgame
            ? '终局判断：黑子${r.blackCount}，白子${r.whiteCount}；$winner，$lead'
            : '中盘判断：$winner，$lead；当前执棋方胜率${(toPlayWin * 100).toStringAsFixed(1)}%';
        _status = '分析完成';
      });
    } catch (e) {
      setState(() {
        _status = '分析失败: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Future<void> _ocrSequenceAndImport() async {
    final RecognizedBoard? r = _recognized;
    final XFile? photo = _photo;
    if (r == null || photo == null) return;
    if (r.corners.length != 4) {
      setState(() {
        _status = 'OCR失败：棋盘角点不足，无法映射手顺';
      });
      return;
    }
    setState(() {
      _loading = true;
      _status = '正在识别手顺数字...';
    });
    try {
      final InputImage inputImage = InputImage.fromFilePath(photo.path);
      final RecognizedText text = await _textRecognizer.processImage(inputImage);
      final List<_NumberedMove> numberedMoves = <_NumberedMove>[];
      final Set<String> seenNumPoint = <String>{};
      final _Homography? homography = _buildImageToBoardHomography(
        r.corners,
      );
      if (homography == null) {
        setState(() {
          _status = 'OCR失败：角点映射计算失败';
        });
        return;
      }
      for (final TextBlock block in text.blocks) {
        for (final TextLine line in block.lines) {
          for (final TextElement e in line.elements) {
            final String digits = e.text.replaceAll(RegExp(r'[^0-9]'), '');
            if (digits.isEmpty) continue;
            final int? n = int.tryParse(digits);
            if (n == null || n <= 0 || n > 500) continue;
            final Rect box = e.boundingBox;
            final Offset center = Offset(
              (box.left + box.right) * 0.5,
              (box.top + box.bottom) * 0.5,
            );
            final Offset? uv = homography.mapPoint(center);
            if (uv == null) continue;
            final double gx = uv.dx * (r.boardSize - 1);
            final double gy = uv.dy * (r.boardSize - 1);
            final int x = gx.round();
            final int y = gy.round();
            if (x < 0 || x >= r.boardSize || y < 0 || y >= r.boardSize) {
              continue;
            }
            final double dist = math.sqrt((gx - x) * (gx - x) + (gy - y) * (gy - y));
            if (dist > 0.42) {
              continue;
            }
            final String key = '$n:$x:$y';
            if (!seenNumPoint.add(key)) continue;
            numberedMoves.add(
              _NumberedMove(number: n, point: GoPoint(x, y)),
            );
          }
        }
      }
      if (numberedMoves.isEmpty) {
        setState(() {
          _status = '未识别到手顺数字';
        });
        return;
      }
      numberedMoves.sort((_NumberedMove a, _NumberedMove b) => a.number.compareTo(b.number));
      final Set<int> seenNum = <int>{};
      final List<_NumberedMove> uniqByNum = <_NumberedMove>[];
      for (final _NumberedMove m in numberedMoves) {
        if (seenNum.add(m.number)) uniqByNum.add(m);
      }

      int conflictCount = 0;
      final List<GoMove> moves = <GoMove>[];
      for (final _NumberedMove m in uniqByNum) {
        GoStone expected = (m.number % 2 == 1) ? GoStone.black : GoStone.white;
        final GoStone? detected = r.board[m.point.y][m.point.x];
        if (detected != null && detected != expected) {
          expected = detected;
          conflictCount++;
        }
        moves.add(GoMove(player: expected, point: m.point));
      }
      final String sgf = _buildSgfFromMoves(
        boardSize: r.boardSize,
        ruleset: _ruleset,
        komi: rulePresetFromString(_ruleset).defaultKomi,
        moves: moves,
      );
      final int now = DateTime.now().millisecondsSinceEpoch;
      final String title = '拍照OCR手顺-$now';
      await _recordRepository.saveOrUpdateSourceRecord(
        source: 'download',
        title: title,
        boardSize: r.boardSize,
        ruleset: _ruleset,
        komi: rulePresetFromString(_ruleset).defaultKomi,
        sgf: sgf,
      );
      setState(() {
        _status = 'OCR完成：识别手顺${uniqByNum.length}手，冲突修正$conflictCount处，已加入下载棋谱列表';
      });
    } catch (e) {
      setState(() {
        _status = '手顺OCR失败: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  String _buildSgfFromMoves({
    required int boardSize,
    required String ruleset,
    required double komi,
    required List<GoMove> moves,
  }) {
    final StringBuffer sb = StringBuffer();
    sb.write('(;GM[1]FF[4]');
    sb.write('SZ[$boardSize]');
    sb.write('KM[$komi]');
    sb.write('RU[$ruleset]');
    sb.write('PB[Black]');
    sb.write('PW[White]');
    for (final GoMove m in moves) {
      final String c = m.player == GoStone.black ? 'B' : 'W';
      final GoPoint? p = m.point;
      if (p == null) continue;
      sb.write(';$c[${_toSgfCoord(p)}]');
    }
    sb.write(')');
    return sb.toString();
  }

  String _toSgfCoord(GoPoint p) {
    const String letters = 'abcdefghijklmnopqrstuvwxyz';
    return '${letters[p.x]}${letters[p.y]}';
  }

  /// 规则或先后手变更后清除上次分析结果，避免界面显示与当前选择不一致。
  void _clearAnalysisResult() {
    _hintPoints = <GoPoint>[];
    _hintSummary = null;
    _judgeText = null;
    if (_recognized != null && _status == '分析完成') {
      _status = '已识别；请点击「分析局面」按当前规则与先后手重新分析';
    }
  }

  /// 根据引擎返回的 ownership 判断是否终局：必须所有点 |ownership| 都 > 0.5 才是终局。
  bool _isEndgameByOwnership(List<double>? ownership, int boardSize) {
    if (ownership == null || ownership.length < boardSize * boardSize) {
      return false;
    }
    final int total = boardSize * boardSize;
    for (int i = 0; i < total && i < ownership.length; i++) {
      if (ownership[i].abs() <= _ownershipEndgameThreshold) {
        return false;
      }
    }
    return true;
  }

  _HintItem? Function(KatagoMoveCandidate) _toHintItem(int boardSize) {
    return (KatagoMoveCandidate c) {
      final GoPoint? p = _gtpToPoint(c.move, boardSize);
      if (p == null) {
        return null;
      }
      final double playerWin = _toPlay == GoStone.black
          ? c.blackWinrate
          : (1.0 - c.blackWinrate);
      return _HintItem(
        point: p,
        move: c.move,
        playerWin: playerWin.clamp(0.0, 1.0),
      );
    };
  }

  GoPoint? _gtpToPoint(String gtp, int boardSize) {
    if (gtp.toLowerCase() == 'pass' || gtp.length < 2) {
      return null;
    }
    const String columns = 'ABCDEFGHJKLMNOPQRSTUVWXYZ';
    final int x = columns.indexOf(gtp.substring(0, 1).toUpperCase());
    final int row = int.tryParse(gtp.substring(1)) ?? 0;
    if (x < 0 || row <= 0) {
      return null;
    }
    final int y = boardSize - row;
    if (y < 0 || y >= boardSize) {
      return null;
    }
    return GoPoint(x, y);
  }

  @override
  Widget build(BuildContext context) {
    final RecognizedBoard? r = _recognized;
    return Scaffold(
      appBar: AppBar(title: const Text('拍照判断')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: kRulePresets.any((RulePreset p) => p.id == _ruleset)
                      ? _ruleset
                      : kRulePresets.first.id,
                  items: kRulePresets
                      .map(
                        (RulePreset p) => DropdownMenuItem<String>(
                          value: p.id,
                          child: Text(p.label),
                        ),
                      )
                      .toList(),
                  onChanged: (String? v) {
                    if (v != null) {
                      setState(() {
                        _ruleset = v;
                        _clearAnalysisResult();
                      });
                    }
                  },
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: '规则',
                  ),
                  isExpanded: true,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: SegmentedButton<GoStone>(
                  segments: const <ButtonSegment<GoStone>>[
                    ButtonSegment(value: GoStone.black, label: Text('轮到黑')),
                    ButtonSegment(value: GoStone.white, label: Text('轮到白')),
                  ],
                  selected: <GoStone>{_toPlay},
                  onSelectionChanged: (Set<GoStone> s) {
                    setState(() {
                      _toPlay = s.first;
                      _clearAnalysisResult();
                    });
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              FilledButton.icon(
                onPressed: _loading ? null : _takePhoto,
                icon: const Icon(Icons.photo_camera),
                label: const Text('拍照'),
              ),
              OutlinedButton.icon(
                onPressed: _loading ? null : _pickFromGallery,
                icon: const Icon(Icons.photo_library_outlined),
                label: const Text('相册'),
              ),
              OutlinedButton.icon(
                onPressed: (r == null || _loading) ? null : _analyzePosition,
                icon: const Icon(Icons.analytics_outlined),
                label: const Text('分析局面'),
              ),
              OutlinedButton.icon(
                onPressed: (r == null || _loading) ? null : _ocrSequenceAndImport,
                icon: const Icon(Icons.text_snippet_outlined),
                label: const Text('手顺OCR入库'),
              ),
            ],
          ),
          if (_photoBytes != null) ...<Widget>[
            const SizedBox(height: 12),
            const Text('您选择的图片', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Center(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.memory(
                  _photoBytes!,
                  fit: BoxFit.contain,
                  height: 280,
                ),
              ),
            ),
          ],
          if (r != null) ...<Widget>[
            const SizedBox(height: 16),
            const Text('识别结果（棋盘）', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            SizedBox(
              height: 360,
              child: GoBoardWidget(
                boardSize: r.boardSize,
                board: r.board,
                hintPoints: _hintPoints,
              ),
            ),
          ],
          if (_judgeText != null) ...<Widget>[
            const SizedBox(height: 8),
            Text(_judgeText!, maxLines: 3, overflow: TextOverflow.ellipsis),
          ],
          if (_hintSummary != null) ...<Widget>[
            const SizedBox(height: 6),
            Text('提示落子: $_hintSummary', maxLines: 2, overflow: TextOverflow.ellipsis),
          ],
          if (_status != null) ...<Widget>[
            const SizedBox(height: 8),
            Text(_status!, maxLines: 2, overflow: TextOverflow.ellipsis),
          ],
        ],
      ),
    );
  }
}

class _HintItem {
  const _HintItem({
    required this.point,
    required this.move,
    required this.playerWin,
  });

  final GoPoint point;
  final String move;
  final double playerWin;
}

class _NumberedMove {
  const _NumberedMove({required this.number, required this.point});
  final int number;
  final GoPoint point;
}

class _Homography {
  const _Homography(this.a, this.b, this.c, this.d, this.e, this.f, this.g, this.h);
  final double a;
  final double b;
  final double c;
  final double d;
  final double e;
  final double f;
  final double g;
  final double h;

  Offset? mapPoint(Offset p) {
    final double den = g * p.dx + h * p.dy + 1.0;
    if (den.abs() < 1e-9) return null;
    final double u = (a * p.dx + b * p.dy + c) / den;
    final double v = (d * p.dx + e * p.dy + f) / den;
    if (u.isNaN || v.isNaN) return null;
    return Offset(u, v);
  }
}

_Homography? _buildImageToBoardHomography(List<GoPointF> corners) {
  if (corners.length != 4) return null;
  final List<Offset> src = <Offset>[
    Offset(corners[0].x, corners[0].y), // tl
    Offset(corners[1].x, corners[1].y), // tr
    Offset(corners[2].x, corners[2].y), // br
    Offset(corners[3].x, corners[3].y), // bl
  ];
  const List<Offset> dst = <Offset>[
    Offset(0, 0),
    Offset(1, 0),
    Offset(1, 1),
    Offset(0, 1),
  ];

  final List<List<double>> m = List<List<double>>.generate(
    8,
    (_) => List<double>.filled(8, 0),
  );
  final List<double> y = List<double>.filled(8, 0);
  for (int i = 0; i < 4; i++) {
    final double x = src[i].dx;
    final double yy = src[i].dy;
    final double u = dst[i].dx;
    final double v = dst[i].dy;
    // a*x + b*y + c - u*g*x - u*h*y = u
    m[i * 2][0] = x;
    m[i * 2][1] = yy;
    m[i * 2][2] = 1;
    m[i * 2][6] = -u * x;
    m[i * 2][7] = -u * yy;
    y[i * 2] = u;
    // d*x + e*y + f - v*g*x - v*h*y = v
    m[i * 2 + 1][3] = x;
    m[i * 2 + 1][4] = yy;
    m[i * 2 + 1][5] = 1;
    m[i * 2 + 1][6] = -v * x;
    m[i * 2 + 1][7] = -v * yy;
    y[i * 2 + 1] = v;
  }

  final List<double>? sol = _solveLinearSystem8x8(m, y);
  if (sol == null) return null;
  return _Homography(
    sol[0],
    sol[1],
    sol[2],
    sol[3],
    sol[4],
    sol[5],
    sol[6],
    sol[7],
  );
}

List<double>? _solveLinearSystem8x8(List<List<double>> a, List<double> b) {
  const int n = 8;
  final List<List<double>> m = List<List<double>>.generate(
    n,
    (int i) => <double>[...a[i], b[i]],
  );
  for (int col = 0; col < n; col++) {
    int pivot = col;
    double maxAbs = m[col][col].abs();
    for (int r = col + 1; r < n; r++) {
      final double v = m[r][col].abs();
      if (v > maxAbs) {
        maxAbs = v;
        pivot = r;
      }
    }
    if (maxAbs < 1e-10) return null;
    if (pivot != col) {
      final List<double> tmp = m[col];
      m[col] = m[pivot];
      m[pivot] = tmp;
    }
    final double div = m[col][col];
    for (int c = col; c <= n; c++) {
      m[col][c] /= div;
    }
    for (int r = 0; r < n; r++) {
      if (r == col) continue;
      final double factor = m[r][col];
      if (factor.abs() < 1e-12) continue;
      for (int c = col; c <= n; c++) {
        m[r][c] -= factor * m[col][c];
      }
    }
  }
  return List<double>.generate(n, (int i) => m[i][n]);
}
