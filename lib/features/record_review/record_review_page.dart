import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:mastergo/application/analysis/game_analysis_service.dart';
import 'package:mastergo/domain/entities/analysis_profile.dart';
import 'package:mastergo/domain/entities/game_record.dart';
import 'package:mastergo/domain/entities/master_game_meta.dart';
import 'package:mastergo/domain/entities/rule_presets.dart';
import 'package:mastergo/domain/entities/game_setup.dart';
import 'package:mastergo/domain/go/go_game.dart';
import 'package:mastergo/domain/go/go_types.dart';
import 'package:mastergo/domain/sgf/sgf_parser.dart';
import 'package:mastergo/features/common/ownership_result_sheet.dart';
import 'package:mastergo/features/common/review_board_panel.dart';
import 'package:mastergo/features/common/winrate_chart.dart';
import 'package:mastergo/infra/config/master_game_repository.dart';
import 'package:mastergo/infra/engine/katago/katago_adapter.dart';
import 'package:mastergo/infra/storage/game_record_repository.dart';

class RecordReviewPage extends StatefulWidget {
  const RecordReviewPage({
    super.key,
    this.initialSgfContent,
    this.initialTitle,
    this.initialRecordId,
    this.initialSource,
  });

  final String? initialSgfContent;
  final String? initialTitle;
  final String? initialRecordId;
  final String? initialSource;

  @override
  State<RecordReviewPage> createState() => _RecordReviewPageState();
}

class _RecordReviewPageState extends State<RecordReviewPage> {
  final SgfParser _sgfParser = const SgfParser();
  final KatagoAdapter _katagoAdapter = PlatformKatagoAdapter();
  final GameAnalysisService _analysisService = const GameAnalysisService();
  final GameRecordRepository _recordRepository = GameRecordRepository();
  final TextEditingController _komiController = TextEditingController(
    text: '6.5',
  );
  final TextEditingController _urlController = TextEditingController();
  final AnalysisProfile _analysisProfile = const AnalysisProfile(
    id: 'review-default',
    name: '复盘分析',
    description: '逐手胜率',
    maxVisits: 120,
    thinkingTimeMs: 1000,
    includeOwnership: false,
  );
  final AnalysisProfile _thirdPartyAnalysisProfile = const AnalysisProfile(
    id: 'review-fast-third-party',
    name: '第三方复盘',
    description: '低参数逐手胜率',
    maxVisits: 10,
    thinkingTimeMs: 400,
    includeOwnership: false,
  );

  String _ruleset = 'chinese';
  SgfGame? _sgf;
  List<SgfNode> _path = <SgfNode>[];
  int _selectedVariation = 0;
  bool _analyzing = false;
  bool _downloading = false;
  bool _reviewTryMode = false;
  GoGameState? _reviewTryState;
  List<GoPoint> _reviewHintPoints = <GoPoint>[];
  bool _reviewHintLoading = false;
  bool _reviewOwnershipLoading = false;
  bool _selectMode = false;
  final Set<String> _selectedIds = <String>{};
  final Map<String, Future<List<GameRecord>>> _sourceFutures =
      <String, Future<List<GameRecord>>>{};
  final Map<int, double> _winrates = <int, double>{};
  String? _status;
  String? _recordId;
  String _recordSource = 'import';

  bool get _isBattleRecord =>
      _recordSource == 'battle_local' || _recordSource == 'battle_temp';
  bool get _isThirdPartyRecord =>
      _recordSource == 'import' ||
      _recordSource == 'download' ||
      _recordSource == 'master';

  String _sgfProp(String sgf, String key) {
    final RegExp reg = RegExp('$key\\[([^\\]]*)\\]');
    final Match? m = reg.firstMatch(sgf);
    return m == null ? '' : (m.group(1) ?? '').trim();
  }

