import 'dart:async';
import 'dart:developer' as developer;
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mastergo/domain/entities/analysis_profile.dart';
import 'package:mastergo/domain/entities/game_rules.dart';
import 'package:mastergo/domain/entities/game_setup.dart';
import 'package:mastergo/domain/go/go_game.dart';
import 'package:mastergo/domain/go/go_types.dart';
import 'package:mastergo/features/common/go_board_widget.dart';
import 'package:mastergo/infra/config/ai_profile_repository.dart';
import 'package:mastergo/infra/engine/katago/katago_adapter.dart';

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
  String? _selectedProfileId;
  String? _engineStatus;
  String? _engineDiagnostics;
  bool _checkingEngine = false;

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

  Future<void> _checkEngine() async {
    setState(() {
      _checkingEngine = true;
      _engineStatus = null;
      _engineDiagnostics = null;
    });
    try {
      await _katagoAdapter.ensureStarted();
      if (!mounted) {
        return;
      }
      setState(() {
        _engineStatus = '引擎已连接，可开始对弈';
        _engineDiagnostics = 'checkEngine: engine started + warmup passed';
      });
    } on PlatformException catch (e) {
      if (!mounted) {
        return;
      }
      final String formatted = _formatPlatformError(e);
      setState(() {
        _engineStatus = '引擎未就绪: $formatted';
        _engineDiagnostics = formatted;
      });
      developer.log(
        'KataGo checkEngine error: code=${e.code}, message=${e.message}, details=${e.details}',
        name: 'mastergo.katago',
      );
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _engineStatus = '引擎未就绪: $e';
        _engineDiagnostics = e.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _checkingEngine = false;
        });
      }
    }
  }

  Future<void> _startBattle(AnalysisProfile profile) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => _AIBattlePage(
          adapter: _katagoAdapter,
          profile: profile,
          boardSize: _boardSize,
          handicap: _handicap,
          randomFirst: _guessFirst,
        ),
      ),
    );
  }

  String _formatPlatformError(PlatformException e) {
    final String message = e.message ?? '';
    final String details = e.details?.toString() ?? '';
    return '[${e.code}] $message${details.isNotEmpty ? ' | $details' : ''}';
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<AnalysisProfile>>(
      future: _profileRepository.loadProfiles(),
      builder: (BuildContext context, AsyncSnapshot<List<AnalysisProfile>> snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return Center(child: Text('加载难度配置失败: ${snap.error}'));
        }
        final List<AnalysisProfile> profiles = snap.data ?? <AnalysisProfile>[];
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
                return DropdownMenuItem<int>(value: s, child: Text('$s x $s'));
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
                return DropdownMenuItem<String>(value: p.id, child: Text(p.name));
              }).toList(),
              onChanged: (String? id) {
                setState(() {
                  _selectedProfileId = id;
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
            Text('让子: $_handicap'),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('猜先（随机先后）'),
              subtitle: const Text('开启后随机分配你执黑或执白'),
              value: _guessFirst,
              onChanged: (bool value) {
                setState(() {
                  _guessFirst = value;
                });
              },
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _checkingEngine ? null : _checkEngine,
              icon: _checkingEngine
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.memory),
              label: const Text('检测引擎连通性'),
            ),
            if (_engineStatus != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(_engineStatus!),
            ],
            if (_engineDiagnostics != null &&
                _engineDiagnostics!.isNotEmpty) ...<Widget>[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.black12),
                  borderRadius: BorderRadius.circular(8),
                  color: Colors.black.withValues(alpha: 0.03),
                ),
                child: SelectableText(
                  _engineDiagnostics!,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ],
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: selected == null ? null : () => _startBattle(selected),
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
  });

  final KatagoAdapter adapter;
  final AnalysisProfile profile;
  final int boardSize;
  final int handicap;
  final bool randomFirst;

  @override
  State<_AIBattlePage> createState() => _AIBattlePageState();
}

class _AIBattlePageState extends State<_AIBattlePage> {
  GoGameState? _game;
  final List<GoGameState> _history = <GoGameState>[];
  List<GoPoint> _handicapStones = <GoPoint>[];
  GoScore? _finalScore;
  GoPoint? _pendingPoint;
  GoStone _playerStone = GoStone.black;
  GoStone _aiStone = GoStone.white;
  bool _aiThinking = false;
  String _status = '准备中...';
  double? _blackWinrate;

  Duration _blackBase = Duration.zero;
  Duration _whiteBase = Duration.zero;
  GoStone? _activeClockStone;
  DateTime? _activeClockStartedAt;
  Timer? _ticker;

  int _timeoutBudgetMs() {
    if (widget.profile.id == 'advanced') {
      return max(120000, widget.profile.thinkingTimeMs * 24);
    }
    return max(12000, widget.profile.thinkingTimeMs * 8);
  }

