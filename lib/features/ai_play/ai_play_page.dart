import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mastergo/application/analysis/game_analysis_service.dart';
import 'package:mastergo/domain/entities/analysis_profile.dart';
import 'package:mastergo/domain/entities/game_rules.dart';
import 'package:mastergo/domain/entities/rule_presets.dart';
import 'package:mastergo/domain/entities/game_setup.dart';
import 'package:mastergo/domain/entities/game_record.dart';
import 'package:mastergo/domain/go/go_game.dart';
import 'package:mastergo/domain/go/go_types.dart';
import 'package:mastergo/features/common/go_board_widget.dart';
import 'package:mastergo/features/common/ownership_result_sheet.dart';
import 'package:mastergo/features/common/review_board_panel.dart';
import 'package:mastergo/features/common/winrate_chart.dart';
import 'package:mastergo/infra/config/ai_profile_repository.dart';
import 'package:mastergo/infra/engine/katago/katago_adapter.dart';
import 'package:mastergo/infra/sound/stone_sound.dart';
import 'package:mastergo/infra/storage/game_record_repository.dart';

class AIPlayPage extends StatefulWidget {
  const AIPlayPage({super.key});

  @override
  State<AIPlayPage> createState() => _AIPlayPageState();
}

class _AIPlayPageState extends State<AIPlayPage> {
  final AIProfileRepository _profileRepository = AIProfileRepository();
  final KatagoAdapter _katagoAdapter = PlatformKatagoAdapter();
  final List<int> _boardSizes = <int>[9, 13, 19];
  final List<AnalysisProfile> _profilesCache = <AnalysisProfile>[];

  int _boardSize = 19;
  int _handicap = 0;
  bool _guessFirst = true;
  String _selectedRulesetId = 'chinese';
  String? _selectedProfileId;

  @override
  void dispose() {
    unawaited(_katagoAdapter.shutdown());
    super.dispose();
  }

  AnalysisProfile? get _activeProfile {
    if (_profilesCache.isEmpty) {
      return null;
    }
    for (final AnalysisProfile p in _profilesCache) {
      if (p.id == _selectedProfileId) {
        return p;
      }
    }
    return _profilesCache.first;
  }

  RulePreset get _activeRulePreset => rulePresetFromString(_selectedRulesetId);

  Future<void> _startBattle(AnalysisProfile profile) async {
    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => _AIBattlePage(
          adapter: _katagoAdapter,
          profile: profile,
          boardSize: _boardSize,
          handicap: _handicap,
          randomFirst: _guessFirst,
          rules: _activeRulePreset.toGameRules(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<AnalysisProfile>>(
      future: _profileRepository.loadProfiles(),
      builder:
          (BuildContext context, AsyncSnapshot<List<AnalysisProfile>> snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snap.hasError) {
              return Center(child: Text('加载难度配置失败: ${snap.error}'));
            }
            final List<AnalysisProfile> profiles =
                snap.data ?? <AnalysisProfile>[];
            _profilesCache
              ..clear()
              ..addAll(profiles);
            if (_selectedProfileId == null && profiles.isNotEmpty) {
              _selectedProfileId = profiles.first.id;
            }
            final AnalysisProfile? selected = _activeProfile;
            return ListView(
              padding: const EdgeInsets.all(16),
              children: <Widget>[
                Text('AI 对弈', style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 12),
                DropdownButtonFormField<int>(
                  initialValue: _boardSize,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: '棋盘尺寸',
                  ),
                  items: _boardSizes.map((int s) {
                    return DropdownMenuItem<int>(
                      value: s,
                      child: Text('$s x $s'),
                    );
                  }).toList(),
                  onChanged: (int? size) {
                    if (size != null) {
                      setState(() {
                        _boardSize = size;
                      });
                    }
                  },
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: selected?.id,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: '难度',
                  ),
                  items: profiles.map((AnalysisProfile p) {
                    return DropdownMenuItem<String>(
                      value: p.id,
                      child: Text(p.name),
                    );
                  }).toList(),
                  onChanged: (String? id) {
                    setState(() {
                      _selectedProfileId = id;
                    });
                  },
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _selectedRulesetId,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: '规则',
                  ),
                  items: kRulePresets
                      .map(
                        (RulePreset p) => DropdownMenuItem<String>(
                          value: p.id,
                          child: Text('${p.label} (KM ${p.defaultKomi})'),
                        ),
                      )
                      .toList(),
                  onChanged: (String? value) {
                    if (value == null) {
                      return;
                    }
                    setState(() {
                      _selectedRulesetId = value;
                    });
                  },
                ),
                const SizedBox(height: 12),
                Slider(
                  value: _handicap.toDouble(),
                  max: 9,
                  divisions: 9,
                  label: '$_handicap',
                  onChanged: (double value) {
                    setState(() {
                      _handicap = value.toInt();
                    });
                  },
                ),
                Text('AI让子给你: $_handicap'),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('猜先（随机先后）'),
                  subtitle: Text(
                    _handicap > 0 ? '让子局固定你执黑（猜先不生效）' : '开启后随机分配你执黑或执白',
                  ),
                  value: _guessFirst,
                  onChanged: _handicap > 0
                      ? null
                      : (bool value) {
                          setState(() {
                            _guessFirst = value;
                          });
                        },
                ),
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed: selected == null
                      ? null
                      : () => _startBattle(selected),
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('开始对弈'),
                ),
                if (selected != null) ...<Widget>[
                  const SizedBox(height: 16),
                  Card(
                    child: ListTile(
                      title: Text(selected.name),
                      subtitle: Text(selected.description),
                      trailing: Text('Visits ${selected.maxVisits}'),
                    ),
                  ),
                ],
              ],
            );
          },
    );
  }
}

class _AIBattlePage extends StatefulWidget {
  const _AIBattlePage({
    required this.adapter,
    required this.profile,
    required this.boardSize,
    required this.handicap,
    required this.randomFirst,
    required this.rules,
  });

  final KatagoAdapter adapter;
  final AnalysisProfile profile;
  final int boardSize;
  final int handicap;
  final bool randomFirst;
  final GameRules rules;

  @override
  State<_AIBattlePage> createState() => _AIBattlePageState();
}

class _AIBattlePageState extends State<_AIBattlePage> {
  static const bool _requireDoubleTapConfirm = true;
  final GameAnalysisService _analysisService = const GameAnalysisService();
  final GameRecordRepository _recordRepository = GameRecordRepository();
  String? _recordId;
  int? _recordCreatedAtMs;
  late GameRules _rules;
  GoGameState? _game;
  final List<GoGameState> _history = <GoGameState>[];
  List<GoPoint> _handicapStones = <GoPoint>[];
  GoScore? _finalScore;
  /// 终局结果文案，仅由局势分析（winrate/scoreLead）得出；不拿数目判断胜负。
  String? _finalResultTextFromAnalysis;
  String? _resignResultText;
  GoPoint? _pendingPoint;
  GoStone _playerStone = GoStone.black;
  GoStone _aiStone = GoStone.white;
  bool _tryMode = false;
  GoGameState? _tryBaseState;
  String? _tryBaseStatus;
  List<GoPoint> _hintPoints = <GoPoint>[];
  String? _hintSummary;
  bool _aiThinking = false;
  bool _restoring = true;
  bool _engineReady = false;
  String _status = '准备中...';
  double? _blackWinrate;
  final Map<int, double> _winrateByTurn = <int, double>{};