  String _fmtTs(int ms) {
    final DateTime d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  Future<void> _openImportPage() async {
    final _ImportResult? result = await Navigator.of(context)
        .push<_ImportResult>(
          MaterialPageRoute<_ImportResult>(
            builder: (_) => const _ImportSgfPage(),
          ),
        );
    if (result == null || result.sgf.trim().isEmpty) {
      return;
    }
    final SgfGame parsed = _sgfParser.parse(result.sgf);
    final String normalizedRuleset = rulePresetFromString(result.ruleset).id;
    final double komi = result.komi;
    _recordId = _recordRepository.newId(prefix: result.source);
    _recordSource = result.source;
    await _recordRepository.saveOrUpdateSourceRecord(
      id: _recordId,
      source: _recordSource,
      title: result.title,
      boardSize: parsed.boardSize,
      ruleset: normalizedRuleset,
      komi: komi,
      sgf: result.sgf,
      status: 'ready',
      winrateJson: jsonEncode(<String, double>{}),
    );
    _sourceFutures.remove(result.source);
    if (!mounted) {
      return;
    }
    setState(() {
      _sgf = parsed;
      _ruleset = normalizedRuleset;
      _komiController.text = komi.toStringAsFixed(1);
      _path = <SgfNode>[];
      _selectedVariation = 0;
      _winrates.clear();
      _status = '已导入 ${result.title}';
    });
  }

  Future<void> _openRecord(GameRecord record) async {
    if (_selectMode) {
      setState(() {
        if (_selectedIds.contains(record.id)) {
          _selectedIds.remove(record.id);
        } else {
          _selectedIds.add(record.id);
        }
      });
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RecordReviewPage(
          initialSgfContent: record.sgf,
          initialTitle: record.title,
          initialRecordId: record.id,
          initialSource: record.source,
        ),
      ),
    );
  }

  Widget _buildRecordList(String source) {
    return FutureBuilder<List<GameRecord>>(
      future: _sourceFutures[source] ??= _recordRepository.listBySource(source),
      builder: (BuildContext context, AsyncSnapshot<List<GameRecord>> snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        final List<GameRecord> records = snapshot.data ?? <GameRecord>[];
        if (records.isEmpty) {
          return const Center(child: Text('暂无棋谱'));
        }
        return ListView.separated(
          itemCount: records.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (_, int i) {
            final GameRecord r = records[i];
            final String pb = _sgfProp(r.sgf, 'PB');
            final String pw = _sgfProp(r.sgf, 'PW');
            final String re = _sgfProp(r.sgf, 'RE');
            final int moves = _sgfParser.parse(r.sgf).mainLineNodes().length;
            final String title = (pb.isNotEmpty || pw.isNotEmpty)
                ? '${pb.isEmpty ? 'Black' : pb} vs ${pw.isEmpty ? 'White' : pw}'
                : r.title;
            return ListTile(
              title: Text(title),
              subtitle: Text(
                '${_fmtTs(r.updatedAtMs)}  ·  手数$moves  ·  ${re.isEmpty ? '结果未知' : re}',
              ),
              leading: _selectMode
                  ? Checkbox(
                      value: _selectedIds.contains(r.id),
                      onChanged: (_) {
                        setState(() {
                          if (_selectedIds.contains(r.id)) {
                            _selectedIds.remove(r.id);
                          } else {
                            _selectedIds.add(r.id);
                          }
                        });
                      },
                    )
                  : null,
              trailing: _selectMode
                  ? const Icon(Icons.checklist)
                  : IconButton(
                      tooltip: '删除',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => _deleteOne(r),
                    ),
              onTap: () => _openRecord(r),
              onLongPress: () {
                setState(() {
                  _selectMode = true;
                  _selectedIds.add(r.id);
                });
              },
            );
          },
        );
      },
    );
  }

