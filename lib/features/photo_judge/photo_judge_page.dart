import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mastergo/app/app_i18n.dart';
import 'package:mastergo/domain/entities/analysis_profile.dart';
import 'package:mastergo/domain/entities/game_setup.dart';
import 'package:mastergo/domain/entities/game_rules.dart';
import 'package:mastergo/domain/entities/rule_presets.dart';
import 'package:mastergo/domain/go/go_game.dart';
import 'package:mastergo/domain/go/go_types.dart';
import 'package:mastergo/features/ai_play/ai_play_page.dart';
import 'package:mastergo/features/common/go_board_widget.dart';
import 'package:mastergo/infra/config/ai_profile_repository.dart';
import 'package:mastergo/features/common/ownership_result_sheet.dart';
import 'package:mastergo/features/photo_judge/board_corner_editor.dart';
import 'package:mastergo/features/photo_judge/go_board_recognizer_opencv.dart';
import 'package:mastergo/infra/engine/katago/katago_adapter.dart';
import 'package:mastergo/infra/engine/katago/katago_engine_scope.dart';

class PhotoJudgePage extends StatefulWidget {
  const PhotoJudgePage({super.key});

  @override
  State<PhotoJudgePage> createState() => _PhotoJudgePageState();
}

const AnalysisProfile _photoContinueFallbackProfile = AnalysisProfile(
  id: 'photo-continue',
  name: 'default',
  description: 'default',
  maxVisits: 2,
  thinkingTimeMs: 10000,
  includeOwnership: false,
);

class _PhotoJudgePageState extends State<PhotoJudgePage> {
  final ImagePicker _picker = ImagePicker();
  final AIProfileRepository _profileRepository = AIProfileRepository();
  /// 拍照分析用快速档时间：10s 思考，超时 2×=20s（与原则一致）。
  static const AnalysisProfile _analysisProfile = AnalysisProfile(
    id: 'photo-judge',
    name: 'photo-judge',
    description: 'light-analysis',
    maxVisits: 2,
    thinkingTimeMs: 10000,
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
  int _boardSize = 19;
  AppStrings get _s => AppStrings.of(context);
  KatagoAdapter get _adapter => KatagoEngineScope.of(context);
  String _t({
    required String zh,
    required String en,
    required String ja,
    required String ko,
  }) => _s.pick(zh: zh, en: en, ja: ja, ko: ko);

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
    await _recognizeBoard(preferAlternate: true);
  }

  BoardRecognitionStrategy get _alternateStrategy =>
      _strategy == BoardRecognitionStrategy.noClahe
          ? BoardRecognitionStrategy.withClahe
          : BoardRecognitionStrategy.noClahe;

  Future<void> _recognizeAlternate() async {
    setState(() {
      _strategy = _alternateStrategy;
    });
    await _recognizeBoard(preferAlternate: false);
  }