  double? get _playerWinrate {
    if (_blackWinrate == null) {
      return null;
    }
    return _playerStone == GoStone.black
        ? _blackWinrate
        : (1.0 - _blackWinrate!);
  }

  Duration _blackBase = Duration.zero;
  Duration _whiteBase = Duration.zero;
  GoStone? _activeClockStone;
  DateTime? _activeClockStartedAt;
  Timer? _ticker;

  int _timeoutBudgetMs() {
    return _timeoutBudgetMsForProfile(widget.profile);
  }

  int _timeoutBudgetMsForProfile(AnalysisProfile profile) {
    if (profile.maxVisits >= 60 || profile.id == 'master') {
      return max(120000, profile.thinkingTimeMs * 24);
    }
    return max(
      12000,
      max(profile.thinkingTimeMs * 10, profile.maxVisits * 900),
    );
  }

  AnalysisProfile _effectiveProfileForTurn(int moveCount) {
    final AnalysisProfile p = widget.profile;
    if (p.maxVisits < 30) {
      return p;
    }
    int effectiveVisits = p.maxVisits;
    if (moveCount < 6) {
      effectiveVisits = min(effectiveVisits, 10);
    } else if (moveCount < 14) {
      effectiveVisits = min(effectiveVisits, 20);
    } else if (moveCount < 24) {
      effectiveVisits = min(effectiveVisits, 30);
    }
    if (effectiveVisits == p.maxVisits) {
      return p;
    }
    return AnalysisProfile(
      id: '${p.id}-opening-$effectiveVisits',
      name: p.name,
      description: p.description,
      maxVisits: effectiveVisits,
      thinkingTimeMs: min(p.thinkingTimeMs, 1000),
      includeOwnership: p.includeOwnership,
    );
  }