  Future<void> _deleteOne(GameRecord record) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('删除棋谱'),
          content: Text('确定删除「${record.title}」吗？'),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('删除'),
            ),
          ],
        );
      },
    );
    if (ok != true) {
      return;
    }
    await _recordRepository.deleteById(record.id);
    if (!mounted) {
      return;
    }
    setState(() {
      _sourceFutures
        ..remove('battle_local')
        ..remove('download');
      _status = '已删除 1 条棋谱';
    });
  }

  Future<void> _deleteSelected() async {
    if (_selectedIds.isEmpty) {
      return;
    }
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('批量删除'),
          content: Text('确定删除已选 ${_selectedIds.length} 条棋谱吗？'),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('删除'),
            ),
          ],
        );
      },
    );
    if (ok != true) {
      return;
    }
    await _recordRepository.deleteByIds(_selectedIds.toList());
    if (!mounted) {
      return;
    }
    setState(() {
      _sourceFutures
        ..remove('battle_local')
        ..remove('download');
      _status = '已删除 ${_selectedIds.length} 条棋谱';
      _selectedIds.clear();
      _selectMode = false;
    });
  }

  Widget _buildLibraryHome(BuildContext context) {
    final MasterGameRepository masterRepo = MasterGameRepository();
    return DefaultTabController(
      length: 3,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            height: 48,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: _selectMode
                  ? Row(
                      children: <Widget>[
                        Expanded(child: Text('已选择 ${_selectedIds.length} 条')),
                        TextButton(
                          onPressed: () {
                            setState(() {
                              _selectedIds.clear();
                              _selectMode = false;
                            });
                          },
                          child: const Text('取消选择'),
                        ),
                        FilledButton(
                          onPressed: _selectedIds.isEmpty
                              ? null
                              : _deleteSelected,
                          child: const Text('批量删除'),
                        ),
                      ],
                    )
                  : const SizedBox.shrink(),
            ),
          ),
          const TabBar(
            tabs: <Tab>[
              Tab(text: '本机对局'),
              Tab(text: '下载棋谱'),
              Tab(text: '名局'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: <Widget>[
                _buildRecordList('battle_local'),
                _buildRecordList('download'),
                FutureBuilder<List<MasterGameMeta>>(
                  future: masterRepo.loadIndex(),
                  builder:
                      (
                        BuildContext context,
                        AsyncSnapshot<List<MasterGameMeta>> snapshot,
                      ) {
                        if (snapshot.connectionState != ConnectionState.done) {
                          return const Center(
                            child: CircularProgressIndicator(),
                          );
                        }
                        if (snapshot.hasError) {
                          return Center(
                            child: Text('加载名局失败: ${snapshot.error}'),
                          );
                        }
                        final List<MasterGameMeta> games =
                            snapshot.data ?? <MasterGameMeta>[];
                        if (games.isEmpty) {
                          return const Center(child: Text('暂无名局'));
                        }
                        return ListView.separated(
                          itemCount: games.length,
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (_, int i) {
                            final MasterGameMeta g = games[i];
                            return ListTile(
                              title: Text(g.title),
                              subtitle: Text(
                                '${g.players} · ${g.event} · ${g.year}',
                              ),
                              trailing: const Icon(Icons.chevron_right),
                              onTap: () async {
                                final String sgf = await masterRepo
                                    .loadSgfContent(g.sgfAssetPath);
                                await _recordRepository.saveMasterGame(
                                  id: 'master-${g.id}',
                                  title: g.title,
                                  boardSize: g.boardSize,
                                  ruleset: g.ruleset,
                                  komi: g.komi,
                                  sgf: sgf,
                                );
                                if (!context.mounted) {
                                  return;
                                }
                                await Navigator.of(context).push(
                                  MaterialPageRoute<void>(
                                    builder: (_) => RecordReviewPage(
                                      initialSgfContent: sgf,
                                      initialTitle: g.title,
                                      initialRecordId: 'master-${g.id}',
                                      initialSource: 'master',
                                    ),
                                  ),
                                );
                              },
                            );
                          },
                        );
                      },
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: FilledButton.icon(
              onPressed: _openImportPage,
              icon: const Icon(Icons.upload_file),
              label: const Text('导入棋谱（文件/URL）'),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    if (widget.initialSgfContent != null &&
        widget.initialSgfContent!.isNotEmpty) {
      final SgfGame parsed = _sgfParser.parse(widget.initialSgfContent!);
      _sgf = parsed;
      _ruleset = parsed.rules.isEmpty
          ? _ruleset
          : rulePresetFromString(parsed.rules).id;
      _komiController.text = parsed.komi.toString();
      _recordId = widget.initialRecordId;
      _recordSource = widget.initialSource ?? 'master';
      _status = widget.initialTitle == null
          ? '已加载棋谱'
          : '已加载 ${widget.initialTitle}';
    }
    unawaited(_loadInitialRecordWinrates());
  }

  Future<void> _loadInitialRecordWinrates() async {
    if (_recordId == null) {
      return;
    }
    final GameRecord? rec = await _recordRepository.loadById(_recordId!);
    if (rec == null || rec.winrateJson.isEmpty) {
      return;
    }
    try {
      final Map<String, dynamic> raw =
          jsonDecode(rec.winrateJson) as Map<String, dynamic>;
      final Map<int, double> parsed = raw.map(
        (String k, dynamic v) =>
            MapEntry<int, double>(int.tryParse(k) ?? 0, (v as num).toDouble()),
      )..remove(0);
      if (!mounted || parsed.isEmpty) {
        return;
      }
      setState(() {
        _winrates
          ..clear()
          ..addAll(parsed);
        if (_isBattleRecord) {
          _status = '已加载对局内胜率数据';
        }
      });
    } catch (_) {
      // ignore invalid stored winrate JSON
    }
  }

  @override
  void dispose() {
    unawaited(_katagoAdapter.shutdown());
    _komiController.dispose();
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _importSgf() async {
    final FilePickerResult? picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: <String>['sgf'],
      withData: true,
    );
    if (picked == null || picked.files.isEmpty) {
      return;
    }
    final PlatformFile file = picked.files.first;
    final String content = String.fromCharCodes(file.bytes ?? <int>[]);
    if (content.trim().isEmpty) {
      setState(() {
        _status = '导入失败：文件为空';
      });
      return;
    }
    final SgfGame parsed = _sgfParser.parse(content);
    setState(() {
      _sgf = parsed;
      _ruleset = parsed.rules.isEmpty
          ? _ruleset
          : rulePresetFromString(parsed.rules).id;
      _komiController.text = parsed.komi.toString();
      _path = <SgfNode>[];
      _selectedVariation = 0;
      _winrates.clear();
      _status = '已导入 ${file.name}';
    });
    _recordId = _recordRepository.newId(prefix: 'import');
    _recordSource = 'import';
    await _recordRepository.saveOrUpdateSourceRecord(
      id: _recordId,
      source: _recordSource,
      title: file.name,
      boardSize: parsed.boardSize,
      ruleset: parsed.rules.isEmpty
          ? _ruleset
          : rulePresetFromString(parsed.rules).id,
      komi: parsed.komi,
      sgf: content,
      status: 'ready',
      winrateJson: jsonEncode(<String, double>{}),
    );
  }

  Future<void> _downloadSgf() async {
    final String url = _urlController.text.trim();
    if (url.isEmpty) {
      setState(() {
        _status = '请输入 SGF 下载链接';
      });
      return;
    }
    setState(() {
      _downloading = true;
      _status = '下载中...';
    });
    try {
      final Uri uri = Uri.parse(url);
      final http.Response response = await http.get(uri);
      if (response.statusCode != 200) {
        throw StateError('HTTP ${response.statusCode}');
      }
      final String content = response.body;
      if (content.trim().isEmpty) {
        throw StateError('下载内容为空');
      }
      final SgfGame parsed = _sgfParser.parse(content);
      _recordId = _recordRepository.newId(prefix: 'download');
      _recordSource = 'download';
      await _recordRepository.saveOrUpdateSourceRecord(
        id: _recordId,
        source: _recordSource,
        title: uri.pathSegments.isNotEmpty
            ? uri.pathSegments.last
            : 'downloaded.sgf',
        boardSize: parsed.boardSize,
        ruleset: parsed.rules.isEmpty
            ? _ruleset
            : rulePresetFromString(parsed.rules).id,
        komi: parsed.komi,
        sgf: content,
        status: 'ready',
        winrateJson: jsonEncode(<String, double>{}),
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _sgf = parsed;
        _ruleset = parsed.rules.isEmpty
            ? _ruleset
            : rulePresetFromString(parsed.rules).id;
        _komiController.text = parsed.komi.toString();
        _path = <SgfNode>[];
        _selectedVariation = 0;
        _winrates.clear();
        _status = '下载并导入成功';
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = '下载失败: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _downloading = false;
        });
      }
    }
  }

  GoGameState? _stateAtPath() {
    if (_sgf == null) {
      return null;
    }
    final List<List<GoStone?>> board = List<List<GoStone?>>.generate(
      _sgf!.boardSize,
      (_) => List<GoStone?>.filled(_sgf!.boardSize, null),
    );
    for (final GoPoint p in _sgf!.initialBlackStones) {
      board[p.y][p.x] = GoStone.black;
    }
    for (final GoPoint p in _sgf!.initialWhiteStones) {
      board[p.y][p.x] = GoStone.white;
    }
    final GoStone toPlay =
        _sgf!.root.children.isNotEmpty && _sgf!.root.children.first.move != null
        ? _sgf!.root.children.first.move!.player
        : GoStone.black;
    GoGameState state = GoGameState(
      boardSize: _sgf!.boardSize,
      board: board,
      toPlay: toPlay,
    );
    for (final SgfNode node in _path) {
      if (node.move == null) {
        continue;
      }
      try {
        state = state.play(node.move!);
      } catch (_) {
        break;
      }
    }
    return state;
  }

  Future<void> _analyzeWinrates() async {
    if (_sgf == null) {
      return;
    }
    if (_isBattleRecord && _winrates.isNotEmpty) {
      setState(() {
        _status = '本机对局已包含每步胜率，无需重新分析';
      });
      return;
    }
    setState(() {
      _analyzing = true;
      _status = '正在分析...';
      _winrates.clear();
    });
    try {
      final double komi = double.tryParse(_komiController.text) ?? _sgf!.komi;
      final List<String> moveTokens = _currentLine()
          .where((SgfNode n) => n.move != null)
          .map((SgfNode n) => n.move!)
          .map((GoMove m) => m.toProtocolToken(_sgf!.boardSize))
          .toList();
      final Map<int, double> data = await _analysisService.analyzeTurns(
        adapter: _katagoAdapter,
        moveTokens: moveTokens,
        boardSize: _sgf!.boardSize,
        ruleset: _ruleset,
        komi: komi,
        profile: _isThirdPartyRecord
            ? _thirdPartyAnalysisProfile
            : _analysisProfile,
        timeoutMs: _isThirdPartyRecord ? 60000 : null,
        onProgress: (int turn, int total) {
          if (!mounted) {
            return;
          }
          setState(() {
            _status = '分析中: $turn/$total';
          });
        },
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _winrates
          ..clear()
          ..addAll(data);
      });
      if (_recordId != null) {
        await _recordRepository.saveOrUpdateSourceRecord(
          id: _recordId,
          source: _recordSource,
          title: _sgf?.gameName ?? 'review',
          boardSize: _sgf!.boardSize,
          ruleset: _ruleset,
          komi: komi,
          sgf: _renderCurrentSgf(),
          status: 'analyzed',
          winrateJson: jsonEncode(
            data.map(
              (int k, double v) => MapEntry<String, double>(k.toString(), v),
            ),
          ),
        );
      }
      setState(() {
        _status = '分析完成';
      });
    } catch (e) {
      setState(() {
        _status = '分析失败: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _analyzing = false;
        });
      }
    }
  }

  List<SgfNode> _currentLine() {
    final List<SgfNode> line = <SgfNode>[..._path];
    SgfNode cursor = _path.isEmpty ? _sgf!.root : _path.last;
    while (cursor.children.isNotEmpty) {
      cursor = cursor.children.first;
      line.add(cursor);
    }
    return line;
  }

  GoPoint? _gtpToPoint(String gtp, int boardSize) {
    if (gtp.toLowerCase() == 'pass') {
      return null;
    }
    const String columns = 'ABCDEFGHJKLMNOPQRSTUVWXYZ';
    if (gtp.length < 2) {
      return null;
    }
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

  Future<KatagoAnalyzeResult> _requestOwnershipAnalysis(GoGameState state) async {
    if (_sgf == null) {
      throw StateError('无棋谱');
    }
    final List<String> moveTokens = state.moves
        .map((GoMove m) => m.toProtocolToken(_sgf!.boardSize))
        .toList();
    final List<String> initialStones = <String>[
      ..._sgf!.initialBlackStones.map(
        (GoPoint p) =>
            'B:${GoMove(player: GoStone.black, point: p).toGtp(_sgf!.boardSize)}',
      ),
      ..._sgf!.initialWhiteStones.map(
        (GoPoint p) =>
            'W:${GoMove(player: GoStone.white, point: p).toGtp(_sgf!.boardSize)}',
      ),
    ];
    final RulePreset preset = rulePresetFromString(_ruleset);
    final double komi =
        double.tryParse(_komiController.text) ?? preset.defaultKomi;
    final AnalysisProfile ownershipProfile = AnalysisProfile(
      id: '${_analysisProfile.id}-ownership-fast',
      name: _analysisProfile.name,
      description: _analysisProfile.description,
      maxVisits: 5,
      thinkingTimeMs: 300,
      includeOwnership: true,
    );
    return _katagoAdapter.analyze(
      KatagoAnalyzeRequest(
        queryId: 'review-ownership-${DateTime.now().millisecondsSinceEpoch}',
        moves: moveTokens,
        initialStones: initialStones,
        gameSetup: GameSetup(
          boardSize: _sgf!.boardSize,
          startingPlayer: state.toPlay == GoStone.black
              ? StoneColor.black
              : StoneColor.white,
        ),
        rules: preset.toGameRules(komi: komi),
        profile: ownershipProfile,
        includeOwnership: true,
        timeoutMs: _isThirdPartyRecord ? 60000 : 30000,
      ),
    );
  }

  Future<void> _requestReviewHint(GoGameState state) async {
    if (_sgf == null) {
      return;
    }
    final List<String> moveTokens = state.moves
        .map((GoMove m) => m.toProtocolToken(_sgf!.boardSize))
        .toList();
    final RulePreset preset = rulePresetFromString(_ruleset);
    final double komi =
        double.tryParse(_komiController.text) ?? preset.defaultKomi;
    final KatagoAnalyzeResult analyzed = await _katagoAdapter.analyze(
      KatagoAnalyzeRequest(
        queryId: 'review-hint-${DateTime.now().millisecondsSinceEpoch}',
        moves: moveTokens,
        gameSetup: GameSetup(
          boardSize: _sgf!.boardSize,
          startingPlayer: state.toPlay == GoStone.black
              ? StoneColor.black
              : StoneColor.white,
        ),
        rules: preset.toGameRules(komi: komi),
        profile: _analysisProfile,
      ),
    );
    final List<String> raw = analyzed.topMoves.isNotEmpty
        ? analyzed.topMoves
        : <String>[analyzed.bestMove];
    setState(() {
      _reviewHintPoints = raw
          .map((String move) => _gtpToPoint(move, _sgf!.boardSize))
          .whereType<GoPoint>()
          .take(raw.length > 1 ? 3 : 1)
          .toList();
      _status = _reviewHintPoints.isEmpty
          ? '暂无可用提示点'
          : '提示点已标注（${_reviewHintPoints.length}个）';
    });
  }

  String _renderCurrentSgf() {
    if (_sgf == null) {
      return '';
    }
    final List<SgfNode> line = _currentLine();
    final StringBuffer sb = StringBuffer();
    sb.write('(;GM[1]FF[4]SZ[');
    sb.write(_sgf!.boardSize);
    sb.write(']KM[');
    sb.write(_sgf!.komi);
    sb.write(']');
    sb.write('RU[');
    sb.write(_ruleset);
    sb.write(']');
    for (final GoPoint p in _sgf!.initialBlackStones) {
      sb.write('AB[${_toSgfCoord(p)}]');
    }
    for (final GoPoint p in _sgf!.initialWhiteStones) {
      sb.write('AW[${_toSgfCoord(p)}]');
    }
    for (final SgfNode node in line) {
      final GoMove? move = node.move;
      if (move == null) {
        continue;
      }
      final String color = move.player == GoStone.black ? 'B' : 'W';
      if (move.isPass || move.point == null) {
        sb.write(';$color[]');
      } else {
        const String letters = 'abcdefghijklmnopqrstuvwxyz';
        sb.write(';$color[${letters[move.point!.x]}${letters[move.point!.y]}]');
      }
    }
    sb.write(')');
    return sb.toString();
  }

  SgfNode? get _currentNode =>
      _sgf == null ? null : (_path.isEmpty ? _sgf!.root : _path.last);

  int get _currentTurn => _path.length;

  void _next() {
    final SgfNode? node = _currentNode;
    if (node == null || node.children.isEmpty) {
      return;
    }
    final int idx = _selectedVariation.clamp(0, node.children.length - 1);
    setState(() {
      _path = <SgfNode>[..._path, node.children[idx]];
      _selectedVariation = 0;
      _reviewTryMode = false;
      _reviewTryState = null;
      _reviewHintPoints = <GoPoint>[];
      _selectMode = false;
      _selectedIds.clear();
    });
  }

  void _prev() {
    if (_path.isEmpty) {
      return;
    }
    setState(() {
      _path = _path.sublist(0, _path.length - 1);
      _selectedVariation = 0;
      _reviewTryMode = false;
      _reviewTryState = null;
      _reviewHintPoints = <GoPoint>[];
      _selectMode = false;
      _selectedIds.clear();
    });
  }

  String _toSgfCoord(GoPoint p) {
    const String letters = 'abcdefghijklmnopqrstuvwxyz';
    return '${letters[p.x]}${letters[p.y]}';
  }

  @override
  Widget build(BuildContext context) {
    if (_sgf == null) {
      final Widget home = _buildLibraryHome(context);
      final ModalRoute<dynamic>? route = ModalRoute.of(context);
      final bool isPushedPage = route?.canPop == true;
      if (isPushedPage) {
        return Scaffold(
          appBar: AppBar(title: const Text('打谱复盘')),
          body: home,
        );
      }
      return Material(child: home);
    }
    final GoGameState? boardState = _stateAtPath();
    final bool compactReviewLayout = _recordId != null;
    final Widget content = ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        if (!compactReviewLayout) ...<Widget>[
          Text('打谱', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 12),
          const Text('导入棋谱后会先校验规则信息。若 SGF 缺失贴目或规则，将在导入流程中要求补录，避免分析结果偏差。'),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: _importSgf,
            icon: const Icon(Icons.upload_file),
            label: const Text('导入棋谱'),
          ),
          const SizedBox(height: 8),
          TextFormField(
            controller: _urlController,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: '在线棋谱链接（SGF URL）',
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _downloading ? null : _downloadSgf,
            icon: _downloading
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.download),
            label: const Text('下载并导入棋谱'),
          ),
        ],
        if (_sgf != null) ...<Widget>[
          const SizedBox(height: 12),
          Text('棋谱: ${_sgf!.gameName ?? '未命名'}'),
          Text(
            '对局: ${_sgf!.blackName ?? 'Black'} vs ${_sgf!.whiteName ?? 'White'}',
          ),
          Text('主线步数: ${_sgf!.mainLineNodes().length}'),
        ],
        if (!compactReviewLayout) ...<Widget>[
          const SizedBox(height: 20),
          const Text('规则补录（导入时使用）'),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            initialValue: _ruleset,
            items: kRulePresets
                .map(
                  (RulePreset p) => DropdownMenuItem<String>(
                    value: p.id,
                    child: Text(p.label),
                  ),
                )
                .toList(),
            onChanged: (String? value) {
              if (value == null) {
                return;
              }
              setState(() {
                final RulePreset preset = rulePresetFromString(value);
                _ruleset = preset.id;
                _komiController.text = preset.defaultKomi.toStringAsFixed(1);
              });
            },
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: '规则',
            ),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _komiController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: '贴目',
            ),
          ),
          const SizedBox(height: 20),
        ],
        if (_sgf != null && boardState != null) ...<Widget>[
          ReviewBoardPanel(
            title: '打谱',
            state: _reviewTryState ?? boardState,
            lastMovePoint: (_reviewTryState ?? boardState).moves.isNotEmpty
                ? (_reviewTryState ?? boardState).moves.last.point
                : null,
            tryMode: _reviewTryMode,
            hintPoints: _reviewHintPoints,
            hintSummary: _reviewHintPoints.isEmpty
                ? null
                : '已标注 ${_reviewHintPoints.length} 个提示点',
            hintLoading: _reviewHintLoading,
            ownershipLoading: _reviewOwnershipLoading,
            onEnterTry: () {
              setState(() {
                _reviewTryMode = true;
                _reviewTryState = boardState;
                _reviewHintPoints = <GoPoint>[];
              });
            },
            onExitTry: () {
              setState(() {
                _reviewTryMode = false;
                _reviewTryState = null;
                _reviewHintPoints = <GoPoint>[];
              });
            },
            onTryPlay: (GoPoint p) {
              final GoGameState cur = _reviewTryState ?? boardState;
              try {
                setState(() {
                  _reviewTryState =
                      cur.play(GoMove(player: cur.toPlay, point: p));
                  _reviewHintPoints = <GoPoint>[];
                });
              } catch (_) {}
            },
            onRequestHint: () async {
              setState(() => _reviewHintLoading = true);
              await _requestReviewHint(_reviewTryState ?? boardState);
              if (mounted) setState(() => _reviewHintLoading = false);
            },
            onRequestOwnership: () async {
              final GoGameState state = _reviewTryState ?? boardState;
              setState(() => _reviewOwnershipLoading = true);
              try {
                final KatagoAnalyzeResult res =
                    await _requestOwnershipAnalysis(state);
                if (!mounted) return;
                setState(() => _reviewOwnershipLoading = false);
                showOwnershipResultSheet(context, state, res);
              } catch (e) {
                if (mounted) {
                  setState(() => _reviewOwnershipLoading = false);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('局势分析失败: $e')),
                  );
                }
              }
            },
            turnNavigation: Row(
              children: <Widget>[
                IconButton(
                  onPressed: _path.isNotEmpty ? _prev : null,
                  icon: const Icon(Icons.chevron_left),
                ),
                Expanded(child: Text('当前手数: $_currentTurn')),
                if (_currentNode != null && _currentNode!.children.length > 1)
                  SizedBox(
                    width: 120,
                    child: DropdownButtonFormField<int>(
                      initialValue: _selectedVariation.clamp(
                        0,
                        _currentNode!.children.length - 1,
                      ),
                      items: List<DropdownMenuItem<int>>.generate(
                        _currentNode!.children.length,
                        (int i) => DropdownMenuItem<int>(
                          value: i,
                          child: Text('变着${i + 1}'),
                        ),
                      ),
                      onChanged: (int? v) {
                        if (v == null) return;
                        setState(() => _selectedVariation = v);
                      },
                    ),
                  ),
                IconButton(
                  onPressed: (_currentNode != null &&
                          _currentNode!.children.isNotEmpty)
                      ? _next
                      : null,
                  icon: const Icon(Icons.chevron_right),
                ),
              ],
            ),
            bottomChild: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                FilledButton.icon(
                  onPressed: _analyzing ? null : _analyzeWinrates,
                  icon: _analyzing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.analytics_outlined),
                  label: const Text('分析每步胜率'),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  height: 180,
                  child: WinrateChart(
                    winrates: _winrates,
                    maxTurn: _currentLine().length,
                  ),
                ),
                if (_winrates.containsKey(_currentTurn))
                  Text(
                    '第$_currentTurn手胜率: ${(_winrates[_currentTurn]! * 100).toStringAsFixed(1)}%',
                  ),
              ],
            ),
          ),
        ],
        if (_status != null) ...<Widget>[
          const SizedBox(height: 8),
          Text(_status!),
        ],
      ],
    );

    final ModalRoute<dynamic>? route = ModalRoute.of(context);
    final bool isPushedPage = route?.canPop == true;
    if (isPushedPage) {
      return Scaffold(
        appBar: AppBar(title: const Text('打谱复盘')),
        body: content,
      );
    }
    return Material(child: content);
  }
}

