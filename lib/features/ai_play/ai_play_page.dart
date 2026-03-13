import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mastergo/app/app_i18n.dart';
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
import 'package:mastergo/features/common/pending_confirm_timer.dart';
import 'package:mastergo/features/common/review_board_panel.dart';
import 'package:mastergo/infra/config/ai_profile_repository.dart';
import 'package:mastergo/infra/engine/katago/katago_adapter.dart';
import 'package:mastergo/infra/sound/stone_sound.dart';
import 'package:mastergo/infra/storage/game_record_repository.dart';

class AIPlayPage extends StatefulWidget {
  const AIPlayPage({super.key, this.initialRestoreRecordId});

  final String? initialRestoreRecordId;

  /// 从打谱/识谱进入续下：当前玩家先下，下一步 AI 下；仅新着法>20 步时记入本机对局。
  /// [prefixWinrates] 打谱续下时传入原谱胜率（手数 -> 黑方胜率），会合并进对局胜率曲线并随记录保存。
  static Future<void> pushContinuePlay(
    BuildContext context, {
    required GoGameState initialGameState,
    required AnalysisProfile profile,
    required GameRules rules,
    int prefixMoveCount = 0,
    double? originalKomi,
    String? originalRuleset,
    List<GoPoint>? originalInitialBlack,
    List<GoPoint>? originalInitialWhite,
    Map<int, double>? prefixWinrates,
  }) async {
    final KatagoAdapter adapter = PlatformKatagoAdapter();
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => _AIBattlePage(
          adapter: adapter,
          profile: profile,
          boardSize: initialGameState.boardSize,
          handicap: 0,
          randomFirst: false,
          rules: rules,
          initialGameState: initialGameState,
          continuationPrefixMoveCount: prefixMoveCount,
          continuationOriginalKomi: originalKomi,
          continuationOriginalRuleset: originalRuleset,
          continuationOriginalInitialBlack: originalInitialBlack,
          continuationOriginalInitialWhite: originalInitialWhite,
          continuationPrefixWinrates: prefixWinrates,
        ),
      ),
    );
    unawaited(adapter.shutdown());
  }

  @override
  State<AIPlayPage> createState() => _AIPlayPageState();
}

class _AIPlayPageState extends State<AIPlayPage> {
  final AIProfileRepository _profileRepository = AIProfileRepository();
  final GameRecordRepository _recordRepository = GameRecordRepository();
  final KatagoAdapter _katagoAdapter = PlatformKatagoAdapter();
  final List<int> _boardSizes = <int>[9, 13, 19];
  final List<AnalysisProfile> _profilesCache = <AnalysisProfile>[];
  bool _autoResumeAttempted = false;

  int _boardSize = 19;
  int _handicap = 0;
  String _selectedRulesetId = 'chinese';
  String? _selectedProfileId;
  late AppLanguage _language;
  AppStrings get _s => AppStrings(_language);
  AppLanguage _effectiveLanguage() {
    try {
      return AppStrings.resolveFromLocale(Localizations.localeOf(context));
    } catch (_) {
      return _language;
    }
  }