  @override
  void initState() {
    super.initState();
    _rules = widget.handicap > 0
        ? widget.rules.copyWith(komi: 0)
        : widget.rules;
    _initializeGame();
    _restoring = false;
    unawaited(_bootstrapSession());
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _freezeActiveClock();
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _bootstrapSession() async {
    final bool restored = await _restoreSession();
    if (!mounted) return;
    if (restored) {
      setState(() {});
    }
    unawaited(_ensureEngineThenMaybeAi());
  }

  Future<void> _ensureEngineThenMaybeAi() async {
    try {
      await widget.adapter.ensureStarted();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _engineReady = true;
    });
    if (_game != null && !_isGameOver && _game!.toPlay == _aiStone) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          unawaited(_aiMove());
        }
      });
    }
  }

  void _initializeGame() {
    _recordId = null;
    _recordCreatedAtMs = null;
    if (widget.handicap > 0) {
      // Handicap means AI gives stones to player, so player is fixed to black.
      _playerStone = GoStone.black;
    } else {
      _playerStone = widget.randomFirst && Random().nextBool()
          ? GoStone.white
          : GoStone.black;
    }
    _aiStone = _playerStone.opposite();

    final List<GoPoint> handicap = _buildHandicapPoints(
      widget.boardSize,
      widget.handicap,
    );
    final List<List<GoStone?>> board = List<List<GoStone?>>.generate(
      widget.boardSize,
      (_) => List<GoStone?>.filled(widget.boardSize, null),
    );
    for (final GoPoint p in handicap) {
      board[p.y][p.x] = GoStone.black;
    }
    final GoStone toPlay = handicap.isEmpty ? GoStone.black : GoStone.white;

    final GoGameState initial = GoGameState(
      boardSize: widget.boardSize,
      board: board,
      toPlay: toPlay,
    );
    _history
      ..clear()
      ..add(initial);
    _game = initial;
    _handicapStones = handicap;
    _finalScore = null;
    _finalResultTextFromAnalysis = null;
    _resignResultText = null;
    _pendingPoint = null;
    _blackWinrate = null;
    _winrateByTurn.clear();
    _hintSummary = null;
    _blackBase = Duration.zero;
    _whiteBase = Duration.zero;
    _activeClockStone = null;
    _activeClockStartedAt = null;
    _startClockFor(toPlay);
    _status = widget.handicap > 0
        ? '${_handicapLabel}，贴目${_rules.komi.toStringAsFixed(1)}，你执黑，${toPlay == _playerStone ? '请落子' : 'AI先行'}'
        : '$_handicapLabel，你执${_playerStone == GoStone.black ? '黑' : '白'}，${toPlay == _playerStone ? '请落子' : 'AI先行'}';

    unawaited(_persistSession());
  }

  void _freezeActiveClock() {
    if (_activeClockStone == null || _activeClockStartedAt == null) {
      return;
    }
    final Duration delta = DateTime.now().difference(_activeClockStartedAt!);
    if (_activeClockStone == GoStone.black) {
      _blackBase += delta;
    } else {
      _whiteBase += delta;
    }
    _activeClockStartedAt = null;
  }

  void _startClockFor(GoStone stone) {
    _freezeActiveClock();
    _activeClockStone = stone;
    _activeClockStartedAt = DateTime.now();
  }

  Duration _clockValue(GoStone stone) {
    Duration base = stone == GoStone.black ? _blackBase : _whiteBase;
    if (_activeClockStone == stone && _activeClockStartedAt != null) {
      base += DateTime.now().difference(_activeClockStartedAt!);
    }
    return base;
  }

  String _fmtDuration(Duration d) {
    final int total = d.inSeconds;
    final int mm = total ~/ 60;
    final int ss = total % 60;
    return '${mm.toString().padLeft(2, '0')}:${ss.toString().padLeft(2, '0')}';
  }

  Future<void> _onBoardTap(GoPoint point) async {
    if (_game == null || _aiThinking || _isGameOver) {
      return;
    }
    if (_tryMode) {
      try {
        final GoGameState next = _game!.play(
          GoMove(player: _game!.toPlay, point: point),
        );
        setState(() {
          _game = next;
          _pendingPoint = null;
          _hintPoints = <GoPoint>[];
          _hintSummary = null;
          _status = '试下中（黑白皆可走）';
        });
      } catch (_) {
        setState(() {
          _status = '试下非法落子';
        });
      }
      return;
    }
    if (_game!.toPlay != _playerStone) {
      return;
    }
    final GoMove probe = GoMove(player: _playerStone, point: point);
    try {
      _game!.play(probe);
    } catch (_) {
      setState(() {
        _status = '非法落子，请重新选择';
        _pendingPoint = null;
      });
      return;
    }

    if (_requireDoubleTapConfirm && _pendingPoint != point) {
      setState(() {
        _pendingPoint = point;
        _status = '再次点击同一位置确认落子';
      });
      return;
    }

    final GoGameState next = _game!.play(probe);
    playStoneSound();
    setState(() {
      _applyGame(next);
      _pendingPoint = null;
      _hintPoints = <GoPoint>[];
      _hintSummary = null;
      _status = '你已落子，AI思考中...';
    });
    unawaited(_persistSession());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(_aiMove());
      }
    });
  }

  Future<void> _playerPass() async {
    if (_game == null || _aiThinking || _isGameOver) {
      return;
    }
    if (_tryMode) {
      setState(() {
        _game = _game!.play(GoMove(player: _game!.toPlay, isPass: true));
        _status = '试下中：pass';
      });
      return;
    }
    if (_game!.toPlay != _playerStone) {
      return;
    }
    final GoGameState next = _game!.play(
      GoMove(player: _playerStone, isPass: true),
    );
    setState(() {
      _applyGame(next);
      _pendingPoint = null;
      _status = '你选择了 pass';
    });
    unawaited(_persistSession());
    _maybeFinishGame();
    if (_finalScore == null) {
      await _aiMove();
    }
  }

  Future<void> _aiMove() async {
    if (_game == null || _game!.toPlay != _aiStone || _isGameOver || _tryMode) {
      return;
    }
    if (!_engineReady) {
      try {
        await widget.adapter.ensureStarted();
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _engineReady = true;
      });
    }
    final AnalysisProfile effectiveProfile = _effectiveProfileForTurn(
      _game!.moves.length,
    );
    setState(() {
      _aiThinking = true;
      _pendingPoint = null;
      _hintPoints = <GoPoint>[];
      _hintSummary = null;
      _status = effectiveProfile.maxVisits < widget.profile.maxVisits
          ? 'AI布局快速思考中（V${effectiveProfile.maxVisits}）...'
          : ((widget.profile.maxVisits >= 60 || widget.profile.id == 'master')
                ? 'AI大师思考中（可能较久）...'
                : 'AI思考中...');
    });
    try {
      final List<String> moveTokens = _game!.moves
          .map((GoMove m) => m.toProtocolToken(widget.boardSize))
          .toList();
      final List<String> initialTokens = _handicapStones
          .map(
            (GoPoint p) =>
                'B:${GoMove(player: GoStone.black, point: p).toGtp(widget.boardSize)}',
          )
          .toList();

      final KatagoAnalyzeResult analyzed = await widget.adapter.analyze(
        KatagoAnalyzeRequest(
          queryId: DateTime.now().millisecondsSinceEpoch.toString(),
          moves: moveTokens,
          initialStones: initialTokens,
          gameSetup: GameSetup(
            boardSize: widget.boardSize,
            startingPlayer: _game!.toPlay == GoStone.black
                ? StoneColor.black
                : StoneColor.white,
          ),
          rules: _rules,
          profile: effectiveProfile,
          timeoutMs: _timeoutBudgetMsForProfile(effectiveProfile),
        ),
      );

      // Normalize BLACK-perspective winrate with scoreLead consistency check.
      _blackWinrate = _normalizeBlackWinrate(
        analyzed.winrate,
        analyzed.scoreLead,
      );
      _winrateByTurn[_game!.moves.length] = _blackWinrate!;

      final double aiWinrate = _aiStone == GoStone.black
          ? _blackWinrate!
          : (1.0 - _blackWinrate!);
      if (_shouldAiResign(aiWinrate)) {
        setState(() {
          _freezeActiveClock();
          _resignResultText = 'AI认输，你胜';
          _status = _resignResultText!;
        });
        unawaited(_persistSession());
        return;
      }

      final GoPoint? aiPoint = _gtpToPoint(analyzed.bestMove, widget.boardSize);
      GoGameState next = _game!;
      if (aiPoint != null) {
        try {
          next = next.play(GoMove(player: _aiStone, point: aiPoint));
          playStoneSound();
        } catch (_) {
          final List<GoPoint> legal = next
              .legalMovesForCurrentPlayer()
              .toList();
          if (legal.isNotEmpty) {
            final GoPoint fallback = legal[Random().nextInt(legal.length)];
            next = next.play(GoMove(player: _aiStone, point: fallback));
            playStoneSound();
          } else {
            next = next.play(GoMove(player: _aiStone, isPass: true));
          }
        }
      } else {
        next = next.play(GoMove(player: _aiStone, isPass: true));
      }

      setState(() {
        _applyGame(next);
        _status = 'AI落子完成，轮到你';
      });
      unawaited(_persistSession());
      _maybeFinishGame();
    } on PlatformException catch (e) {
      final String details = e.details?.toString() ?? '';
      setState(() {
        _status =
            'AI分析失败: [${e.code}] ${e.message ?? ''} ${details.isEmpty ? '' : '| $details'}';
      });
    } finally {
      if (mounted) {
        setState(() {
          _aiThinking = false;
        });
      }
    }
  }

  void _applyGame(GoGameState state) {
    _game = state;
    _history.add(state);
    _startClockFor(state.toPlay);
  }

  void _maybeFinishGame() {
    if (_game == null) {
      return;
    }
    if (_game!.consecutivePasses >= 2) {
      _freezeActiveClock();
      unawaited(_finishGameWithOwnership());
    }
  }

  /// 终局时用局势分析（winrate/scoreLead）判定胜负，数目仅用于显示黑地/白地。
  Future<void> _finishGameWithOwnership() async {
    if (_game == null || _game!.consecutivePasses < 2) {
      return;
    }
    setState(() {
      _status = '正在分析终局...';
    });
    try {
      final List<String> moveTokens = _game!.moves
          .map((GoMove m) => m.toProtocolToken(widget.boardSize))
          .toList();
      final List<String> initialTokens = _handicapStones
          .map(
            (GoPoint p) =>
                'B:${GoMove(player: GoStone.black, point: p).toGtp(widget.boardSize)}',
          )
          .toList();
      final AnalysisProfile profile = _effectiveProfileForTurn(_game!.moves.length);
      final KatagoAnalyzeResult res = await widget.adapter.analyze(
        KatagoAnalyzeRequest(
          queryId: 'count-${DateTime.now().millisecondsSinceEpoch}',
          moves: moveTokens,
          initialStones: initialTokens,
          gameSetup: GameSetup(
            boardSize: widget.boardSize,
            startingPlayer: _game!.toPlay == GoStone.black
                ? StoneColor.black
                : StoneColor.white,
          ),
          rules: _rules,
          profile: profile,
          includeOwnership: true,
          timeoutMs: _timeoutBudgetMsForProfile(profile),
        ),
      );
      // 用局势分析判定胜负，不用数目
      final double blackWr =
          _normalizeBlackWinrate(res.winrate, res.scoreLead);
      final double leadForBlack = _game!.toPlay == GoStone.black
          ? res.scoreLead
          : -res.scoreLead;
      String resultText;
      if (blackWr > 0.5) {
        resultText =
            '黑胜 ${leadForBlack.clamp(0.0, double.infinity).toStringAsFixed(1)} 目';
      } else if (blackWr < 0.5) {
        resultText =
            '白胜 ${(-leadForBlack).clamp(0.0, double.infinity).toStringAsFixed(1)} 目';
      } else {
        resultText = '和棋';
      }
      final GoScore? score = _scoreFromOwnership(res.ownership);
      if (mounted) {
        setState(() {
          _finalScore = score ?? _game!.scoreByRules(_rules);
          _finalResultTextFromAnalysis = resultText;
          _status = '终局: $resultText';
        });
        unawaited(_persistSession());
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _finalScore = _game!.scoreByRules(_rules);
          _finalResultTextFromAnalysis = null;
          _status = '终局: 分析失败（仅显示数目）';
        });
        unawaited(_persistSession());
      }
    }
  }

  static const double _ownershipThreshold = 0.35;

  /// 用 ownership 判断每个交叉点归属（含棋子死活）：有子也看 ownership，归属对方即为死子，该点算入对方面积。
  GoScore? _scoreFromOwnership(List<double>? ownership) {
    if (_game == null ||
        ownership == null ||
        ownership.length < widget.boardSize * widget.boardSize) {
      return null;
    }
    int livingBlackStones = 0;
    int livingWhiteStones = 0;
    int blackTerritory = 0;
    int whiteTerritory = 0;
    int deadWhiteInBlack = 0; // 白子但 ownership 属黑 → 死白子，该点算黑
    int deadBlackInWhite = 0; // 黑子但 ownership 属白 → 死黑子，该点算白
    for (int y = 0; y < widget.boardSize; y++) {
      for (int x = 0; x < widget.boardSize; x++) {
        final GoStone? s = _game!.board[y][x];
        final int idx = y * widget.boardSize + x;
        final double v = idx < ownership.length ? ownership[idx] : 0.0;
        final bool belongsToBlack = v > _ownershipThreshold;
        final bool belongsToWhite = v < -_ownershipThreshold;
        if (s == GoStone.black) {
          if (belongsToBlack) {
            livingBlackStones++;
          } else if (belongsToWhite) {
            deadBlackInWhite++;
          }
        } else if (s == GoStone.white) {
          if (belongsToWhite) {
            livingWhiteStones++;
          } else if (belongsToBlack) {
            deadWhiteInBlack++;
          }
        } else {
          if (belongsToBlack) {
            blackTerritory++;
          } else if (belongsToWhite) {
            whiteTerritory++;
          }
        }
      }
    }
    // 面积 = 活子 + 己方空点 + 对方死子所在点（按 ownership 归属）
    final double blackArea = (livingBlackStones + blackTerritory + deadWhiteInBlack).toDouble();
    final double whiteArea = (livingWhiteStones + whiteTerritory + deadBlackInWhite).toDouble() + _rules.komi;
    return GoScore(
      blackStones: livingBlackStones,
      whiteStones: livingWhiteStones,
      blackTerritory: blackTerritory,
      whiteTerritory: whiteTerritory,
      komi: _rules.komi,
      blackArea: blackArea,
      whiteArea: whiteArea,
      blackCaptures: _game!.blackCaptures,
      whiteCaptures: _game!.whiteCaptures,
    );
  }

  void _undo() {
    if (_tryMode) {
      return;
    }
    if (_history.length <= 1 || _aiThinking) {
      return;
    }
    while (_history.length > 1) {
      _history.removeLast();
      if (_history.last.toPlay == _playerStone || _history.length == 1) {
        break;
      }
    }
    setState(() {
      _game = _history.last;
      _pendingPoint = null;
      _finalScore = null;
      _finalResultTextFromAnalysis = null;
      _resignResultText = null;
      _status = '已悔棋';
      _startClockFor(_game!.toPlay);
    });
    unawaited(_persistSession());
  }

  GoPoint? _lastMovePoint() {
    if (_game == null || _game!.moves.isEmpty) {
      return null;
    }
    for (int i = _game!.moves.length - 1; i >= 0; i--) {
      final GoMove move = _game!.moves[i];
      if (!move.isPass && move.point != null) {
        return move.point;
      }
    }
    return null;
  }

  GoGameState _initialStateForReview() {
    final List<List<GoStone?>> board = List<List<GoStone?>>.generate(
      widget.boardSize,
      (_) => List<GoStone?>.filled(widget.boardSize, null),
    );
    for (final GoPoint p in _handicapStones) {
      board[p.y][p.x] = GoStone.black;
    }
    final GoStone toPlay = _handicapStones.isEmpty
        ? GoStone.black
        : GoStone.white;
    return GoGameState(
      boardSize: widget.boardSize,
      board: board,
      toPlay: toPlay,
    );
  }

  GoGameState _stateAtTurn(int turn) {
    GoGameState state = _initialStateForReview();
    final List<GoMove> moves = _game?.moves ?? <GoMove>[];
    final int safeTurn = turn.clamp(0, moves.length);
    for (int i = 0; i < safeTurn; i++) {
      state = state.play(moves[i]);
    }
    return state;
  }

  GoPoint? _lastMovePointAtTurn(int turn) {
    final List<GoMove> moves = _game?.moves ?? <GoMove>[];
    final int safeTurn = turn.clamp(0, moves.length);
    for (int i = safeTurn - 1; i >= 0; i--) {
      final GoMove move = moves[i];
      if (!move.isPass && move.point != null) {
        return move.point;
      }
    }
    return null;
  }

  GoPoint? _gtpToPoint(String gtp, int boardSize) {
    if (gtp.toLowerCase() == 'pass') {
      return null;
    }
    const String columns = 'ABCDEFGHJKLMNOPQRSTUVWXYZ';
    if (gtp.length < 2) {
      return null;
    }
    final String c = gtp.substring(0, 1).toUpperCase();
    final int x = columns.indexOf(c);
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

  List<GoPoint> _buildHandicapPoints(int size, int handicap) {
    if (handicap <= 0) {
      return <GoPoint>[];
    }
    final int offset = size >= 13 ? 3 : 2;
    final int low = offset;
    final int high = size - 1 - offset;
    final int mid = size ~/ 2;
    final List<GoPoint> ordered = <GoPoint>[
      GoPoint(low, high),
      GoPoint(high, low),
      GoPoint(low, low),
      GoPoint(high, high),
      GoPoint(low, mid),
      GoPoint(high, mid),
      GoPoint(mid, low),
      GoPoint(mid, high),
      GoPoint(mid, mid),
    ];
    return ordered.take(handicap.clamp(0, ordered.length)).toList();
  }

  bool get _isGameOver => _finalScore != null || _resignResultText != null;

  String get _handicapLabel {
    if (widget.handicap <= 0) {
      return '猜先';
    }
    if (widget.handicap == 1) {
      return '让先';
    }
    return '让${widget.handicap}子';
  }

  String get _ruleLabelForTopBar {
    if (widget.handicap == 1) {
      return '让先';
    }
    if (widget.handicap > 1) {
      return '让子棋';
    }
    return rulePresetFromString(_rules.ruleset).label;
  }

  bool _shouldAiResign(double aiWinrate) {
    final int moveCount = _game?.moves.length ?? 0;
    final int threshold = switch (widget.boardSize) {
      9 => 35,
      13 => 70,
      _ => 120,
    };
    return moveCount >= threshold && aiWinrate < 0.05;
  }

  double _normalizeBlackWinrate(double rawWinrate, double scoreLead) {
    final double clamped = rawWinrate.clamp(0.0, 1.0);
    // If winrate direction conflicts with scoreLead sign, flip it.
    // scoreLead > 0 generally means black is ahead; < 0 means white is ahead.
    if (scoreLead > 0.5 && clamped < 0.5) {
      return 1.0 - clamped;
    }
    if (scoreLead < -0.5 && clamped > 0.5) {
      return 1.0 - clamped;
    }
    return clamped;
  }

  Future<void> _playerResign() async {
    if (_isGameOver || _aiThinking) {
      return;
    }
    setState(() {
      _freezeActiveClock();
      _resignResultText = '你认输，AI胜';
      _status = _resignResultText!;
    });
    await _persistSession();
  }

  String _toSgf() {
    final StringBuffer sb = StringBuffer();
    final String result =
        _resignResultText ??
        (_finalScore != null
            ? (_finalResultTextFromAnalysis ?? '?')
            : '?');
    sb.write('(;GM[1]FF[4]');
    sb.write('SZ[${widget.boardSize}]');
    sb.write('KM[${_rules.komi}]');
    sb.write('RU[${_rules.ruleset}]');
    sb.write('PB[Player]');
    sb.write('PW[MasterGo AI]');
    if (widget.handicap > 0) {
      sb.write('HA[${widget.handicap}]');
      for (final GoPoint p in _handicapStones) {
        sb.write('AB[${_toSgfCoord(p)}]');
      }
    }
    sb.write('RE[$result]');
    for (final GoMove move in _game?.moves ?? <GoMove>[]) {
      final String color = move.player == GoStone.black ? 'B' : 'W';
      if (move.isPass || move.point == null) {
        sb.write(';$color[]');
      } else {
        sb.write(';$color[${_toSgfCoord(move.point!)}]');
      }
    }
    sb.write(')');
    return sb.toString();
  }

  String _toSgfCoord(GoPoint p) {
    const String letters = 'abcdefghijklmnopqrstuvwxyz';
    return '${letters[p.x]}${letters[p.y]}';
  }

  Future<void> _persistSession() async {
    final GoGameState? game = _game;
    if (game == null) {
      return;
    }
    final int now = DateTime.now().millisecondsSinceEpoch;
    final int createdAt = _recordCreatedAtMs ?? now;
    final Map<String, dynamic> data = <String, dynamic>{
      'boardSize': widget.boardSize,
      'handicap': widget.handicap,
      'profileId': widget.profile.id,
      'profileName': widget.profile.name,
      'playerStone': _playerStone.name,
      'aiStone': _aiStone.name,
      'moves': game.moves.map((GoMove m) {
        return <String, dynamic>{
          'player': m.player.name,
          'isPass': m.isPass,
          'x': m.point?.x,
          'y': m.point?.y,
        };
      }).toList(),
      'winrateByTurn': _winrateByTurn.map(
        (int k, double v) => MapEntry<String, dynamic>(k.toString(), v),
      ),
      'status': _status,
      'finalScore': _finalScore == null
          ? null
          : <String, dynamic>{
              'blackStones': _finalScore!.blackStones,
              'whiteStones': _finalScore!.whiteStones,
              'blackTerritory': _finalScore!.blackTerritory,
              'whiteTerritory': _finalScore!.whiteTerritory,
              'blackArea': _finalScore!.blackArea,
              'whiteArea': _finalScore!.whiteArea,
              'komi': _finalScore!.komi,
            },
      'finalResultTextFromAnalysis': _finalResultTextFromAnalysis,
      'resignResult': _resignResultText,
      'blackMs': _clockValue(GoStone.black).inMilliseconds,
      'whiteMs': _clockValue(GoStone.white).inMilliseconds,
      'ruleset': _rules.ruleset,
      'komi': _rules.komi,
      'sgf': _toSgf(),
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
    };
    final String id = _recordId ?? _recordRepository.newId(prefix: 'battle');
    _recordId = id;
    final String source = game.moves.length >= 20
        ? 'battle_local'
        : 'battle_temp';
    final GameRecord record = GameRecord(
      id: id,
      source: source,
      title: 'AI对弈 ${widget.boardSize}路 ${widget.profile.name}',
      boardSize: widget.boardSize,
      ruleset: _rules.ruleset,
      komi: _rules.komi,
      sgf: _toSgf(),
      status: _isGameOver ? 'finished' : 'active',
      sessionJson: jsonEncode(data),
      winrateJson: jsonEncode(
        _winrateByTurn.map(
          (int k, double v) => MapEntry<String, dynamic>(k.toString(), v),
        ),
      ),
      createdAtMs: createdAt,
      updatedAtMs: now,
    );
    _recordCreatedAtMs = createdAt;
    await _recordRepository.upsert(record);
  }

  Future<bool> _restoreSession() async {
    final GameRecord? local = await _recordRepository.loadLatestBySource(
      'battle_local',
    );
    final GameRecord? temp = await _recordRepository.loadLatestBySource(
      'battle_temp',
    );
    final GameRecord? latest = () {
      if (local == null) {
        return temp;
      }
      if (temp == null) {
        return local;
      }
      return local.updatedAtMs >= temp.updatedAtMs ? local : temp;
    }();
    if (latest == null ||
        latest.sessionJson.isEmpty ||
        latest.status == 'finished') {
      return false;
    }
    try {
      final Map<String, dynamic> data =
          jsonDecode(latest.sessionJson) as Map<String, dynamic>;
      if (data['finalScore'] != null ||
          (data['resignResult'] as String?) != null) {
        return false;
      }
      final int boardSize =
          (data['boardSize'] as num?)?.toInt() ?? latest.boardSize;
      final int handicap = (data['handicap'] as num?)?.toInt() ?? 0;
      final String restoredProfileId = (data['profileId'] as String?) ?? '';
      final String restoredRuleset =
          (data['ruleset'] as String?) ?? latest.ruleset;
      final double restoredKomi =
          (data['komi'] as num?)?.toDouble() ?? latest.komi;
      final String expectedRuleset = widget.rules.ruleset;
      final double expectedKomi = widget.handicap > 0 ? 0 : widget.rules.komi;
      final bool sameConfig =
          boardSize == widget.boardSize &&
          handicap == widget.handicap &&
          restoredProfileId == widget.profile.id &&
          restoredRuleset == expectedRuleset &&
          (restoredKomi - expectedKomi).abs() < 0.01;
      if (!sameConfig) {
        return false;
      }
      _recordId = latest.id;
      _recordCreatedAtMs = latest.createdAtMs;
      final RulePreset restoredPreset = rulePresetFromString(restoredRuleset);
      _rules = restoredPreset.toGameRules(komi: restoredKomi);
      if (handicap > 0 && _rules.komi != 0) {
        _rules = _rules.copyWith(komi: 0);
      }
      _playerStone = (data['playerStone'] as String) == 'white'
          ? GoStone.white
          : GoStone.black;
      _aiStone = _playerStone.opposite();

      final List<List<GoStone?>> board = List<List<GoStone?>>.generate(
        boardSize,
        (_) => List<GoStone?>.filled(boardSize, null),
      );
      final List<GoPoint> handicapStones = _buildHandicapPoints(
        boardSize,
        handicap,
      );
      for (final GoPoint p in handicapStones) {
        board[p.y][p.x] = GoStone.black;
      }
      final GoStone toPlay = handicapStones.isEmpty
          ? GoStone.black
          : GoStone.white;
      GoGameState state = GoGameState(
        boardSize: boardSize,
        board: board,
        toPlay: toPlay,
      );
      _history
        ..clear()
        ..add(state);

      final List<dynamic> moves =
          (data['moves'] as List<dynamic>? ?? <dynamic>[]);
      for (final dynamic rawMove in moves) {
        final Map<String, dynamic> m = rawMove as Map<String, dynamic>;
        final GoStone player = (m['player'] as String) == 'white'
            ? GoStone.white
            : GoStone.black;
        final bool isPass = m['isPass'] as bool? ?? false;
        final int? x = (m['x'] as num?)?.toInt();
        final int? y = (m['y'] as num?)?.toInt();
        final GoMove move = isPass || x == null || y == null
            ? GoMove(player: player, isPass: true)
            : GoMove(player: player, point: GoPoint(x, y));
        state = state.play(move);
        _history.add(state);
      }

      _game = state;
      _handicapStones = handicapStones;
      _pendingPoint = null;
      _blackWinrate = null;
      _hintSummary = null;
      _winrateByTurn
        ..clear()
        ..addAll(
          ((data['winrateByTurn'] as Map<String, dynamic>? ??
                  <String, dynamic>{})
              .map(
                (String k, dynamic v) =>
                    MapEntry<int, double>(int.parse(k), (v as num).toDouble()),
              )),
        );
      _status = data['status'] as String? ?? '已恢复上局';
      _finalResultTextFromAnalysis =
          data['finalResultTextFromAnalysis'] as String?;
      _resignResultText = data['resignResult'] as String?;

      final Map<String, dynamic>? score =
          data['finalScore'] as Map<String, dynamic>?;
      _finalScore = score == null
          ? null
          : GoScore(
              blackStones: (score['blackStones'] as num).toInt(),
              whiteStones: (score['whiteStones'] as num).toInt(),
              blackTerritory: (score['blackTerritory'] as num).toInt(),
              whiteTerritory: (score['whiteTerritory'] as num).toInt(),
              komi: (score['komi'] as num).toDouble(),
              blackArea: (score['blackArea'] as num).toDouble(),
              whiteArea: (score['whiteArea'] as num).toDouble(),
            );

      _blackBase = Duration(
        milliseconds: (data['blackMs'] as num?)?.toInt() ?? 0,
      );
      _whiteBase = Duration(
        milliseconds: (data['whiteMs'] as num?)?.toInt() ?? 0,
      );
      _activeClockStone = null;
      _activeClockStartedAt = null;
      if (!_isGameOver) {
        _startClockFor(state.toPlay);
      } else {
        _freezeActiveClock();
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<List<_HintPointInfo>> _requestHintPointsForState(
    GoGameState state,
  ) async {
    final List<String> moveTokens = state.moves
        .map((GoMove m) => m.toProtocolToken(widget.boardSize))
        .toList();
    final List<String> initialTokens = _handicapStones
        .map(
          (GoPoint p) =>
              'B:${GoMove(player: GoStone.black, point: p).toGtp(widget.boardSize)}',
        )
        .toList();
    final KatagoAnalyzeResult analyzed = await widget.adapter.analyze(
      KatagoAnalyzeRequest(
        queryId: 'hint-${DateTime.now().millisecondsSinceEpoch}',
        moves: moveTokens,
        initialStones: initialTokens,
        gameSetup: GameSetup(
          boardSize: widget.boardSize,
          startingPlayer: state.toPlay == GoStone.black
              ? StoneColor.black
              : StoneColor.white,
        ),
        rules: _rules,
        profile: AnalysisProfile(
          id: '${widget.profile.id}-hint',
          name: widget.profile.name,
          description: widget.profile.description,
          maxVisits: max(10, widget.profile.maxVisits),
          thinkingTimeMs: widget.profile.thinkingTimeMs,
          includeOwnership: widget.profile.includeOwnership,
        ),
        timeoutMs: _timeoutBudgetMs(),
      ),
    );
    final List<KatagoMoveCandidate> candidates =
        analyzed.topCandidates.isNotEmpty
        ? analyzed.topCandidates
        : <KatagoMoveCandidate>[
            KatagoMoveCandidate(
              move: analyzed.bestMove,
              blackWinrate: analyzed.winrate,
            ),
          ];
    final List<_HintPointInfo> infos = <_HintPointInfo>[];
    for (final KatagoMoveCandidate c in candidates) {
      final GoPoint? p = _gtpToPoint(c.move, widget.boardSize);
      if (p == null) {
        continue;
      }
      final double playerWin = state.toPlay == GoStone.black
          ? c.blackWinrate
          : (1.0 - c.blackWinrate);
      infos.add(
        _HintPointInfo(
          point: p,
          move: c.move,
          playerWinrate: playerWin.clamp(0.0, 1.0),
        ),
      );
      if (infos.length >= 3) {
        break;
      }
    }
    if (infos.isEmpty) {
      return const <_HintPointInfo>[];
    }
    return infos.length > 1
        ? infos.take(3).toList()
        : <_HintPointInfo>[infos.first];
  }

  Future<void> _showHintPoints() async {
    final GoGameState? state = _game;
    if (state == null || _aiThinking || _isGameOver) {
      return;
    }
    setState(() {
      _status = '正在计算提示点...';
    });
    try {
      final List<_HintPointInfo> hints = await _requestHintPointsForState(
        state,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _hintPoints = hints.map((_HintPointInfo h) => h.point).toList();
        _hintSummary = hints.isEmpty
            ? null
            : hints
                  .map(
                    (_HintPointInfo h) =>
                        '${h.move}:${(h.playerWinrate * 100).toStringAsFixed(1)}%',
                  )
                  .join('  ');
        _status = hints.isEmpty ? '暂无可用提示点' : '提示点已标注（${hints.length}个）';
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = '提示失败: $e';
      });
    }
  }

  /// 对任意局面请求势力/目数分析，供对局中与复盘共用。
  Future<KatagoAnalyzeResult> _requestOwnershipAnalysis(GoGameState state) {
    final List<String> moveTokens = state.moves
        .map((GoMove m) => m.toProtocolToken(widget.boardSize))
        .toList();
    final List<String> initialTokens = _handicapStones
        .map(
          (GoPoint p) =>
              'B:${GoMove(player: GoStone.black, point: p).toGtp(widget.boardSize)}',
        )
        .toList();
    final AnalysisProfile profile =
        _effectiveProfileForTurn(state.moves.length);
    // 局势分析优先可用性：固定低 visits，避免复盘场景超时。
    final AnalysisProfile ownershipProfile = AnalysisProfile(
      id: '${profile.id}-ownership-fast',
      name: profile.name,
      description: profile.description,
      maxVisits: 20,
      thinkingTimeMs: 1000,
      includeOwnership: true,
    );
    final int timeoutMs = max(_timeoutBudgetMsForProfile(ownershipProfile), 30000);
    return widget.adapter.analyze(
      KatagoAnalyzeRequest(
        queryId: 'ownership-${DateTime.now().millisecondsSinceEpoch}',
        moves: moveTokens,
        initialStones: initialTokens,
        gameSetup: GameSetup(
          boardSize: widget.boardSize,
          startingPlayer: state.toPlay == GoStone.black
              ? StoneColor.black
              : StoneColor.white,
        ),
        rules: _rules,
        profile: ownershipProfile,
        includeOwnership: true,
        timeoutMs: timeoutMs,
      ),
    );
  }

  void _showOwnershipResultSheet(
    BuildContext ctx,
    GoGameState state,
    KatagoAnalyzeResult res, {
    GoPoint? lastMovePoint,
  }) {
    showOwnershipResultSheet(ctx, state, res, boardSize: widget.boardSize);
  }

  Future<void> _showPositionAnalysis() async {
    final GoGameState? state = _game;
    if (state == null || _aiThinking || _isGameOver) {
      return;
    }
    setState(() {
      _status = '正在分析局势...';
    });
    try {
      final KatagoAnalyzeResult res = await _requestOwnershipAnalysis(state);
      if (!mounted) {
        return;
      }
      setState(() {
        _status = '分析完成';
      });
      if (!mounted) {
        return;
      }
      _showOwnershipResultSheet(context, state, res,
          lastMovePoint: _lastMovePoint());
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = '局势分析失败: $e';
      });
    }
  }

  void _enterTryMode() {
    if (_game == null || _tryMode || _aiThinking) {
      return;
    }
    setState(() {
      _tryMode = true;
      _tryBaseState = _game;
      _tryBaseStatus = _status;
      _pendingPoint = null;
      _hintPoints = <GoPoint>[];
      _hintSummary = null;
      _status = '试下模式：可同时走黑白，结束后返回实战局面';
    });
  }

  void _exitTryMode() {
    if (!_tryMode || _tryBaseState == null) {
      return;
    }
    setState(() {
      _game = _tryBaseState;
      _tryMode = false;
      _tryBaseState = null;
      _pendingPoint = null;
      _hintPoints = <GoPoint>[];
      _hintSummary = null;
      _status = _tryBaseStatus ?? '已结束试下';
    });
  }

  List<String> _buildHints({required bool good}) {
    final List<MoveHint> hints = _analysisService.buildHints(
      _winrateByTurn,
      playerStone: _playerStone,
      brilliantEpsilon: 0.05,
    );
    return hints
        .where(
          (MoveHint h) =>
              good ? h.kind == HintKind.brilliant : h.kind == HintKind.blunder,
        )
        .map(
          (MoveHint h) =>
              '第${h.turn}手后玩家胜率 ${(h.deltaPlayerWinrate * 100).toStringAsFixed(1)}%',
        )
        .toList();
  }

  void _showReviewSheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext context) {
        final List<String> good = _buildHints(good: true);
        final List<String> bad = _buildHints(good: false);
        final List<GoMove> moves = _game?.moves ?? <GoMove>[];
        int turn = moves.length;
        bool reviewTryMode = false;
        GoGameState? reviewTryState;
        GoGameState? reviewTryBaseState;
        List<GoPoint> reviewHints = <GoPoint>[];
        String? reviewHintSummary;
        bool reviewHintLoading = false;
        bool reviewOwnershipLoading = false;
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setSheetState) {
            return DraggableScrollableSheet(
              expand: false,
              initialChildSize: 0.92,
              maxChildSize: 0.96,
              builder: (_, ScrollController controller) {
                final GoGameState state = reviewTryMode
                    ? (reviewTryState ?? _stateAtTurn(turn))
                    : _stateAtTurn(turn);
                final GoPoint? lastPoint = _lastMovePointAtTurn(turn);
                void exitTryAndClearHints() {
                  reviewTryMode = false;
                  reviewTryState = reviewTryBaseState;
                  reviewTryBaseState = null;
                  reviewHints = <GoPoint>[];
                  reviewHintSummary = null;
                }
                return ListView(
                  controller: controller,
                  padding: const EdgeInsets.all(12),
                  children: <Widget>[
                    ReviewBoardPanel(
                      title: '复盘',
                      state: state,
                      lastMovePoint: lastPoint,
                      tryMode: reviewTryMode,
                      hintPoints: reviewHints,
                      hintSummary: reviewHintSummary,
                      hintLoading: reviewHintLoading,
                      ownershipLoading: reviewOwnershipLoading,
                      onEnterTry: () {
                        setSheetState(() {
                          reviewTryMode = true;
                          reviewTryBaseState = state;
                          reviewTryState = state;
                          reviewHints = <GoPoint>[];
                          reviewHintSummary = null;
                        });
                      },
                      onExitTry: () => setSheetState(exitTryAndClearHints),
                      onTryPlay: (GoPoint p) {
                        try {
                          setSheetState(() {
                            reviewTryState = state.play(
                              GoMove(player: state.toPlay, point: p),
                            );
                            reviewHints = <GoPoint>[];
                            reviewHintSummary = null;
                          });
                          playStoneSound();
                        } catch (_) {}
                      },
                      onRequestHint: () async {
                        setSheetState(() => reviewHintLoading = true);
                        final List<_HintPointInfo> hints =
                            await _requestHintPointsForState(state);
                        if (!context.mounted) return;
                        setSheetState(() {
                          reviewHintLoading = false;
                          reviewHints =
                              hints.map((_HintPointInfo h) => h.point).toList();
                          reviewHintSummary = hints.isEmpty
                              ? null
                              : hints
                                    .map(
                                      (_HintPointInfo h) =>
                                          '${h.move}:${(h.playerWinrate * 100).toStringAsFixed(1)}%',
                                    )
                                    .join('  ');
                        });
                      },
                      onRequestOwnership: () async {
                        setSheetState(() => reviewOwnershipLoading = true);
                        try {
                          final KatagoAnalyzeResult res =
                              await _requestOwnershipAnalysis(state);
                          if (!context.mounted) return;
                          setSheetState(() => reviewOwnershipLoading = false);
                          _showOwnershipResultSheet(context, state, res);
                        } catch (e) {
                          if (context.mounted) {
                            setSheetState(() => reviewOwnershipLoading = false);
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('局势分析失败: $e')),
                            );
                          }
                        }
                      },
                      currentTurn: turn,
                      maxTurn: max((_game?.moves.length ?? 1), 1),
                      winrates: _winrateByTurn,
                      onTurnSelected: (int t) {
                        setSheetState(() {
                          turn = t.clamp(0, moves.length);
                          exitTryAndClearHints();
                        });
                      },
                      turnNavigation: Row(
                        children: <Widget>[
                          IconButton(
                            onPressed: turn > 0
                                ? () => setSheetState(() => turn -= 1)
                                : null,
                            icon: const Icon(Icons.chevron_left),
                          ),
                          Expanded(
                              child: Text('当前手数: $turn/${moves.length}')),
                          IconButton(
                            onPressed: turn < moves.length
                                ? () => setSheetState(() => turn += 1)
                                : null,
                            icon: const Icon(Icons.chevron_right),
                          ),
                        ],
                      ),
                      bottomChild: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Slider(
                            value: turn.toDouble(),
                            min: 0,
                            max: max(1, moves.length).toDouble(),
                            divisions: max(1, moves.length),
                            label: '$turn',
                            onChanged: (double value) {
                              setSheetState(() {
                                turn = value.round().clamp(0, moves.length);
                                exitTryAndClearHints();
                              });
                            },
                          ),
                          if (_winrateByTurn.containsKey(turn))
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Text(() {
                                final double black = _winrateByTurn[turn]!;
                                final double player = _playerStone == GoStone.black
                                    ? black
                                    : (1.0 - black);
                                return '第$turn手玩家胜率: ${(player * 100).toStringAsFixed(1)}%';
                              }()),
                            ),
                          const SizedBox(height: 8),
                          Text('妙手提示',
                              style: Theme.of(context).textTheme.titleMedium),
                          if (good.isEmpty)
                            const Text('暂无明显妙手')
                          else
                            ...good.map(Text.new),
                          const SizedBox(height: 8),
                          Text('恶手提示',
                              style: Theme.of(context).textTheme.titleMedium),
                          if (bad.isEmpty)
                            const Text('暂无明显恶手')
                          else
                            ...bad.map(Text.new),
                        ],
                      ),
                    ),
                  ],
                );
              },
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final GoGameState? game = _game;
    final double? playerWin = _playerWinrate;
    final String winrateText = playerWin == null
        ? '--'
        : '${(playerWin * 100).toStringAsFixed(1)}%';
    Widget compactBtn(VoidCallback? onPressed, String label) {
      return OutlinedButton(
        style: OutlinedButton.styleFrom(
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        onPressed: onPressed,
        child: Text(label),
      );
    }

    Widget stoneTimeTag(GoStone stone, Duration value) {
      final bool isBlack = stone == GoStone.black;
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isBlack ? Colors.black : Colors.white,
              border: Border.all(color: Colors.black26),
            ),
          ),
          const SizedBox(width: 4),
          Text(_fmtDuration(value), style: const TextStyle(fontSize: 12)),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 68,
        titleSpacing: 8,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                '难度:${widget.profile.name}  规则:$_handicapLabel  胜率:$winrateText',
                style: const TextStyle(fontSize: 13),
              ),
            ),
            const SizedBox(height: 4),
            Row(
              children: <Widget>[
                stoneTimeTag(GoStone.black, _clockValue(GoStone.black)),
                const SizedBox(width: 12),
                stoneTimeTag(GoStone.white, _clockValue(GoStone.white)),
              ],
            ),
          ],
        ),
      ),
      body: _restoring
          ? const Center(child: CircularProgressIndicator())
          : game == null
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              child: Column(
                children: <Widget>[
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
                      child: GoBoardWidget(
                        boardSize: game.boardSize,
                        board: game.board,
                        onTapPoint: _onBoardTap,
                        lastMovePoint: _lastMovePoint(),
                        tentativePoint: _pendingPoint,
                        tentativeStone: _pendingPoint == null
                            ? null
                            : _playerStone,
                        hintPoints: _hintPoints,
                        padding: 14,
                      ),
                    ),
                  ),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                    decoration: BoxDecoration(
                      border: Border(top: BorderSide(color: Colors.black12)),
                      color: Colors.white,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          '当前落子: ${game.toPlay == GoStone.black ? '黑' : '白'}'
                          '${_aiThinking ? '（AI思考中）' : ''}',
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _engineReady ? _status : '启动引擎中…',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (_hintSummary != null) ...<Widget>[
                          const SizedBox(height: 4),
                          Text(
                            '提示胜率: $_hintSummary',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12),
                          ),
                        ],
                        if (_finalScore != null) ...<Widget>[
                          const SizedBox(height: 4),
                          Text(
                            _finalResultTextFromAnalysis != null
                                ? '终局结果: $_finalResultTextFromAnalysis（黑地${_finalScore!.blackTerritory}，白地${_finalScore!.whiteTerritory}）'
                                : '终局结果: 分析失败（黑地${_finalScore!.blackTerritory}，白地${_finalScore!.whiteTerritory}）',
                          ),
                        ],
                        if (_resignResultText != null) ...<Widget>[
                          const SizedBox(height: 4),
                          Text('终局结果: $_resignResultText'),
                        ],
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 4,
                          runSpacing: 4,
                          children: <Widget>[
                            compactBtn(
                              (!_isGameOver && !_aiThinking)
                                  ? (_tryMode ? _exitTryMode : _enterTryMode)
                                  : null,
                              _tryMode ? '结束试下' : '试下',
                            ),
                            compactBtn(
                              (_engineReady && !_isGameOver && !_aiThinking)
                                  ? _showHintPoints
                                  : null,
                              '提示',
                            ),
                            compactBtn(
                              (_engineReady && !_isGameOver && !_aiThinking)
                                  ? _showPositionAnalysis
                                  : null,
                              '局势分析',
                            ),
                            compactBtn(
                              (game.toPlay == _playerStone &&
                                      !_aiThinking &&
                                      _finalScore == null)
                                  ? _playerPass
                                  : null,
                              'Pass',
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Wrap(
                          spacing: 4,
                          runSpacing: 4,
                          children: <Widget>[
                            compactBtn(
                              (_history.length > 1 && !_aiThinking) ? _undo : null,
                              '悔棋',
                            ),
                            compactBtn(
                              (!_isGameOver && !_aiThinking)
                                  ? _playerResign
                                  : null,
                              '认输',
                            ),
                            compactBtn(
                              _isGameOver ? _showReviewSheet : null,
                              '复盘',
                            ),
                            compactBtn(
                              () => Navigator.of(context).pop(),
                              '返回',
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

class _HintPointInfo {
  const _HintPointInfo({
    required this.point,
    required this.move,
    required this.playerWinrate,
  });

  final GoPoint point;
  final String move;
  final double playerWinrate;
}