  @override
  void initState() {
    super.initState();
    _initializeGame();
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

  void _initializeGame() {
    _playerStone = widget.randomFirst && Random().nextBool()
        ? GoStone.white
        : GoStone.black;
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
    _pendingPoint = null;
    _blackWinrate = null;
    _blackBase = Duration.zero;
    _whiteBase = Duration.zero;
    _activeClockStone = null;
    _activeClockStartedAt = null;
    _startClockFor(toPlay);
    _status =
        '你执${_playerStone == GoStone.black ? '黑' : '白'}，${toPlay == _playerStone ? '请落子' : 'AI先行'}';

    if (toPlay == _aiStone) {
      unawaited(_aiMove());
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

  Future<void> _onBoardTap(GoPoint point) async {
    if (_game == null || _aiThinking || _finalScore != null) {
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

    if (_pendingPoint != point) {
      setState(() {
        _pendingPoint = point;
        _status = '再次点击同一位置确认落子';
      });
      return;
    }

    final GoGameState next = _game!.play(probe);
    setState(() {
      _applyGame(next);
      _pendingPoint = null;
      _status = '你已落子，等待AI应手...';
    });
    await _aiMove();
  }

  Future<void> _playerPass() async {
    if (_game == null || _aiThinking || _finalScore != null) {
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
    _maybeFinishGame();
    if (_finalScore == null) {
      await _aiMove();
    }
  }

  Future<void> _aiMove() async {
    if (_game == null || _game!.toPlay != _aiStone || _finalScore != null) {
      return;
    }
    setState(() {
      _aiThinking = true;
      _pendingPoint = null;
      _status = widget.profile.id == 'advanced'
          ? 'AI高阶思考中（可能较久）...'
          : 'AI思考中...';
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
          rules: const GameRules(
            ruleset: 'chinese',
            komi: 7.5,
            scoringRule: ScoringRule.area,
            koRule: KoRule.situationalSuperko,
          ),
          profile: widget.profile,
          timeoutMs: _timeoutBudgetMs(),
        ),
      );

      _blackWinrate = _aiStone == GoStone.black
          ? analyzed.winrate
          : (1.0 - analyzed.winrate);

      final GoPoint? aiPoint = _gtpToPoint(analyzed.bestMove, widget.boardSize);
      GoGameState next = _game!;
      if (aiPoint != null) {
        try {
          next = next.play(GoMove(player: _aiStone, point: aiPoint));
        } catch (_) {
          final List<GoPoint> legal = next.legalMovesForCurrentPlayer().toList();
          if (legal.isNotEmpty) {
            final GoPoint fallback = legal[Random().nextInt(legal.length)];
            next = next.play(GoMove(player: _aiStone, point: fallback));
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
      _maybeFinishGame();
    } on PlatformException catch (e) {
      final String details = e.details?.toString() ?? '';
      setState(() {
        _status = 'AI分析失败: [${e.code}] ${e.message ?? ''} ${details.isEmpty ? '' : '| $details'}';
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
      _finalScore = _game!.scoreChineseArea(komi: 7.5);
      _freezeActiveClock();
      _status = '终局: ${_finalScore!.winnerText()}';
    }
  }

  void _undo() {
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
      _status = '已悔棋';
      _startClockFor(_game!.toPlay);
    });
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

  @override
  Widget build(BuildContext context) {
    final GoGameState? game = _game;
    final double? blackWin = _blackWinrate;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 8,
        title: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Text(
            '难度:${widget.profile.name}  让子:${widget.handicap}  '
            '黑胜率:${blackWin == null ? '--' : '${(blackWin * 100).toStringAsFixed(1)}%'}  '
            '黑:${_fmtDuration(_clockValue(GoStone.black))}  '
            '白:${_fmtDuration(_clockValue(GoStone.white))}',
            style: const TextStyle(fontSize: 13),
          ),
        ),
      ),
      body: game == null
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
                          _status,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (_finalScore != null) ...<Widget>[
                          const SizedBox(height: 4),
                          Text(
                            '终局结果: ${_finalScore!.winnerText()}（黑地${_finalScore!.blackTerritory}，白地${_finalScore!.whiteTerritory}）',
                          ),
                        ],
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          children: <Widget>[
                            OutlinedButton(
                              onPressed: (game.toPlay == _playerStone &&
                                      !_aiThinking &&
                                      _finalScore == null)
                                  ? _playerPass
                                  : null,
                              child: const Text('Pass'),
                            ),
                            OutlinedButton(
                              onPressed: (_history.length > 1 && !_aiThinking)
                                  ? _undo
                                  : null,
                              child: const Text('悔棋'),
                            ),
                            OutlinedButton(
                              onPressed: _aiThinking
                                  ? null
                                  : () {
                                      setState(_initializeGame);
                                    },
                              child: const Text('再战'),
                            ),
                            OutlinedButton(
                              onPressed: () => Navigator.of(context).pop(),
                              child: const Text('返回'),
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