  @override
  void initState() {
    super.initState();
    _language = AppStrings.resolveFromLocale(
      WidgetsBinding.instance.platformDispatcher.locale,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _language = _effectiveLanguage();
  }

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

  List<RulePreset> get _aiRulePresets => kRulePresets
      .where((RulePreset preset) => preset.supportsAiPlay)
      .toList(growable: false);

  RulePreset get _activeRulePreset => rulePresetFromString(_selectedRulesetId);

  /// 恢复对局时传入 [restoreRules]，与 session 的 ruleset/komi 对齐，避免配置不一致导致无法恢复。
  Future<void> _startBattle(AnalysisProfile profile, {GameRules? restoreRules}) async {
    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => _AIBattlePage(
          adapter: _katagoAdapter,
          profile: profile,
          boardSize: _boardSize,
          handicap: _handicap,
          randomFirst: true,
          rules: restoreRules ?? _activeRulePreset.toGameRules(),
          preferredRestoreRecordId: widget.initialRestoreRecordId,
        ),
      ),
    );
  }

  Future<void> _autoResumeIfRequested(List<AnalysisProfile> profiles) async {
    if (_autoResumeAttempted) {
      debugPrint('[恢复对局] 加载失败: 已尝试过，跳过');
      return;
    }
    _autoResumeAttempted = true;
    final String? recordId = widget.initialRestoreRecordId;
    if (recordId == null || recordId.isEmpty) {
      debugPrint('[恢复对局] 加载失败: 未传入 recordId (initialRestoreRecordId 为空)');
      return;
    }
    debugPrint('[恢复对局] 加载记录 id=$recordId');
    final GameRecord? record = await _recordRepository.loadById(recordId);
    if (!mounted) {
      debugPrint('[恢复对局] 加载失败: 页面已 dispose');
      return;
    }
    if (record == null) {
      debugPrint('[恢复对局] 加载失败: 记录不存在 (loadById 返回 null)');
      return;
    }
    if (record.sessionJson.isEmpty) {
      debugPrint('[恢复对局] 加载失败: session 为空 recordId=$recordId');
      return;
    }
    try {
      final Map<String, dynamic> data =
          jsonDecode(record.sessionJson) as Map<String, dynamic>;
      final int boardSize =
          (data['boardSize'] as num?)?.toInt() ?? record.boardSize;
      final int handicap = (data['handicap'] as num?)?.toInt() ?? 0;
      final String ruleset = (data['ruleset'] as String?) ?? record.ruleset;
      final double komi = (data['komi'] as num?)?.toDouble() ?? record.komi;
      final GameRules restoreRules = rulePresetFromString(ruleset).toGameRules(komi: komi);
      final String? profileId = data['profileId'] as String?;
      final int moveCount = (data['moves'] as List<dynamic>?)?.length ?? 0;
      AnalysisProfile? profile;
      if (profileId != null) {
        for (final AnalysisProfile p in profiles) {
          if (p.id == profileId) {
            profile = p;
            break;
          }
        }
      }
      profile ??= _activeProfile;
      if (profile == null) {
        debugPrint('[恢复对局] 加载失败: 未找到难度配置 profileId=$profileId');
        return;
      }
      if (!_boardSizes.contains(boardSize)) {
        debugPrint('[恢复对局] 加载失败: 不支持的棋盘大小 boardSize=$boardSize (支持: $_boardSizes)');
        return;
      }
      if (!kRulePresets.any(
        (RulePreset p) => p.id == ruleset && p.supportsAiPlay,
      )) {
        debugPrint('[恢复对局] 加载失败: 规则不支持 AI 对局 ruleset=$ruleset');
        return;
      }
      if (!mounted) {
        debugPrint('[恢复对局] 加载失败: setState 后页面已 dispose');
        return;
      }
      debugPrint('[恢复对局] 准备进入对局页 recordId=$recordId boardSize=$boardSize handicap=$handicap komi=$komi moves=$moveCount profile=${profile.id}');
      setState(() {
        _boardSize = boardSize;
        _handicap = handicap.clamp(0, 9);
        _selectedRulesetId = ruleset;
        _selectedProfileId = profile!.id;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          unawaited(_startBattle(profile!, restoreRules: restoreRules));
        }
      });
    } catch (e, st) {
      debugPrint('[恢复对局] 加载失败: 异常 $e\n$st');
      return;
    }
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
              return Center(
                child: Text(
                  _s.pick(
                    zh: '加载难度配置失败: ${snap.error}',
                    en: 'Failed to load AI profiles: ${snap.error}',
                    ja: '難易度設定の読み込みに失敗: ${snap.error}',
                    ko: '난이도 설정 불러오기 실패: ${snap.error}',
                  ),
                ),
              );
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
            final List<RulePreset> aiRulePresets = _aiRulePresets;
            if (aiRulePresets.isNotEmpty &&
                !aiRulePresets.any(
                  (RulePreset preset) => preset.id == _selectedRulesetId,
                )) {
              _selectedRulesetId = aiRulePresets.first.id;
            }
            unawaited(_autoResumeIfRequested(profiles));
            return ListView(
              padding: const EdgeInsets.all(16),
              children: <Widget>[
                Text(
                  _s.tabAiPlay,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<int>(
                  initialValue: _boardSize,
                  decoration: InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: _s.pick(
                      zh: '棋盘尺寸',
                      en: 'Board Size',
                      ja: '盤サイズ',
                      ko: '바둑판 크기',
                    ),
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
                  decoration: InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: _s.pick(
                      zh: '难度',
                      en: 'Difficulty',
                      ja: '難易度',
                      ko: '난이도',
                    ),
                  ),
                  items: profiles.map((AnalysisProfile p) {
                    return DropdownMenuItem<String>(
                      value: p.id,
                      child: Text(_s.aiProfileName(p.id, p.name)),
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
                  decoration: InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: _s.pick(
                      zh: '规则',
                      en: 'Rules',
                      ja: 'ルール',
                      ko: '규칙',
                    ),
                  ),
                  items: aiRulePresets
                      .map(
                        (RulePreset p) => DropdownMenuItem<String>(
                          value: p.id,
                          child: Text(
                            '${_s.ruleLabel(p.id)} (KM ${p.defaultKomi})',
                          ),
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
                Text(
                  _s.pick(
                    zh: 'AI让子给你: $_handicap',
                    en: 'AI handicap: $_handicap',
                    ja: 'AI置石: $_handicap',
                    ko: 'AI 접바둑: $_handicap',
                  ),
                ),
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed: selected == null
                      ? null
                      : () => _startBattle(selected),
                  icon: const Icon(Icons.play_arrow),
                  label: Text(
                    _s.pick(
                      zh: '开始对弈',
                      en: 'Start Game',
                      ja: '対局開始',
                      ko: '대국 시작',
                    ),
                  ),
                ),
                if (selected != null) ...<Widget>[
                  const SizedBox(height: 16),
                  Card(
                    child: ListTile(
                      title: Text(_s.aiProfileName(selected.id, selected.name)),
                      subtitle: Text(
                        _s.aiProfileDescription(
                          selected.id,
                          selected.description,
                        ),
                      ),
                      trailing: Text(
                        _s.pick(
                          zh: '访问数 ${selected.maxVisits}',
                          en: 'Visits ${selected.maxVisits}',
                          ja: '探索数 ${selected.maxVisits}',
                          ko: '탐색수 ${selected.maxVisits}',
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            );
          },
    );
  }
}

/// 续下模式：从打谱/识谱进入，保留前缀着法（打谱）或仅当前局面（识谱），仅新着法>20步时记入本机对局。
class _AIBattlePage extends StatefulWidget {
  const _AIBattlePage({
    required this.adapter,
    required this.profile,
    required this.boardSize,
    required this.handicap,
    required this.randomFirst,
    required this.rules,
    this.preferredRestoreRecordId,
    this.initialGameState,
    this.continuationPrefixMoveCount = 0,
    this.continuationOriginalKomi,
    this.continuationOriginalRuleset,
    this.continuationOriginalInitialBlack,
    this.continuationOriginalInitialWhite,
    this.continuationPrefixWinrates,
  });

  final KatagoAdapter adapter;
  final AnalysisProfile profile;
  final int boardSize;
  final int handicap;
  final bool randomFirst;
  final GameRules rules;
  final String? preferredRestoreRecordId;
  final GoGameState? initialGameState;
  final int continuationPrefixMoveCount;
  final double? continuationOriginalKomi;
  final String? continuationOriginalRuleset;
  final List<GoPoint>? continuationOriginalInitialBlack;
  final List<GoPoint>? continuationOriginalInitialWhite;
  /// 打谱续下时原谱的胜率（手数 -> 黑方胜率），合并进 _winrateByTurn 并随记录保存。
  final Map<int, double>? continuationPrefixWinrates;

  @override
  State<_AIBattlePage> createState() => _AIBattlePageState();
}

class _AIBattlePageState extends State<_AIBattlePage>
    with WidgetsBindingObserver {
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
  final PendingConfirmTimer _pendingConfirmTimer = PendingConfirmTimer();
  GoStone _playerStone = GoStone.black;
  GoStone _aiStone = GoStone.white;
  bool _tryMode = false;
  GoGameState? _tryBaseState;
  String? _tryBaseStatus;
  List<GoPoint> _hintPoints = <GoPoint>[];
  String? _hintSummary;
  bool _hintLoading = false;
  bool _ownershipLoading = false;
  bool _aiThinking = false;
  bool _restoring = true;
  bool _engineReady = false;
  String _status = 'Preparing...';
  double? _blackWinrate;
  final Map<int, double> _winrateByTurn = <int, double>{};
  late AppLanguage _language;
  AppStrings get _s => AppStrings(_language);
  AppLanguage _effectiveLanguage() {
    try {
      return AppStrings.resolveFromLocale(Localizations.localeOf(context));
    } catch (_) {
      return _language;
    }
  }

  String _t({
    required String zh,
    required String en,
    required String ja,
    required String ko,
  }) => AppStrings(_effectiveLanguage()).pick(zh: zh, en: en, ja: ja, ko: ko);

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

  /// 读取超时 = 建议思考时间的两倍（引擎 maxTime 已用 thinkingTimeMs，此处为 App 等待上限）。
  int _timeoutBudgetMsForProfile(AnalysisProfile profile) {
    return profile.thinkingTimeMs * 2;
  }

  /// 前几步快速开局：手数 < 6 用 20，< 24 用 50，与难度档位（快速 20 / 挑战 50）对应。
  /// 开局思考时间至少 10s，避免 iOS 等设备上「刚开局就超时」（原 1s 太短）。
  AnalysisProfile _effectiveProfileForTurn(int moveCount) {
    final AnalysisProfile p = widget.profile;
    if (p.maxVisits <= 20) {
      return p;
    }
    int effectiveVisits = p.maxVisits;
    if (moveCount < 6) {
      effectiveVisits = min(effectiveVisits, 20);
    } else if (moveCount < 24) {
      effectiveVisits = min(effectiveVisits, 50);
    }
    if (effectiveVisits == p.maxVisits) {
      return p;
    }
    return AnalysisProfile(
      id: '${p.id}-opening-$effectiveVisits',
      name: p.name,
      description: p.description,
      maxVisits: effectiveVisits,
      thinkingTimeMs: min(p.thinkingTimeMs, 10000),
      includeOwnership: p.includeOwnership,
    );
  }

  bool get _isContinuation =>
      widget.initialGameState != null || widget.continuationPrefixMoveCount > 0;

  int get _newMoveCount {
    final GoGameState? game = _game;
    if (game == null) return 0;
    return (game.moves.length - widget.continuationPrefixMoveCount)
        .clamp(0, game.moves.length);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _language = AppStrings.resolveFromLocale(
      WidgetsBinding.instance.platformDispatcher.locale,
    );
    _rules = widget.handicap > 0
        ? widget.rules.copyWith(komi: 0)
        : widget.rules;
    _initializeGame(shouldPersist: false);
    _restoring = false;
    unawaited(_bootstrapSession());
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final AppLanguage next = _effectiveLanguage();
    final bool changed = next != _language;
    _language = next;
    if (changed && _game != null) {
      _status = _localizedStatusForCurrentState(_game!);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(_persistSession());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_persistSession());
    _freezeActiveClock();
    _ticker?.cancel();
    _pendingConfirmTimer.cancel();
    super.dispose();
  }

  Future<void> _bootstrapSession() async {
    final bool restored = await _restoreSession();
    if (!mounted) return;
    if (restored) {
      setState(() {});
    } else {
      // Only persist a fresh session when no resumable game is found.
      await _persistSession();
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

  void _initializeGame({bool shouldPersist = true}) {
    _recordId = null;
    _recordCreatedAtMs = null;

    final GoGameState? fromContinuation = widget.initialGameState;
    if (fromContinuation != null) {
      _playerStone = fromContinuation.toPlay;
      _aiStone = _playerStone.opposite();
      _history
        ..clear()
        ..add(fromContinuation);
      _game = fromContinuation;
      _handicapStones = <GoPoint>[];
    } else {
      if (widget.handicap > 0) {
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
      final GoStone toPlay =
          handicap.isEmpty ? GoStone.black : GoStone.white;
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
    }

    _finalScore = null;
    _finalResultTextFromAnalysis = null;
    _resignResultText = null;
    _pendingConfirmTimer.cancel();
    _pendingPoint = null;
    _blackWinrate = null;
    _winrateByTurn.clear();
    if (fromContinuation != null &&
        widget.continuationPrefixWinrates != null &&
        widget.continuationPrefixWinrates!.isNotEmpty) {
      _winrateByTurn.addAll(widget.continuationPrefixWinrates!);
    }
    _hintSummary = null;
    _hintLoading = false;
    _ownershipLoading = false;
    _blackBase = Duration.zero;
    _whiteBase = Duration.zero;
    _activeClockStone = null;
    _activeClockStartedAt = null;
    final GoStone toPlay = _game!.toPlay;
    _startClockFor(toPlay);
    _status = _buildOpeningStatus(toPlay);

    if (shouldPersist) {
      unawaited(_persistSession());
    }
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

  /// 续下时：initialTokens 来自开局棋盘，moveTokens 仅新着法；否则来自 handicap + 全部 moves。
  (List<String> initial, List<String> moves) _kataGoTokens() {
    final GoGameState? game = _game;
    if (game == null) return (<String>[], <String>[]);
    return _kataGoTokensForState(game);
  }

  (List<String> initial, List<String> moves) _kataGoTokensForState(
    GoGameState state,
  ) {
    if (_isContinuation && _history.isNotEmpty) {
      final GoGameState start = _history.first;
      final List<String> initial = <String>[];
      for (int y = 0; y < start.boardSize; y++) {
        for (int x = 0; x < start.boardSize; x++) {
          final GoStone? s = start.board[y][x];
          if (s != null) {
            initial.add(
              '${s.sgfColor}:${GoMove(player: s, point: GoPoint(x, y)).toGtp(start.boardSize)}',
            );
          }
        }
      }
      final List<String> moves = state.moves
          .skip(widget.continuationPrefixMoveCount)
          .map((GoMove m) => m.toProtocolToken(widget.boardSize))
          .toList();
      return (initial, moves);
    }
    final List<String> initial = _handicapStones
        .map(
          (GoPoint p) =>
              'B:${GoMove(player: GoStone.black, point: p).toGtp(widget.boardSize)}',
        )
        .toList();
    final List<String> moves = state.moves
        .map((GoMove m) => m.toProtocolToken(widget.boardSize))
        .toList();
    return (initial, moves);
  }

  Future<void> _onBoardTap(GoPoint point) async {
    if (_game == null || _aiThinking || _isGameOver) {
      return;
    }
    if (_tryMode) {
      _pendingConfirmTimer.handleTap(
        point,
        _pendingPoint,
        (GoPoint p) {
          setState(() {
            _pendingPoint = p;
            _status = _t(
              zh: '再次点击同一位置确认落子',
              en: 'Tap the same point again to confirm',
              ja: '同じ点を再タップで確定',
              ko: '같은 점을 다시 눌러 확정',
            );
          });
        },
        (GoPoint p) {
          if (_game == null || _pendingPoint != p) return;
          try {
            final GoGameState next = _game!.play(
              GoMove(player: _game!.toPlay, point: p),
            );
            setState(() {
              _game = next;
              _pendingConfirmTimer.cancel();
              _pendingPoint = null;
              _hintPoints = <GoPoint>[];
              _hintSummary = null;
              _status = _t(
                zh: '试下中（黑白皆可走）',
                en: 'Try mode (both sides playable)',
                ja: '試し打ち中（黒白どちらも可）',
                ko: '시험 수순(흑백 모두 가능)',
              );
            });
            playStoneSound();
          } catch (_) {
            setState(() {
              _pendingPoint = null;
              _status = _t(
                zh: '试下非法落子',
                en: 'Illegal move in try mode',
                ja: '試し打ちで不正着手',
                ko: '시험 수순에서 금수',
              );
            });
          }
        },
      );
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
        _status = _t(
          zh: '非法落子，请重新选择',
          en: 'Illegal move, choose again',
          ja: '不正着手です。再選択してください',
          ko: '금수입니다. 다시 선택하세요',
        );
        _pendingConfirmTimer.cancel();
        _pendingPoint = null;
      });
      return;
    }

    if (_requireDoubleTapConfirm) {
      _pendingConfirmTimer.handleTap(
        point,
        _pendingPoint,
        (GoPoint p) {
          setState(() {
            _pendingPoint = p;
            _status = _t(
              zh: '再次点击同一位置确认落子',
              en: 'Tap the same point again to confirm',
              ja: '同じ点を再タップで確定',
              ko: '같은 점을 다시 눌러 확정',
            );
          });
        },
        (GoPoint p) {
          if (_game == null || _pendingPoint != p || _aiThinking || _isGameOver) {
            return;
          }
          final GoGameState next = _game!.play(GoMove(player: _playerStone, point: p));
          _pendingConfirmTimer.cancel();
          playStoneSound();
          setState(() {
            _applyGame(next);
            _pendingPoint = null;
            _hintPoints = <GoPoint>[];
            _hintSummary = null;
            _status = _t(
              zh: '你已落子，AI思考中...',
              en: 'Move played, AI thinking...',
              ja: '着手完了、AI思考中...',
              ko: '착수 완료, AI 생각 중...',
            );
          });
          unawaited(_persistSession());
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              unawaited(_aiMove());
            }
          });
        },
      );
      return;
    }

    final GoGameState next = _game!.play(probe);
    playStoneSound();
    setState(() {
      _applyGame(next);
      _pendingPoint = null;
      _hintPoints = <GoPoint>[];
      _hintSummary = null;
      _status = _t(
        zh: '你已落子，AI思考中...',
        en: 'Move played, AI thinking...',
        ja: '着手完了、AI思考中...',
        ko: '착수 완료, AI 생각 중...',
      );
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
        _status = _t(
          zh: '试下中：pass',
          en: 'Try mode: pass',
          ja: '試し打ち: パス',
          ko: '시험 수순: 패스',
        );
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
      _pendingConfirmTimer.cancel();
      _pendingPoint = null;
      _status = _t(
        zh: '你选择了 pass',
        en: 'You passed',
        ja: 'あなたはパスしました',
        ko: '당신이 패스했습니다',
      );
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
      _pendingConfirmTimer.cancel();
      _pendingPoint = null;
      _hintPoints = <GoPoint>[];
      _hintSummary = null;
      _status = effectiveProfile.maxVisits < widget.profile.maxVisits
          ? _t(
              zh: 'AI布局快速思考中（V${effectiveProfile.maxVisits}）...',
              en: 'AI opening quick-think (V${effectiveProfile.maxVisits})...',
              ja: 'AI序盤高速思考中（V${effectiveProfile.maxVisits}）...',
              ko: 'AI 초반 빠른 탐색 중(V${effectiveProfile.maxVisits})...',
            )
          : ((widget.profile.maxVisits >= 60 || widget.profile.id == 'master')
                ? _t(
                    zh: 'AI大师思考中（可能较久）...',
                    en: 'Master AI thinking (may take longer)...',
                    ja: 'AI高段思考中（時間がかかる場合があります）...',
                    ko: '마스터 AI 생각 중(시간이 걸릴 수 있음)...',
                  )
                : _t(
                    zh: 'AI思考中...',
                    en: 'AI is thinking...',
                    ja: 'AI思考中...',
                    ko: 'AI 생각 중...',
                  ));
    });
    try {
      final (List<String> initialTokens, List<String> moveTokens) =
          _kataGoTokens();

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
          _resignResultText = _t(
            zh: 'AI认输，你胜',
            en: 'AI resigned, you win',
            ja: 'AIが投了、あなたの勝ち',
            ko: 'AI 기권, 당신 승리',
          );
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

      // 该手胜率用当次分析返回的「最佳一手之后」的胜率，不重复调用分析；补录为当前显示胜率，避免错位
      final double? winrateAfterAi = _winrateAfterBestMove(analyzed);
      if (winrateAfterAi != null) {
        _winrateByTurn[next.moves.length] = winrateAfterAi;
        _blackWinrate = _normalizeBlackWinrate(winrateAfterAi, 0.0);
      }

      setState(() {
        _applyGame(next);
        _status = _t(
          zh: 'AI落子完成，轮到你',
          en: 'AI moved, your turn',
          ja: 'AI着手完了、あなたの番',
          ko: 'AI 착수 완료, 당신 차례',
        );
      });
      unawaited(_persistSession());
      _maybeFinishGame();
    } on PlatformException catch (e) {
      setState(() {
        if (e.code == 'ENGINE_TIMEOUT') {
          _status = _t(
            zh: '分析超时，请选择较低难度或使用性能更好的设备',
            en: 'Analysis timed out. Try a lower difficulty or use a faster device.',
            ja: '解析がタイムアウトしました。難易度を下げるか、性能の良い端末をお試しください。',
            ko: '분석 시간 초과. 난이도를 낮추거나 성능이 좋은 기기를 사용해 보세요.',
          );
        } else {
          final String details = e.details?.toString() ?? '';
          _status =
              '${_t(zh: 'AI分析失败', en: 'AI analysis failed', ja: 'AI解析失敗', ko: 'AI 분석 실패')}: [${e.code}] ${e.message ?? ''} ${details.isEmpty ? '' : '| $details'}';
        }
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

  /// 当次分析结果中「最佳一手之后」的黑方胜率（来自 topCandidates），无则返回 null。
  double? _winrateAfterBestMove(KatagoAnalyzeResult analyzed) {
    if (analyzed.topCandidates.isEmpty) return null;
    for (final KatagoMoveCandidate c in analyzed.topCandidates) {
      if (c.move == analyzed.bestMove) return c.blackWinrate;
    }
    return analyzed.topCandidates.first.blackWinrate;
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
  /// 若已认输则不再覆盖结局。
  Future<void> _finishGameWithOwnership() async {
    if (_game == null || _game!.consecutivePasses < 2) {
      return;
    }
    if (_resignResultText != null) {
      return;
    }
    setState(() {
      _status = _t(
        zh: '正在分析终局...',
        en: 'Analyzing endgame...',
        ja: '終局解析中...',
        ko: '종국 분석 중...',
      );
    });
    try {
      final (List<String> initialTokens, List<String> moveTokens) =
          _kataGoTokens();
      final AnalysisProfile profile = _effectiveProfileForTurn(
        _game!.moves.length,
      );
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
      final double blackWr = _normalizeBlackWinrate(res.winrate, res.scoreLead);
      final double leadForBlack = _game!.toPlay == GoStone.black
          ? res.scoreLead
          : -res.scoreLead;
      String resultText;
      if (blackWr > 0.5) {
        resultText = _t(
          zh: '黑胜 ${leadForBlack.clamp(0.0, double.infinity).toStringAsFixed(1)} 目',
          en: 'Black wins by ${leadForBlack.clamp(0.0, double.infinity).toStringAsFixed(1)}',
          ja: '黒 ${leadForBlack.clamp(0.0, double.infinity).toStringAsFixed(1)}目勝ち',
          ko: '흑 ${leadForBlack.clamp(0.0, double.infinity).toStringAsFixed(1)}집 승',
        );
      } else if (blackWr < 0.5) {
        resultText = _t(
          zh: '白胜 ${(-leadForBlack).clamp(0.0, double.infinity).toStringAsFixed(1)} 目',
          en: 'White wins by ${(-leadForBlack).clamp(0.0, double.infinity).toStringAsFixed(1)}',
          ja: '白 ${(-leadForBlack).clamp(0.0, double.infinity).toStringAsFixed(1)}目勝ち',
          ko: '백 ${(-leadForBlack).clamp(0.0, double.infinity).toStringAsFixed(1)}집 승',
        );
      } else {
        resultText = _t(zh: '和棋', en: 'Draw', ja: '持碁', ko: '무승부');
      }
      final GoScore? score = _scoreFromOwnership(res.ownership);
      if (mounted) {
        setState(() {
          _finalScore = score ?? _game!.scoreByRules(_rules);
          _finalResultTextFromAnalysis = resultText;
          _status =
              '${_t(zh: '终局', en: 'Game over', ja: '終局', ko: '종국')}: $resultText';
        });
        unawaited(_persistSession());
      }
    } on PlatformException catch (e) {
      if (mounted) {
        setState(() {
          _finalScore = _game!.scoreByRules(_rules);
          _finalResultTextFromAnalysis = null;
          _status = e.code == 'ENGINE_TIMEOUT'
              ? _t(
                  zh: '分析超时，请选择较低难度或使用性能更好的设备',
                  en: 'Analysis timed out. Try a lower difficulty or use a faster device.',
                  ja: '解析がタイムアウトしました。難易度を下げるか、性能の良い端末をお試しください。',
                  ko: '분석 시간 초과. 난이도를 낮추거나 성능이 좋은 기기를 사용해 보세요.',
                )
              : _t(
                  zh: '终局: 分析失败（仅显示数目）',
                  en: 'Game over: analysis failed (count only)',
                  ja: '終局: 解析失敗（目数のみ）',
                  ko: '종국: 분석 실패(집계만)',
                );
        });
        unawaited(_persistSession());
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _finalScore = _game!.scoreByRules(_rules);
          _finalResultTextFromAnalysis = null;
          _status = _t(
            zh: '终局: 分析失败（仅显示数目）',
            en: 'Game over: analysis failed (count only)',
            ja: '終局: 解析失敗（目数のみ）',
            ko: '종국: 분석 실패(집계만)',
          );
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
    final double blackArea =
        (livingBlackStones + blackTerritory + deadWhiteInBlack).toDouble();
    final double whiteArea =
        (livingWhiteStones + whiteTerritory + deadBlackInWhite).toDouble() +
        _rules.komi;
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
      _pendingConfirmTimer.cancel();
      _pendingPoint = null;
      _finalScore = null;
      _finalResultTextFromAnalysis = null;
      _resignResultText = null;
      _status = _t(
        zh: '已悔棋',
        en: 'Undo completed',
        ja: '一手戻しました',
        ko: '되돌리기 완료',
      );
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
      return _t(zh: '猜先', en: 'Random first', ja: '先後ランダム', ko: '선후 랜덤');
    }
    if (widget.handicap == 1) {
      return _t(zh: '让先', en: 'Sen', ja: '互先', ko: '호선');
    }
    return _t(
      zh: '让${widget.handicap}子',
      en: 'Handicap ${widget.handicap}',
      ja: '${widget.handicap}子局',
      ko: '${widget.handicap}점 접바둑',
    );
  }

  String _buildOpeningStatus(GoStone toPlay) {
    return widget.handicap > 0
        ? _t(
            zh: '$_handicapLabel，贴目${_rules.komi.toStringAsFixed(1)}，你执黑，${toPlay == _playerStone ? '请落子' : 'AI先行'}',
            en: '$_handicapLabel, komi ${_rules.komi.toStringAsFixed(1)}, you are Black, ${toPlay == _playerStone ? 'your move' : 'AI first'}',
            ja: '$_handicapLabel、コミ${_rules.komi.toStringAsFixed(1)}、あなたは黒、${toPlay == _playerStone ? '着手してください' : 'AI先手'}',
            ko: '$_handicapLabel, 덤 ${_rules.komi.toStringAsFixed(1)}, 당신은 흑, ${toPlay == _playerStone ? '착수하세요' : 'AI 선착'}',
          )
        : _t(
            zh: '$_handicapLabel，你执${_playerStone == GoStone.black ? '黑' : '白'}，${toPlay == _playerStone ? '请落子' : 'AI先行'}',
            en: '$_handicapLabel, you are ${_playerStone == GoStone.black ? 'Black' : 'White'}, ${toPlay == _playerStone ? 'your move' : 'AI first'}',
            ja: '$_handicapLabel、あなたは${_playerStone == GoStone.black ? '黒' : '白'}、${toPlay == _playerStone ? '着手してください' : 'AI先手'}',
            ko: '$_handicapLabel, 당신은 ${_playerStone == GoStone.black ? '흑' : '백'}, ${toPlay == _playerStone ? '착수하세요' : 'AI 선착'}',
          );
  }

  String _localizedStatusForCurrentState(GoGameState state) {
    if (_isGameOver) {
      return _resignResultText ??
          _t(zh: '终局', en: 'Game over', ja: '終局', ko: '종국');
    }
    if (_aiThinking) {
      return _t(
        zh: 'AI思考中...',
        en: 'AI is thinking...',
        ja: 'AI思考中...',
        ko: 'AI 생각 중...',
      );
    }
    return state.toPlay == _playerStone
        ? _t(zh: '轮到你落子', en: 'Your move', ja: 'あなたの番', ko: '당신 차례')
        : _t(zh: '轮到AI落子', en: 'AI turn', ja: 'AIの番', ko: 'AI 차례');
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
      _resignResultText = _t(
        zh: '你认输，AI胜',
        en: 'You resigned, AI wins',
        ja: 'あなたが投了、AI勝ち',
        ko: '당신 기권, AI 승리',
      );
      _status = _resignResultText!;
    });
    await _persistSession();
  }

  String _toSgf() {
    final StringBuffer sb = StringBuffer();
    final String result =
        _resignResultText ??
        (_finalScore != null ? (_finalResultTextFromAnalysis ?? '?') : '?');
    sb.write('(;GM[1]FF[4]');
    sb.write('SZ[${widget.boardSize}]');
    final bool useOriginalRoot = widget.continuationOriginalKomi != null;
    if (useOriginalRoot) {
      sb.write('KM[${widget.continuationOriginalKomi}]');
      sb.write('RU[${widget.continuationOriginalRuleset ?? _rules.ruleset}]');
      for (final GoPoint p in widget.continuationOriginalInitialBlack ?? <GoPoint>[]) {
        sb.write('AB[${_toSgfCoord(p)}]');
      }
      for (final GoPoint p in widget.continuationOriginalInitialWhite ?? <GoPoint>[]) {
        sb.write('AW[${_toSgfCoord(p)}]');
      }
    } else {
      sb.write('KM[${_rules.komi}]');
      sb.write('RU[${_rules.ruleset}]');
      if (_isContinuation && _history.isNotEmpty) {
        final GoGameState start = _history.first;
        for (int y = 0; y < start.boardSize; y++) {
          for (int x = 0; x < start.boardSize; x++) {
            final GoStone? s = start.board[y][x];
            if (s != null) {
              if (s == GoStone.black) {
                sb.write('AB[${_toSgfCoord(GoPoint(x, y))}]');
              } else {
                sb.write('AW[${_toSgfCoord(GoPoint(x, y))}]');
              }
            }
          }
        }
      } else if (widget.handicap > 0) {
        sb.write('HA[${widget.handicap}]');
        for (final GoPoint p in _handicapStones) {
          sb.write('AB[${_toSgfCoord(p)}]');
        }
      }
    }
    sb.write('PB[Player]');
    sb.write('PW[MasterGo AI]');
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

  /// 拍照续下时把开局局面编码进 session，保证记录中有完整开局棋局。
  /// 同时 _toSgf() 会把开局写入 SGF 根节点 AB/AW，便于导出/重装后仅凭 SGF 恢复开局。
  List<Map<String, dynamic>> _encodeInitialStonesFromState(GoGameState state) {
    final List<Map<String, dynamic>> list = <Map<String, dynamic>>[];
    for (int y = 0; y < state.boardSize; y++) {
      for (int x = 0; x < state.boardSize; x++) {
        final GoStone? s = state.board[y][x];
        if (s != null) {
          list.add(<String, dynamic>{
            'player': s.name,
            'x': x,
            'y': y,
          });
        }
      }
    }
    return list;
  }

  Future<void> _persistSession() async {
    final GoGameState? game = _game;
    if (game == null) return;
    if (_isContinuation && _newMoveCount <= 20) {
      return;
    }
    final int now = DateTime.now().millisecondsSinceEpoch;
    final int createdAt = _recordCreatedAtMs ?? now;
    // 续下时只保存到实际手数，避免胜率曲线超出新棋谱长度（如原谱200手，从100续下到150则只保留1..150）
    final int maxTurn = game.moves.length;
    final Map<int, double> winrateTrimmed = <int, double>{
      for (final MapEntry<int, double> e in _winrateByTurn.entries)
        if (e.key >= 1 && e.key <= maxTurn) e.key: e.value,
    };
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
      // 续下（含打谱续下）都保存起始局面，恢复对局时才能正确还原
      if (_isContinuation && _history.isNotEmpty)
        'initialStones': _encodeInitialStonesFromState(_history.first),
      'winrateByTurn': winrateTrimmed.map(
        (int k, double v) => MapEntry<String, dynamic>(k.toString(), v),
      ),
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
    final int effectiveMoveCount =
        _isContinuation ? _newMoveCount : game.moves.length;
    final String source = effectiveMoveCount > 20
        ? 'battle_local'
        : 'battle_temp';
    final GameRecord record = GameRecord(
      id: id,
      source: source,
      title: _t(
        zh: 'AI对弈 ${widget.boardSize}路 ${widget.profile.name}',
        en: 'AI Play ${widget.boardSize}x${widget.boardSize} ${widget.profile.name}',
        ja: 'AI対局 ${widget.boardSize}路 ${widget.profile.name}',
        ko: 'AI 대국 ${widget.boardSize}로 ${widget.profile.name}',
      ),
      boardSize: widget.boardSize,
      ruleset: _rules.ruleset,
      komi: _rules.komi,
      sgf: _toSgf(),
      status: _isGameOver ? 'finished' : 'active',
      sessionJson: jsonEncode(data),
      winrateJson: jsonEncode(
        winrateTrimmed.map(
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
    if (widget.initialGameState != null) {
      debugPrint('[恢复对局] _restoreSession 跳过: 本页为续下入口 (initialGameState 非空)');
      return false;
    }
    final String? preferredId = widget.preferredRestoreRecordId;
    if (preferredId != null && preferredId.isNotEmpty) {
      debugPrint('[恢复对局] _restoreSession 优先恢复 preferredId=$preferredId');
      final GameRecord? preferred = await _recordRepository.loadById(
        preferredId,
      );
      if (preferred == null) {
        debugPrint('[恢复对局] _restoreSession 失败: loadById(preferredId) 返回 null，不尝试其他记录');
        return false;
      }
      final bool ok = await _tryRestoreFromRecord(preferred);
      debugPrint('[恢复对局] _restoreSession _tryRestoreFromRecord(preferred) => $ok');
      if (ok) return true;
      debugPrint('[恢复对局] _restoreSession 指定记录未恢复成功，不尝试其他记录');
      return false;
    }

    final GameRecord? local = await _recordRepository.loadLatestBySource(
      'battle_local',
    );
    final GameRecord? temp = await _recordRepository.loadLatestBySource(
      'battle_temp',
    );
    final List<GameRecord> candidates =
        <GameRecord>[if (local != null) local, if (temp != null) temp]
          ..removeWhere((GameRecord r) => r.id == preferredId)
          ..sort(
            (GameRecord a, GameRecord b) =>
                b.updatedAtMs.compareTo(a.updatedAtMs),
          );

    debugPrint('[恢复对局] _restoreSession 候选记录数=${candidates.length}');
    for (final GameRecord record in candidates) {
      final bool restored = await _tryRestoreFromRecord(record);
      debugPrint('[恢复对局] _restoreSession 尝试候选 id=${record.id} => $restored');
      if (restored) {
        return true;
      }
    }
    debugPrint('[恢复对局] _restoreSession 无任何记录恢复成功');
    return false;
  }

  Future<bool> _tryRestoreFromRecord(GameRecord record) async {
    debugPrint('[恢复对局] _tryRestoreFromRecord 记录 id=${record.id} status=${record.status} sessionLen=${record.sessionJson.length}');
    if (record.sessionJson.isEmpty || record.status == 'finished') {
      debugPrint('[恢复对局] _tryRestoreFromRecord 失败: session 为空或已终局 (sessionEmpty=${record.sessionJson.isEmpty} status=${record.status})');
      return false;
    }
    try {
      final Map<String, dynamic> data =
          jsonDecode(record.sessionJson) as Map<String, dynamic>;
      if (data['finalScore'] != null ||
          (data['resignResult'] as String?) != null) {
        debugPrint('[恢复对局] _tryRestoreFromRecord 失败: 已终局 (finalScore=${data['finalScore'] != null} resignResult=${data['resignResult'] != null})');
        return false;
      }
      final int boardSize =
          (data['boardSize'] as num?)?.toInt() ?? record.boardSize;
      final int handicap = (data['handicap'] as num?)?.toInt() ?? 0;
      final String restoredRuleset =
          (data['ruleset'] as String?) ?? record.ruleset;
      final double restoredKomi =
          (data['komi'] as num?)?.toDouble() ?? record.komi;
      final String expectedRuleset = widget.rules.ruleset;
      final double expectedKomi = widget.handicap > 0 ? 0 : widget.rules.komi;
      final bool sameConfig =
          boardSize == widget.boardSize &&
          handicap == widget.handicap &&
          restoredRuleset == expectedRuleset &&
          (restoredKomi - expectedKomi).abs() < 0.01;
      if (!sameConfig) {
        debugPrint('[恢复对局] _tryRestoreFromRecord 失败: 配置不一致 '
            'session(boardSize=$boardSize handicap=$handicap ruleset=$restoredRuleset komi=$restoredKomi) '
            'widget(boardSize=${widget.boardSize} handicap=${widget.handicap} ruleset=$expectedRuleset komi=$expectedKomi)');
        return false;
      }
      _recordId = record.id;
      _recordCreatedAtMs = record.createdAtMs;
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
      List<GoPoint> handicapStones = _buildHandicapPoints(
        boardSize,
        handicap,
      );
      final List<dynamic>? rawInitialStones =
          data['initialStones'] as List<dynamic>?;
      final GoStone toPlay;
      if (rawInitialStones != null && rawInitialStones.isNotEmpty) {
        for (final dynamic item in rawInitialStones) {
          final Map<String, dynamic> s = item as Map<String, dynamic>;
          final String player = s['player'] as String? ?? 'black';
          final int? x = (s['x'] as num?)?.toInt();
          final int? y = (s['y'] as num?)?.toInt();
          if (x != null && y != null &&
              x >= 0 && x < boardSize && y >= 0 && y < boardSize) {
            board[y][x] = player == 'white' ? GoStone.white : GoStone.black;
          }
        }
        handicapStones = <GoPoint>[];
        toPlay = _playerStone;
      } else {
        for (final GoPoint p in handicapStones) {
          board[p.y][p.x] = GoStone.black;
        }
        toPlay = handicapStones.isEmpty
            ? GoStone.black
            : GoStone.white;
      }
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
      final int initialStonesCount = rawInitialStones != null && rawInitialStones.isNotEmpty ? rawInitialStones.length : 0;
      debugPrint('[恢复对局] _tryRestoreFromRecord 成功 id=${record.id} moves=${state.moves.length} initialStones=$initialStonesCount');
      _pendingConfirmTimer.cancel();
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
      _status = _localizedStatusForCurrentState(state);
      return true;
    } catch (e, st) {
      debugPrint('[恢复对局] _tryRestoreFromRecord 失败: 异常 $e\n$st');
      return false;
    }
  }

  Future<List<_HintPointInfo>> _requestHintPointsForState(
    GoGameState state,
  ) async {
    final (List<String> initialTokens, List<String> moveTokens) =
        _kataGoTokensForState(state);
    // 提示与当前对局难度一致，直接使用当前档位配置（避免硬编码档位数值）。
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
        profile: widget.profile,
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
    if (state == null || _aiThinking || _isGameOver || _hintLoading) {
      return;
    }
    setState(() {
      _hintLoading = true;
      _status = _t(
        zh: '正在计算提示点...',
        en: 'Calculating hint points...',
        ja: '候補手を計算中...',
        ko: '추천 수 계산 중...',
      );
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
        _status = hints.isEmpty
            ? _t(
                zh: '暂无可用提示点',
                en: 'No available hint points',
                ja: '候補手はありません',
                ko: '사용 가능한 추천 수가 없습니다',
              )
            : _t(
                zh: '提示点已标注（${hints.length}个）',
                en: 'Hint points marked (${hints.length})',
                ja: '候補手を表示しました（${hints.length}件）',
                ko: '추천 수 표시 완료(${hints.length}개)',
              );
      });
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() {
        _status = e.code == 'ENGINE_TIMEOUT'
            ? _t(
                zh: '分析超时，请选择较低难度或使用性能更好的设备',
                en: 'Analysis timed out. Try a lower difficulty or use a faster device.',
                ja: '解析がタイムアウトしました。難易度を下げるか、性能の良い端末をお試しください。',
                ko: '분석 시간 초과. 난이도를 낮추거나 성능이 좋은 기기를 사용해 보세요.',
              )
            : '${_t(zh: '提示失败', en: 'Hint failed', ja: '候補手取得失敗', ko: '추천 수 실패')}: ${e.message ?? e.code}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _status =
            '${_t(zh: '提示失败', en: 'Hint failed', ja: '候補手取得失敗', ko: '추천 수 실패')}: $e';
      });
    } finally {
      if (!mounted) return;
      setState(() {
        _hintLoading = false;
      });
    }
  }

  /// 对任意局面请求势力/目数分析，供对局中与复盘共用。
  Future<KatagoAnalyzeResult> _requestOwnershipAnalysis(GoGameState state) {
    final (List<String> initialTokens, List<String> moveTokens) =
        _kataGoTokensForState(state);
    final AnalysisProfile profile = _effectiveProfileForTurn(
      state.moves.length,
    );
    // 局势分析：快速档 10s 思考，超时 = 2×（与原则一致）。
    final AnalysisProfile ownershipProfile = AnalysisProfile(
      id: '${profile.id}-ownership-fast',
      name: profile.name,
      description: profile.description,
      maxVisits: 20,
      thinkingTimeMs: 10000,
      includeOwnership: true,
    );
    final int timeoutMs = _timeoutBudgetMsForProfile(ownershipProfile);
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
    if (state == null || _aiThinking || _isGameOver || _ownershipLoading) {
      return;
    }
    setState(() {
      _ownershipLoading = true;
      _status = _t(
        zh: '正在分析局势...',
        en: 'Analyzing position...',
        ja: '局勢解析中...',
        ko: '형세 분석 중...',
      );
    });
    try {
      final KatagoAnalyzeResult res = await _requestOwnershipAnalysis(state);
      if (!mounted) {
        return;
      }
      setState(() {
        _status = _t(
          zh: '分析完成',
          en: 'Analysis complete',
          ja: '解析完了',
          ko: '분석 완료',
        );
      });
      if (!mounted) {
        return;
      }
      _showOwnershipResultSheet(
        context,
        state,
        res,
        lastMovePoint: _lastMovePoint(),
      );
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() {
        _status = e.code == 'ENGINE_TIMEOUT'
            ? _t(
                zh: '分析超时，请选择较低难度或使用性能更好的设备',
                en: 'Analysis timed out. Try a lower difficulty or use a faster device.',
                ja: '解析がタイムアウトしました。難易度を下げるか、性能の良い端末をお試しください。',
                ko: '분석 시간 초과. 난이도를 낮추거나 성능이 좋은 기기를 사용해 보세요.',
              )
            : '${_t(zh: '局势分析失败', en: 'Position analysis failed', ja: '局勢解析失敗', ko: '형세 분석 실패')}: ${e.message ?? e.code}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _status =
            '${_t(zh: '局势分析失败', en: 'Position analysis failed', ja: '局勢解析失敗', ko: '형세 분석 실패')}: $e';
      });
    } finally {
      if (!mounted) return;
      setState(() {
        _ownershipLoading = false;
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
      _pendingConfirmTimer.cancel();
      _pendingPoint = null;
      _hintPoints = <GoPoint>[];
      _hintSummary = null;
      _status = _t(
        zh: '试下模式：可同时走黑白，结束后返回实战局面',
        en: 'Try mode: both sides playable; exit to return',
        ja: '試し打ち: 黒白どちらも可、終了で実戦局面へ',
        ko: '시험 수순: 흑백 모두 가능, 종료 시 실전으로 복귀',
      );
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
      _pendingConfirmTimer.cancel();
      _pendingPoint = null;
      _hintPoints = <GoPoint>[];
      _hintSummary = null;
      _status =
          _tryBaseStatus ??
          _t(zh: '已结束试下', en: 'Try mode ended', ja: '試し打ち終了', ko: '시험 수순 종료');
    });
  }

  List<String> _buildHints({required bool good}) {
    final bool firstMoveIsBlack = widget.handicap == 0;
    final List<MoveHint> hints = _analysisService.buildHints(
      _winrateByTurn,
      playerStone: _playerStone,
      firstMoveIsBlack: firstMoveIsBlack,
      brilliantEpsilon: 0.05,
    );
    return hints
        .where(
          (MoveHint h) =>
              good ? h.kind == HintKind.brilliant : h.kind == HintKind.blunder,
        )
        .map(
          (MoveHint h) => _t(
            zh: '第${h.turn}手后玩家胜率 ${(h.deltaPlayerWinrate * 100).toStringAsFixed(1)}%',
            en: 'After move ${h.turn}, player winrate ${(h.deltaPlayerWinrate * 100).toStringAsFixed(1)}%',
            ja: '${h.turn}手後のプレイヤー勝率 ${(h.deltaPlayerWinrate * 100).toStringAsFixed(1)}%',
            ko: '${h.turn}수 후 플레이어 승률 ${(h.deltaPlayerWinrate * 100).toStringAsFixed(1)}%',
          ),
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
                      title: _s.pick(
                        zh: '复盘',
                        en: 'Review',
                        ja: '復盤',
                        ko: '복기',
                      ),
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
                          reviewHints = hints
                              .map((_HintPointInfo h) => h.point)
                              .toList();
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
                              SnackBar(
                                content: Text(
                                  '${_t(zh: '局势分析失败', en: 'Position analysis failed', ja: '局勢解析失敗', ko: '형세 분석 실패')}: $e',
                                ),
                              ),
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
                            child: Text(
                              _t(
                                zh: '当前手数: $turn/${moves.length}',
                                en: 'Turn: $turn/${moves.length}',
                                ja: '手数: $turn/${moves.length}',
                                ko: '수순: $turn/${moves.length}',
                              ),
                            ),
                          ),
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
                                final double player =
                                    _playerStone == GoStone.black
                                    ? black
                                    : (1.0 - black);
                                return _t(
                                  zh: '第$turn手玩家胜率: ${(player * 100).toStringAsFixed(1)}%',
                                  en: 'Turn $turn player winrate: ${(player * 100).toStringAsFixed(1)}%',
                                  ja: '$turn手のプレイヤー勝率: ${(player * 100).toStringAsFixed(1)}%',
                                  ko: '$turn수 플레이어 승률: ${(player * 100).toStringAsFixed(1)}%',
                                );
                              }()),
                            ),
                          const SizedBox(height: 8),
                          Text(
                            _t(
                              zh: '妙手提示',
                              en: 'Brilliant Moves',
                              ja: '妙手',
                              ko: '묘수',
                            ),
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          if (good.isEmpty)
                            Text(
                              _t(
                                zh: '暂无明显妙手',
                                en: 'No obvious brilliant move',
                                ja: '目立つ妙手はありません',
                                ko: '뚜렷한 묘수가 없습니다',
                              ),
                            )
                          else
                            ...good.map(Text.new),
                          const SizedBox(height: 8),
                          Text(
                            _t(zh: '恶手提示', en: 'Blunders', ja: '悪手', ko: '악수'),
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          if (bad.isEmpty)
                            Text(
                              _t(
                                zh: '暂无明显恶手',
                                en: 'No obvious blunder',
                                ja: '目立つ悪手はありません',
                                ko: '뚜렷한 악수가 없습니다',
                              ),
                            )
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
    final Size screenSize = MediaQuery.sizeOf(context);
    final bool useLandscapeSplit =
        screenSize.width > screenSize.height && screenSize.width >= 700;
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
                _t(
                  zh: '难度:${_s.aiProfileName(widget.profile.id, widget.profile.name)}  规则:$_handicapLabel  胜率:$winrateText',
                  en: 'Level:${_s.aiProfileName(widget.profile.id, widget.profile.name)}  Rule:$_handicapLabel  Winrate:$winrateText',
                  ja: '難易度:${_s.aiProfileName(widget.profile.id, widget.profile.name)}  ルール:$_handicapLabel  勝率:$winrateText',
                  ko: '난이도:${_s.aiProfileName(widget.profile.id, widget.profile.name)}  규칙:$_handicapLabel  승률:$winrateText',
                ),
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
              child: Builder(
                builder: (BuildContext context) {
                  final Widget board = Padding(
                    padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
                    child: GoBoardWidget(
                      boardSize: game.boardSize,
                      board: game.board,
                      onTapPoint: _onBoardTap,
                      lastMovePoint: _lastMovePoint(),
                      tentativePoint: _pendingPoint,
                      tentativeStone: _pendingPoint == null
                          ? null
                          : (_tryMode ? _game?.toPlay : _playerStone),
                      hintPoints: _hintPoints,
                      padding: 14,
                    ),
                  );

                  final Widget panelContent = Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        _t(
                          zh: '当前落子: ${game.toPlay == GoStone.black ? '黑' : '白'}${_aiThinking ? '（AI思考中）' : ''}',
                          en: 'To play: ${game.toPlay == GoStone.black ? 'Black' : 'White'}${_aiThinking ? ' (AI thinking)' : ''}',
                          ja: '手番: ${game.toPlay == GoStone.black ? '黒' : '白'}${_aiThinking ? '（AI思考中）' : ''}',
                          ko: '현재 차례: ${game.toPlay == GoStone.black ? '흑' : '백'}${_aiThinking ? ' (AI 생각 중)' : ''}',
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _engineReady
                            ? _status
                            : _t(
                                zh: '启动引擎中…',
                                en: 'Starting engine...',
                                ja: 'エンジン起動中…',
                                ko: '엔진 시작 중…',
                              ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (_hintSummary != null) ...<Widget>[
                        const SizedBox(height: 4),
                        Text(
                          _t(
                            zh: '提示胜率: $_hintSummary',
                            en: 'Hint winrate: $_hintSummary',
                            ja: '候補手勝率: $_hintSummary',
                            ko: '추천 수 승률: $_hintSummary',
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ],
                      if (_finalScore != null) ...<Widget>[
                        const SizedBox(height: 4),
                        Text(
                          _finalResultTextFromAnalysis != null
                              ? _t(
                                  zh: '终局结果: $_finalResultTextFromAnalysis（黑地${_finalScore!.blackTerritory}，白地${_finalScore!.whiteTerritory}）',
                                  en: 'Result: $_finalResultTextFromAnalysis (B territory ${_finalScore!.blackTerritory}, W territory ${_finalScore!.whiteTerritory})',
                                  ja: '終局結果: $_finalResultTextFromAnalysis（黒地${_finalScore!.blackTerritory}、白地${_finalScore!.whiteTerritory}）',
                                  ko: '종국 결과: $_finalResultTextFromAnalysis (흑 집 ${_finalScore!.blackTerritory}, 백 집 ${_finalScore!.whiteTerritory})',
                                )
                              : _t(
                                  zh: '终局结果: 分析失败（黑地${_finalScore!.blackTerritory}，白地${_finalScore!.whiteTerritory}）',
                                  en: 'Result: analysis failed (B territory ${_finalScore!.blackTerritory}, W territory ${_finalScore!.whiteTerritory})',
                                  ja: '終局結果: 解析失敗（黒地${_finalScore!.blackTerritory}、白地${_finalScore!.whiteTerritory}）',
                                  ko: '종국 결과: 분석 실패 (흑 집 ${_finalScore!.blackTerritory}, 백 집 ${_finalScore!.whiteTerritory})',
                                ),
                        ),
                      ],
                      if (_resignResultText != null) ...<Widget>[
                        const SizedBox(height: 4),
                        Text(
                          _t(
                            zh: '终局结果: $_resignResultText',
                            en: 'Result: $_resignResultText',
                            ja: '終局結果: $_resignResultText',
                            ko: '종국 결과: $_resignResultText',
                          ),
                        ),
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
                            _tryMode
                                ? _t(
                                    zh: '结束试下',
                                    en: 'End Try',
                                    ja: '試し打ち終了',
                                    ko: '시험 종료',
                                  )
                                : _t(
                                    zh: '试下',
                                    en: 'Try',
                                    ja: '試し打ち',
                                    ko: '시험 수순',
                                  ),
                          ),
                          compactBtn(
                            (_engineReady &&
                                    !_isGameOver &&
                                    !_aiThinking &&
                                    !_hintLoading &&
                                    !_ownershipLoading)
                                ? _showHintPoints
                                : null,
                            _hintLoading
                                ? _t(
                                    zh: '提示中...',
                                    en: 'Hinting...',
                                    ja: 'ヒント中...',
                                    ko: '힌트 중...',
                                  )
                                : _t(zh: '提示', en: 'Hint', ja: 'ヒント', ko: '힌트'),
                          ),
                          compactBtn(
                            (_engineReady &&
                                    !_isGameOver &&
                                    !_aiThinking &&
                                    !_hintLoading &&
                                    !_ownershipLoading)
                                ? _showPositionAnalysis
                                : null,
                            _ownershipLoading
                                ? _t(
                                    zh: '分析中...',
                                    en: 'Analyzing...',
                                    ja: '解析中...',
                                    ko: '분석 중...',
                                  )
                                : _t(
                                    zh: '局势分析',
                                    en: 'Position',
                                    ja: '局勢解析',
                                    ko: '형세 분석',
                                  ),
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
                            (_history.length > 1 && !_aiThinking)
                                ? _undo
                                : null,
                            _t(zh: '悔棋', en: 'Undo', ja: '待った', ko: '되돌리기'),
                          ),
                          compactBtn(
                            (!_isGameOver && !_aiThinking)
                                ? _playerResign
                                : null,
                            _t(zh: '认输', en: 'Resign', ja: '投了', ko: '기권'),
                          ),
                          compactBtn(
                            _isGameOver ? _showReviewSheet : null,
                            _t(zh: '复盘', en: 'Review', ja: '復盤', ko: '복기'),
                          ),
                          compactBtn(
                            () => Navigator.of(context).pop(),
                            _t(zh: '返回', en: 'Back', ja: '戻る', ko: '뒤로'),
                          ),
                        ],
                      ),
                    ],
                  );

                  if (useLandscapeSplit) {
                    return Row(
                      children: <Widget>[
                        Expanded(child: board),
                        Container(
                          width: 320,
                          padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
                          decoration: BoxDecoration(
                            border: Border(
                              left: BorderSide(color: Colors.black12),
                            ),
                            color: Colors.white,
                          ),
                          child: SingleChildScrollView(child: panelContent),
                        ),
                      ],
                    );
                  }

                  return Column(
                    children: <Widget>[
                      Expanded(child: board),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                        decoration: BoxDecoration(
                          border: Border(
                            top: BorderSide(color: Colors.black12),
                          ),
                          color: Colors.white,
                        ),
                        child: panelContent,
                      ),
                    ],
                  );
                },
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
