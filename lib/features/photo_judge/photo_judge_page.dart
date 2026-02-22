import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mastergo/app/app_i18n.dart';
import 'package:mastergo/domain/entities/analysis_profile.dart';
import 'package:mastergo/domain/entities/game_setup.dart';
import 'package:mastergo/domain/entities/rule_presets.dart';
import 'package:mastergo/domain/go/go_game.dart';
import 'package:mastergo/domain/go/go_types.dart';
import 'package:mastergo/features/common/go_board_widget.dart';
import 'package:mastergo/features/common/ownership_result_sheet.dart';
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
    name: 'photo-judge',
    description: 'light-analysis',
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
  AppStrings get _s => AppStrings.of(context);
  String _t({
    required String zh,
    required String en,
    required String ja,
    required String ko,
  }) => _s.pick(zh: zh, en: en, ja: ja, ko: ko);

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
      _status = _t(
        zh: '已拍照，正在校准棋盘...',
        en: 'Photo captured, calibrating board...',
        ja: '撮影完了、盤補正中...',
        ko: '촬영 완료, 판 보정 중...',
      );
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
      _status = _t(
        zh: '已选择图片，正在校准棋盘...',
        en: 'Image selected, calibrating board...',
        ja: '画像選択完了、盤補正中...',
        ko: '이미지 선택 완료, 판 보정 중...',
      );
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
        _status = _t(
          zh: '图片解码失败，请重试',
          en: 'Image decode failed, try again',
          ja: '画像デコード失敗、再試行してください',
          ko: '이미지 디코딩 실패, 다시 시도하세요',
        );
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
      _status = _t(
        zh: '校准完成，正在识别棋子...',
        en: 'Calibration done, recognizing stones...',
        ja: '補正完了、石認識中...',
        ko: '보정 완료, 돌 인식 중...',
      );
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
          _status = _t(
            zh: '识别失败，请调整四角或切换策略重试',
            en: 'Recognition failed, adjust corners or switch strategy',
            ja: '認識失敗。四隅調整または戦略変更で再試行',
            ko: '인식 실패. 모서리 조정/전략 변경 후 재시도',
          );
        });
        return;
      }
      setState(() {
        _recognized = board;
        _status = _t(
          zh: '识别完成（${_strategy.label}）：黑${board.blackCount}，白${board.whiteCount}',
          en: 'Recognition complete (${_strategyLabel(_strategy)}): B${board.blackCount}, W${board.whiteCount}',
          ja: '認識完了（${_strategyLabel(_strategy)}）：黒${board.blackCount}、白${board.whiteCount}',
          ko: '인식 완료(${_strategyLabel(_strategy)}): 흑${board.blackCount}, 백${board.whiteCount}',
        );
      });
    } catch (e) {
      setState(() {
        _recognized = null;
        _status = '${_t(zh: '识别失败', en: 'Recognition failed', ja: '認識失敗', ko: '인식 실패')}: $e';
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
      _status = _t(
        zh: '正在分析局面...',
        en: 'Analyzing position...',
        ja: '局面解析中...',
        ko: '형세 분석 중...',
      );
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
      final String winner = blackWin >= 0.5
          ? _t(zh: '黑优', en: 'Black better', ja: '黒優勢', ko: '흑 우세')
          : _t(zh: '白优', en: 'White better', ja: '白優勢', ko: '백 우세');
      final String lead = res.scoreLead >= 0
          ? _t(
              zh: '黑领先约${res.scoreLead.abs().toStringAsFixed(1)}目',
              en: 'Black leads by ${res.scoreLead.abs().toStringAsFixed(1)}',
              ja: '黒が約${res.scoreLead.abs().toStringAsFixed(1)}目リード',
              ko: '흑 약 ${res.scoreLead.abs().toStringAsFixed(1)}집 우세',
            )
          : _t(
              zh: '白领先约${res.scoreLead.abs().toStringAsFixed(1)}目',
              en: 'White leads by ${res.scoreLead.abs().toStringAsFixed(1)}',
              ja: '白が約${res.scoreLead.abs().toStringAsFixed(1)}目リード',
              ko: '백 약 ${res.scoreLead.abs().toStringAsFixed(1)}집 우세',
            );
      final List<_HintItem> hints = res.topCandidates
          .map(_toHintItem(r.boardSize))
          .whereType<_HintItem>()
          .take(res.topCandidates.length > 1 ? 3 : 1)
          .toList();
      final GoGameState analysisState = _stateFromRecognized(r);
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
            ? _t(
                zh: '终局判断：黑子${r.blackCount}，白子${r.whiteCount}；$winner，$lead',
                en: 'Endgame: B${r.blackCount}, W${r.whiteCount}; $winner, $lead',
                ja: '終局判定：黒${r.blackCount}、白${r.whiteCount}；$winner、$lead',
                ko: '종국 판정: 흑${r.blackCount}, 백${r.whiteCount}; $winner, $lead',
              )
            : _t(
                zh: '中盘判断：$winner，$lead；当前执棋方胜率${(toPlayWin * 100).toStringAsFixed(1)}%',
                en: 'Middlegame: $winner, $lead; side-to-play winrate ${(toPlayWin * 100).toStringAsFixed(1)}%',
                ja: '中盤判定：$winner、$lead；手番側勝率 ${(toPlayWin * 100).toStringAsFixed(1)}%',
                ko: '중반 판정: $winner, $lead; 현재 차례 승률 ${(toPlayWin * 100).toStringAsFixed(1)}%',
              );
        final String byPlayer = _toPlay == GoStone.black
            ? _t(zh: '轮到黑', en: 'Black to play', ja: '黒番', ko: '흑 차례')
            : _t(zh: '轮到白', en: 'White to play', ja: '白番', ko: '백 차례');
        _status = _t(
          zh: '分析完成（按$byPlayer计算）',
          en: 'Analysis complete ($byPlayer)',
          ja: '解析完了（$byPlayer）',
          ko: '분석 완료($byPlayer)',
        );
      });
      if (mounted) {
        showOwnershipResultSheet(context, analysisState, res);
      }
    } catch (e) {
      setState(() {
        _status = '${_t(zh: '分析失败', en: 'Analysis failed', ja: '解析失敗', ko: '분석 실패')}: $e';
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
    if (_recognized != null &&
        _status == _t(zh: '分析完成', en: 'Analysis complete', ja: '解析完了', ko: '분석 완료')) {
      _status = _t(
        zh: '已识别；请点击「分析局面」按当前规则与先后手重新分析',
        en: 'Recognized. Tap Analyze with current rules and side-to-play.',
        ja: '認識済み。現在の条件で再解析してください。',
        ko: '인식 완료. 현재 규칙/차례로 다시 분석하세요.',
      );
    }
  }

  String _strategyLabel(BoardRecognitionStrategy strategy) {
    if (strategy == BoardRecognitionStrategy.noClahe) {
      return _t(
        zh: '默认（无CLAHE）',
        en: 'Default (No CLAHE)',
        ja: '標準（CLAHEなし）',
        ko: '기본(CLAHE 없음)',
      );
    }
    return _t(
      zh: '额外策略（CLAHE）',
      en: 'Alternative (CLAHE)',
      ja: '追加戦略（CLAHE）',
      ko: '추가 전략(CLAHE)',
    );
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

  GoGameState _stateFromRecognized(RecognizedBoard board) {
    return GoGameState(
      boardSize: board.boardSize,
      board: board.board
          .map((List<GoStone?> row) => List<GoStone?>.from(row))
          .toList(),
      toPlay: _toPlay,
    );
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
      appBar: AppBar(title: Text(_s.tabPhotoJudge)),
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
                          child: Text(_s.ruleLabel(p.id)),
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
                  decoration: InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: _t(zh: '规则', en: 'Rules', ja: 'ルール', ko: '규칙'),
                  ),
                  isExpanded: true,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      _t(zh: '下一步轮到', en: 'Next Step', ja: '次の手番', ko: '다음 수순'),
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: <Widget>[
                          _stoneWithLabel(
                            stone: GoStone.black,
                            label: _t(zh: '黑', en: 'Black', ja: '黒', ko: '흑'),
                            selected: _toPlay == GoStone.black,
                          ),
                          Switch.adaptive(
                            value: _toPlay == GoStone.white,
                            activeTrackColor: Theme.of(
                              context,
                            ).colorScheme.surfaceContainerHighest,
                            inactiveTrackColor: Theme.of(
                              context,
                            ).colorScheme.surfaceContainerHighest,
                            thumbColor: WidgetStateProperty.resolveWith<Color>((Set<WidgetState> states) {
                              return states.contains(WidgetState.selected)
                                  ? Colors.white
                                  : Colors.black;
                            }),
                            onChanged: _loading
                                ? null
                                : (bool whiteTurn) {
                                    setState(() {
                                      _toPlay = whiteTurn ? GoStone.white : GoStone.black;
                                      _clearAnalysisResult();
                                    });
                                  },
                          ),
                          _stoneWithLabel(
                            stone: GoStone.white,
                            label: _t(zh: '白', en: 'White', ja: '白', ko: '백'),
                            selected: _toPlay == GoStone.white,
                          ),
                        ],
                      ),
                    ),
                  ],
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
                    child: Text(_strategyLabel(s)),
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
            decoration: InputDecoration(
              border: OutlineInputBorder(),
              labelText: _t(zh: '识别策略', en: 'Strategy', ja: '認識戦略', ko: '인식 전략'),
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
                label: Text(_t(zh: '拍照', en: 'Camera', ja: '撮影', ko: '촬영')),
              ),
              OutlinedButton.icon(
                onPressed: _loading ? null : _pickFromGallery,
                icon: const Icon(Icons.photo_library_outlined),
                label: Text(_t(zh: '相册', en: 'Gallery', ja: 'アルバム', ko: '앨범')),
              ),
            ],
          ),
          if (_photoBytes != null) ...<Widget>[
            const SizedBox(height: 12),
            Text(
              _t(zh: '您选择的图片', en: 'Selected Image', ja: '選択画像', ko: '선택한 이미지'),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
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
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    _t(
                      zh: '识别结果（棋盘） 黑${r.blackCount} 白${r.whiteCount}',
                      en: 'Recognition (board) B${r.blackCount} W${r.whiteCount}',
                      ja: '認識結果（盤） 黒${r.blackCount} 白${r.whiteCount}',
                      ko: '인식 결과(판) 흑${r.blackCount} 백${r.whiteCount}',
                    ),
                    style: const TextStyle(fontWeight: FontWeight.w600),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: _loading ? null : _analyzePosition,
                  icon: const Icon(Icons.analytics_outlined),
                  label: Text(_t(zh: '分析局面', en: 'Analyze', ja: '局面分析', ko: '국면 분석')),
                ),
              ],
            ),
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
            Text(
              _t(
                zh: '提示落子: $_hintSummary',
                en: 'Suggested moves: $_hintSummary',
                ja: '候補手: $_hintSummary',
                ko: '추천 수: $_hintSummary',
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          if (_status != null) ...<Widget>[
            const SizedBox(height: 8),
            Text(_status!, maxLines: 2, overflow: TextOverflow.ellipsis),
          ],
        ],
      ),
    );
  }

  Widget _stoneWithLabel({
    required GoStone stone,
    required String label,
    required bool selected,
  }) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final Color textColor = selected ? cs.onSurface : cs.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          width: 16,
          height: 16,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: stone == GoStone.black ? Colors.black : Colors.white,
            border: Border.all(color: Colors.black26),
          ),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            color: textColor,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ],
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