  Future<void> _recognizeBoard({required bool preferAlternate}) async {
    final Uint8List? preparedBytes = _preparedPhotoBytes;
    final List<Offset>? corners = _calibratedCorners;
    if (preparedBytes == null || corners == null || corners.length != 4) return;
    setState(() {
      _loading = true;
      _clearAnalysisResult();
    });
    try {
      BoardRecognitionStrategy strategy = _strategy;
      RecognizedBoard? board = recognizeGoBoardWithCorners(
        preparedBytes,
        corners,
        boardSize: _boardSize,
        strategy: strategy,
      );
      final bool empty =
          board == null || (board.blackCount + board.whiteCount) == 0;
      if (preferAlternate && empty) {
        final BoardRecognitionStrategy other = strategy == BoardRecognitionStrategy.noClahe
            ? BoardRecognitionStrategy.withClahe
            : BoardRecognitionStrategy.noClahe;
        final RecognizedBoard? alt = recognizeGoBoardWithCorners(
          preparedBytes,
          corners,
          boardSize: _boardSize,
          strategy: other,
        );
        final int altCount = alt == null ? 0 : alt.blackCount + alt.whiteCount;
        final int curCount = board == null ? 0 : board.blackCount + board.whiteCount;
        if (alt != null && altCount > curCount) {
          board = alt;
          strategy = other;
        }
      }
      if (board == null) {
        setState(() {
          _strategy = strategy;
          _recognized = null;
          _status = _t(
            zh: '识别失败，请调整四角后重试',
            en: 'Recognition failed, adjust the four corners and retry',
            ja: '認識失敗。四隅を調整して再試行してください',
            ko: '인식 실패. 네 모서리를 조정한 뒤 다시 시도하세요',
          );
        });
        return;
      }
      final RecognizedBoard recognized = board;
      setState(() {
        _strategy = strategy;
        _recognized = recognized;
        _status = _t(
          zh: '识别完成：黑${recognized.blackCount}，白${recognized.whiteCount}。点交叉点可改错子。',
          en: 'Recognized: B${recognized.blackCount}, W${recognized.whiteCount}. Tap an intersection to fix a stone.',
          ja: '認識完了：黒${recognized.blackCount}、白${recognized.whiteCount}。交点をタップして石を修正できます。',
          ko: '인식 완료: 흑${recognized.blackCount}, 백${recognized.whiteCount}. 교차점을 눌러 돌을 고칠 수 있습니다.',
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
          timeoutMs: 20000,
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
    } on PlatformException catch (e) {
      setState(() {
        _status = e.code == 'ENGINE_TIMEOUT'
            ? _t(
                zh: '分析超时，请选择较低难度或使用性能更好的设备',
                en: 'Analysis timed out. Try a lower difficulty or use a faster device.',
                ja: '解析がタイムアウトしました。難易度を下げるか、性能の良い端末をお試しください。',
                ko: '분석 시간 초과. 난이도를 낮추거나 성능이 좋은 기기를 사용해 보세요.',
              )
            : '${_t(zh: '分析失败', en: 'Analysis failed', ja: '解析失敗', ko: '분석 실패')}: ${e.message ?? e.code}';
      });
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

  void _cycleRecognizedStone(GoPoint p) {
    final RecognizedBoard? r = _recognized;
    if (r == null || _loading) {
      return;
    }
    if (p.x < 0 || p.y < 0 || p.x >= r.boardSize || p.y >= r.boardSize) {
      return;
    }
    final List<List<GoStone?>> next = r.board
        .map((List<GoStone?> row) => List<GoStone?>.from(row))
        .toList();
    final GoStone? current = next[p.y][p.x];
    next[p.y][p.x] = switch (current) {
      null => GoStone.black,
      GoStone.black => GoStone.white,
      GoStone.white => null,
    };
    setState(() {
      _recognized = r.copyWithBoard(next);
      _clearAnalysisResult();
    });
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

  /// 拍照续下：默认中国规则，可选规则与难度；当前玩家先下，下一步 AI 下。
  Future<void> _openContinuePlay() async {
    final RecognizedBoard? r = _recognized;
    if (r == null) return;
    List<AnalysisProfile> profiles = <AnalysisProfile>[];
    try {
      profiles = await _profileRepository.loadProfiles();
    } catch (_) {}
    if (profiles.isEmpty) {
      profiles = <AnalysisProfile>[_photoContinueFallbackProfile];
    }
    int profileIndex = 0;
    String rulesetId = 'chinese';
    if (!mounted) return;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (BuildContext context, void Function(void Function()) setDialogState) {
            return AlertDialog(
              title: Text(
                _t(zh: '续下', en: 'Continue Play', ja: '続き対局', ko: '계속 대국'),
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      _t(zh: '规则', en: 'Rules', ja: 'ルール', ko: '규칙'),
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 4),
                    DropdownButton<String>(
                      value: kRulePresets.any((RulePreset p) => p.id == rulesetId)
                          ? rulesetId
                          : kRulePresets.first.id,
                      isExpanded: true,
                      items: kRulePresets
                          .map(
                            (RulePreset p) => DropdownMenuItem<String>(
                              value: p.id,
                              child: Text(_s.ruleLabel(p.id)),
                            ),
                          )
                          .toList(),
                      onChanged: (String? v) {
                        if (v != null) setDialogState(() => rulesetId = v);
                      },
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _t(zh: 'AI 难度', en: 'AI strength', ja: 'AI強さ', ko: 'AI 난이도'),
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 4),
                    DropdownButton<int>(
                      value: profileIndex.clamp(0, profiles.length - 1),
                      isExpanded: true,
                      items: List<DropdownMenuItem<int>>.generate(
                        profiles.length,
                        (int i) => DropdownMenuItem<int>(
                          value: i,
                          child: Text(
                            _s.aiProfileName(profiles[i].id, profiles[i].name),
                          ),
                        ),
                      ),
                      onChanged: (int? v) {
                        if (v != null) setDialogState(() => profileIndex = v);
                      },
                    ),
                  ],
                ),
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: Text(_t(zh: '取消', en: 'Cancel', ja: 'キャンセル', ko: '취소')),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: Text(_t(zh: '开始', en: 'Start', ja: '開始', ko: '시작')),
                ),
              ],
            );
          },
        );
      },
    );
    if (confirmed != true || !mounted) return;
    final AnalysisProfile profile = profiles[profileIndex.clamp(0, profiles.length - 1)];
    final RulePreset preset = rulePresetFromString(rulesetId);
    final GameRules rules = preset.toGameRules(komi: preset.defaultKomi);
    await AIPlayPage.pushContinuePlay(
      context,
      initialGameState: _stateFromRecognized(r),
      profile: profile,
      rules: rules,
      prefixMoveCount: 0,
    );
  }

  void _changeBoardSize(int size) {
    if (size == _boardSize) {
      return;
    }
    setState(() {
      _boardSize = size;
      _recognized = null;
      _clearAnalysisResult();
    });
    if (_preparedPhotoBytes != null && _calibratedCorners != null) {
      unawaited(_recognizeBoard(preferAlternate: true));
    }
  }

  String _boardSizeLabel(int size) => _t(
        zh: '$size路',
        en: '$size×$size',
        ja: '$size路',
        ko: '$size줄',
      );

  @override
  Widget build(BuildContext context) {
    final RecognizedBoard? r = _recognized;
    final ButtonStyle photoButtonStyle = FilledButton.styleFrom(
      minimumSize: const Size.fromHeight(48),
    );
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: FilledButton.icon(
                onPressed: _loading ? null : _takePhoto,
                style: photoButtonStyle,
                icon: const Icon(Icons.photo_camera),
                label: Text(_t(zh: '拍照', en: 'Camera', ja: '撮影', ko: '촬영')),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _loading ? null : _pickFromGallery,
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
                icon: const Icon(Icons.photo_library_outlined),
                label: Text(_t(zh: '相册', en: 'Gallery', ja: 'アルバム', ko: '앨범')),
              ),
            ),
          ],
        ),
        if (_photoBytes == null && !_loading) ...<Widget>[
          const SizedBox(height: 8),
          Text(
            _t(
              zh: '拍棋盘，或从相册选一张。',
              en: 'Take a board photo, or pick one from the gallery.',
              ja: '盤面を撮るか、アルバムから選んでください。',
              ko: '바둑판을 찍거나 앨범에서 고르세요.',
            ),
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        if (_status != null) ...<Widget>[
          const SizedBox(height: 8),
          Text(_status!, maxLines: 3, overflow: TextOverflow.ellipsis),
        ],
        const SizedBox(height: 16),
        Text(
          _t(zh: '路数', en: 'Board size', ja: '路', ko: '줄수'),
          style: Theme.of(context).textTheme.labelLarge,
        ),
        const SizedBox(height: 8),
        SegmentedButton<int>(
          expandedInsets: EdgeInsets.zero,
          showSelectedIcon: false,
          segments: <int>[9, 13, 19]
              .map(
                (int size) => ButtonSegment<int>(
                  value: size,
                  label: Text(_boardSizeLabel(size)),
                ),
              )
              .toList(),
          selected: <int>{_boardSize},
          onSelectionChanged: _loading
              ? null
              : (Set<int> next) {
                  if (next.isEmpty) {
                    return;
                  }
                  _changeBoardSize(next.first);
                },
        ),
        const SizedBox(height: 16),
        DropdownButtonFormField<String>(
          initialValue: kRulePresets.any((RulePreset p) => p.id == _ruleset)
              ? _ruleset
              : kRulePresets.first.id,
          isExpanded: true,
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
            border: const OutlineInputBorder(),
            labelText: _t(zh: '规则', en: 'Rules', ja: 'ルール', ko: '규칙'),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          _t(zh: '下一步轮到', en: 'To play', ja: '次の手番', ko: '다음 수순'),
          style: Theme.of(context).textTheme.labelLarge,
        ),
        const SizedBox(height: 8),
        SegmentedButton<GoStone>(
          expandedInsets: EdgeInsets.zero,
          showSelectedIcon: false,
          segments: <ButtonSegment<GoStone>>[
            ButtonSegment<GoStone>(
              value: GoStone.black,
              label: Text(_t(zh: '黑', en: 'Black', ja: '黒', ko: '흑')),
            ),
            ButtonSegment<GoStone>(
              value: GoStone.white,
              label: Text(_t(zh: '白', en: 'White', ja: '白', ko: '백')),
            ),
          ],
          selected: <GoStone>{_toPlay},
          onSelectionChanged: _loading
              ? null
              : (Set<GoStone> next) {
                  if (next.isEmpty) {
                    return;
                  }
                  setState(() {
                    _toPlay = next.first;
                    _clearAnalysisResult();
                  });
                },
        ),
        if (r != null) ...<Widget>[
          const SizedBox(height: 20),
          Text(
            _t(
              zh: '识别结果  黑${r.blackCount}  白${r.whiteCount}',
              en: 'Recognized  B${r.blackCount}  W${r.whiteCount}',
              ja: '認識結果  黒${r.blackCount}  白${r.whiteCount}',
              ko: '인식 결과  흑${r.blackCount}  백${r.whiteCount}',
            ),
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            _t(
              zh: '点交叉点可改子：空 → 黑 → 白 → 空',
              en: 'Tap an intersection to fix: empty → black → white → empty',
              ja: '交点をタップして修正：空 → 黒 → 白 → 空',
              ko: '교차점을 눌러 수정: 빈칸 → 흑 → 백 → 빈칸',
            ),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          AspectRatio(
            aspectRatio: 1,
            child: GoBoardStage(
              child: GoBoardWidget(
                boardSize: r.boardSize,
                board: r.board,
                hintPoints: _hintPoints,
                onTapPoint: _loading ? null : _cycleRecognizedStone,
                enableHover: false,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              OutlinedButton(
                onPressed: _loading ? null : _recognizeAlternate,
                child: Text(
                  _t(
                    zh: '换一种识别',
                    en: 'Try another scan',
                    ja: '別の認識',
                    ko: '다른 방식으로 인식',
                  ),
                ),
              ),
              OutlinedButton.icon(
                onPressed: _loading ? null : _analyzePosition,
                icon: const Icon(Icons.analytics_outlined),
                label: Text(
                  _t(zh: '分析局面', en: 'Analyze', ja: '局面分析', ko: '국면 분석'),
                ),
              ),
              FilledButton.icon(
                onPressed: _loading ? null : _openContinuePlay,
                icon: const Icon(Icons.play_arrow, size: 20),
                label: Text(
                  _t(zh: '续下', en: 'Continue', ja: '続き対局', ko: '계속 대국'),
                ),
              ),
            ],
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
