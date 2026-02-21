import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mastergo/domain/entities/analysis_profile.dart';
import 'package:mastergo/domain/entities/game_setup.dart';
import 'package:mastergo/domain/entities/rule_presets.dart';
import 'package:mastergo/domain/go/go_types.dart';
import 'package:mastergo/features/common/go_board_widget.dart';
import 'package:mastergo/features/photo_judge/board_corner_editor.dart';
import 'package:mastergo/features/photo_judge/go_board_recognizer_opencv.dart';
import 'package:mastergo/infra/engine/katago/katago_adapter.dart';

class PhotoJudgePage extends StatefulWidget {
  const PhotoJudgePage({super.key});

  @override
  State<PhotoJudgePage> createState() => _PhotoJudgePageState();
}

class _PhotoJudgePageState extends State<PhotoJudgePage> {
  final ImagePicker _picker = ImagePicker();
  final KatagoAdapter _adapter = PlatformKatagoAdapter();
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
  Uint8List? _preparedPhotoBytes;
  List<Offset>? _calibratedCorners;
  RecognizedBoard? _recognized;
  BoardRecognitionStrategy _strategy = BoardRecognitionStrategy.noClahe;
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
      _preparedPhotoBytes = null;
      _calibratedCorners = null;
      _hintPoints = <GoPoint>[];
      _hintSummary = null;
      _judgeText = null;
      _status = '已拍照，正在校准棋盘...';
    });
    await _calibrateAndRecognize();
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
      _preparedPhotoBytes = null;
      _calibratedCorners = null;
      _hintPoints = <GoPoint>[];
      _hintSummary = null;
      _judgeText = null;
      _status = '已选择图片，正在校准棋盘...';
    });
    await _calibrateAndRecognize();
  }

  Future<void> _calibrateAndRecognize() async {
    final Uint8List? bytes = _photoBytes ?? (_photo != null ? await _photo!.readAsBytes() : null);
    if (bytes == null) return;
    final (Uint8List, int, int)? prepared = prepareImageBytes(bytes);
    if (prepared == null) {
      setState(() {
        _recognized = null;
        _status = '图片解码失败，请重试';
      });
      return;
    }
    final Uint8List preparedBytes = prepared.$1;
    final int imgW = prepared.$2;
    final int imgH = prepared.$3;
    final List<Offset> initialCorners = detectBoardCorners(preparedBytes) ?? defaultBoardCorners(imgW, imgH);
    if (!mounted) return;

    final List<Offset>? pickedCorners = await Navigator.of(context).push<List<Offset>>(
      MaterialPageRoute<List<Offset>>(
        builder: (BuildContext context) => BoardCornerEditorPage(
          imageBytes: preparedBytes,
          imageWidth: imgW,
          imageHeight: imgH,
          initialCorners: initialCorners,
        ),
      ),
    );
    if (!mounted || pickedCorners == null) return;

    setState(() {
      _preparedPhotoBytes = preparedBytes;
      _calibratedCorners = pickedCorners;
      _status = '校准完成，正在识别棋子...';
      _loading = true;
    });
    await _recognizeWithCurrentStrategy();
  }

  Future<void> _recognizeWithCurrentStrategy() async {
    final Uint8List? preparedBytes = _preparedPhotoBytes;
    final List<Offset>? corners = _calibratedCorners;
    if (preparedBytes == null || corners == null || corners.length != 4) return;
    setState(() {
      _loading = true;
      _clearAnalysisResult();
    });
    try {
      final RecognizedBoard? board = recognizeGoBoardWithCorners(
        preparedBytes,
        corners,
        strategy: _strategy,
      );
      if (board == null) {
        setState(() {
          _recognized = null;
          _status = '识别失败，请调整四角或切换策略重试';
        });
        return;
      }
      setState(() {
        _recognized = board;
        _status = '识别完成（${_strategy.label}）：黑${board.blackCount}，白${board.whiteCount}';
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
        final String byPlayer = _toPlay == GoStone.black ? '轮到黑' : '轮到白';
        _status = '分析完成（按$byPlayer计算）';
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
          DropdownButtonFormField<BoardRecognitionStrategy>(
            initialValue: _strategy,
            items: BoardRecognitionStrategy.values
                .map(
                  (BoardRecognitionStrategy s) => DropdownMenuItem<BoardRecognitionStrategy>(
                    value: s,
                    child: Text(s.label),
                  ),
                )
                .toList(),
            onChanged: _loading
                ? null
                : (BoardRecognitionStrategy? s) {
                    if (s == null || s == _strategy) return;
                    setState(() => _strategy = s);
                    if (_preparedPhotoBytes != null && _calibratedCorners != null) {
                      unawaited(_recognizeWithCurrentStrategy());
                    }
                  },
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: '识别策略',
            ),
            isExpanded: true,
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