class _ImportResult {
  const _ImportResult({
    required this.sgf,
    required this.title,
    required this.source,
    required this.ruleset,
    required this.komi,
  });

  final String sgf;
  final String title;
  final String source;
  final String ruleset;
  final double komi;
}

class _ImportSgfPage extends StatefulWidget {
  const _ImportSgfPage();

  @override
  State<_ImportSgfPage> createState() => _ImportSgfPageState();
}

class _ImportSgfPageState extends State<_ImportSgfPage> {
  final TextEditingController _urlController = TextEditingController();
  String _ruleset = 'chinese';
  double _komi = 7.5;
  bool _loading = false;
  String? _status;

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  void _onRulesChanged(String value) {
    final RulePreset preset = rulePresetFromString(value);
    setState(() {
      _ruleset = preset.id;
      _komi = preset.defaultKomi;
    });
  }

  Future<void> _pickFile() async {
    setState(() {
      _loading = true;
      _status = null;
    });
    try {
      final FilePickerResult? picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: <String>['sgf'],
        withData: true,
      );
      if (picked == null || picked.files.isEmpty) {
        return;
      }
      final PlatformFile file = picked.files.first;
      final String content = String.fromCharCodes(file.bytes ?? <int>[]);
      if (!mounted) {
        return;
      }
      Navigator.of(context).pop(
        _ImportResult(
          sgf: content,
          title: file.name,
          source: 'import',
          ruleset: _ruleset,
          komi: _komi,
        ),
      );
    } catch (e) {
      setState(() {
        _status = '导入失败: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Future<void> _downloadByUrl() async {
    final String url = _urlController.text.trim();
    if (url.isEmpty) {
      setState(() {
        _status = '请输入 SGF URL';
      });
      return;
    }
    setState(() {
      _loading = true;
      _status = null;
    });
    try {
      final Uri uri = Uri.parse(url);
      final http.Response response = await http.get(uri);
      if (response.statusCode != 200) {
        throw StateError('HTTP ${response.statusCode}');
      }
      if (!mounted) {
        return;
      }
      final String fileName = uri.pathSegments.isNotEmpty
          ? uri.pathSegments.last
          : 'downloaded.sgf';
      Navigator.of(context).pop(
        _ImportResult(
          sgf: response.body,
          title: fileName,
          source: 'download',
          ruleset: _ruleset,
          komi: _komi,
        ),
      );
    } catch (e) {
      setState(() {
        _status = '下载失败: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('导入棋谱')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          DropdownButtonFormField<String>(
            initialValue: _ruleset,
            items: kRulePresets
                .where(
                  (RulePreset p) =>
                      p.id == 'chinese' ||
                      p.id == 'japanese' ||
                      p.id == 'classical',
                )
                .map(
                  (RulePreset p) => DropdownMenuItem<String>(
                    value: p.id,
                    child: Text(p.label),
                  ),
                )
                .toList(),
            onChanged: (String? value) {
              if (value != null) {
                _onRulesChanged(value);
              }
            },
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: '规则',
            ),
          ),
          const SizedBox(height: 8),
          TextFormField(
            initialValue: _komi.toStringAsFixed(1),
            enabled: false,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: '贴目（规则默认）',
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _loading ? null : _pickFile,
            icon: const Icon(Icons.upload_file),
            label: const Text('选择 SGF 文件'),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _urlController,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: 'SGF URL',
            ),
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _loading ? null : _downloadByUrl,
            icon: const Icon(Icons.download),
            label: const Text('下载并导入'),
          ),
          if (_status != null) ...<Widget>[
            const SizedBox(height: 12),
            Text(_status!),
          ],
        ],
      ),
    );
  }
}
