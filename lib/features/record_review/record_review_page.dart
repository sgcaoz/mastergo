import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory, File, FileSystemEntity, Platform;

import 'package:external_path/external_path.dart';
import 'package:path/path.dart' as p;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import 'package:mastergo/application/analysis/game_analysis_service.dart'
    show GameAnalysisService, HintKind, MoveHint;
import 'package:mastergo/domain/entities/analysis_profile.dart';
import 'package:mastergo/domain/entities/game_record.dart';
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
import 'package:mastergo/infra/sound/stone_sound.dart';
import 'package:mastergo/infra/storage/game_record_repository.dart';

/// 默认打开的目录：下载目录。iOS 用 path_provider；Android 上 getDownloadsDirectory 不可用时用 external_path 取公共 Download 路径。
Future<String?> getInitialDirectoryForImport() async {
  try {
    final Directory? downloads = await getDownloadsDirectory();
    if (downloads != null) return downloads.path;
  } catch (_) {}
  if (Platform.isAndroid) {
    try {
      final String path = await ExternalPath.getExternalStoragePublicDirectory(
        ExternalPath.DIRECTORY_DOWNLOAD,
      );
      if (path.isNotEmpty) return path;
    } catch (_) {}
  }
  return null;
}

/// 将 SGF 内容写入设备下载目录（与 URL 导入一致，便于在文件管理器中看到）。失败不抛错。
Future<void> saveSgfToDownloadDirectory(String content, String fileName) async {
  try {
    final String? dir = await getInitialDirectoryForImport();
    if (dir == null || dir.isEmpty) return;
    final String safeName = fileName.toLowerCase().endsWith('.sgf')
        ? fileName
        : '$fileName.sgf';
    final File file = File(p.join(dir, safeName));
    await file.writeAsString(content);
  } catch (_) {}
}

class RecordReviewPage extends StatefulWidget {
  const RecordReviewPage({
    super.key,
    this.initialSgfContent,
    this.initialTitle,
    this.initialRecordId,
    this.initialSource,
    this.openWithSgfContent,
    this.openWithSgfFileName,
    this.onOpenWithSgfConsumed,
  });

  final String? initialSgfContent;
  final String? initialTitle;
  final String? initialRecordId;
  final String? initialSource;
  /// 由「用本应用打开」传入的 SGF 内容，以导入棋谱方式处理
  final String? openWithSgfContent;
  final String? openWithSgfFileName;
  final VoidCallback? onOpenWithSgfConsumed;

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
  /// 分析当前胜率默认用低 visits，避免超时；若对局/复盘选了更高参数可在此覆盖。
  static const int _defaultCurrentWinrateVisits = 5;
  final AnalysisProfile _currentWinrateProfile = const AnalysisProfile(
    id: 'review-current-winrate',
    name: '当前胜率',
    description: '单点分析',
    maxVisits: _defaultCurrentWinrateVisits,
    thinkingTimeMs: 500,
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
  String _recordSource = 'download';

  bool get _isBattleRecord =>
      _recordSource == 'battle_local' || _recordSource == 'battle_temp';
  bool get _isThirdPartyRecord =>
      _recordSource == 'import' || // legacy compatibility
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
    unawaited(saveSgfToDownloadDirectory(result.sgf, result.title));
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
    final Future<List<GameRecord>> future =
        _sourceFutures[source] ??= () async {
          if (source != 'download') {
            return _recordRepository.listBySource(source);
          }
          // 单一可见列表：下载页兼容展示历史 import 与当前 download。
          final List<GameRecord> download = await _recordRepository.listBySource(
            'download',
          );
          final List<GameRecord> legacyImport = await _recordRepository
              .listBySource('import');
          final Map<String, GameRecord> merged = <String, GameRecord>{};
          for (final GameRecord r in <GameRecord>[...download, ...legacyImport]) {
            final GameRecord? old = merged[r.id];
            if (old == null || r.updatedAtMs > old.updatedAtMs) {
              merged[r.id] = r;
            }
          }
          final List<GameRecord> list = merged.values.toList()
            ..sort((GameRecord a, GameRecord b) => b.updatedAtMs.compareTo(a.updatedAtMs));
          return list;
        }();
    return FutureBuilder<List<GameRecord>>(
      future: future,
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

  /// 名局列表：从数据库按 source=master 列出（seed 库在首次打开时已从 assets 复制）。
  Future<List<GameRecord>> _loadMasterGamesFromDb() async {
    return _recordRepository.listBySource('master');
  }

  /// 从名局记录的 sessionJson 解析副标题（players · event · year）。
  static String _masterRecordSubtitle(GameRecord record) {
    try {
      final Map<String, dynamic>? m =
          jsonDecode(record.sessionJson) as Map<String, dynamic>?;
      if (m == null) return record.title;
      final String? players = m['players'] as String?;
      final String? event = m['event'] as String?;
      final Object? year = m['year'];
      if (players != null && event != null && year != null) {
        return '$players · $event · $year';
      }
    } catch (_) {}
    return record.title;
  }

  Widget _buildLibraryHome(BuildContext context) {
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
                FutureBuilder<List<GameRecord>>(
                  future: _loadMasterGamesFromDb(),
                  builder:
                      (
                        BuildContext context,
                        AsyncSnapshot<List<GameRecord>> snapshot,
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
                        final List<GameRecord> games =
                            snapshot.data ?? <GameRecord>[];
                        if (games.isEmpty) {
                          return const Center(child: Text('暂无名局'));
                        }
                        return ListView.separated(
                          itemCount: games.length,
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (_, int i) {
                            final GameRecord record = games[i];
                            return ListTile(
                              title: Text(record.title),
                              subtitle: Text(
                                _masterRecordSubtitle(record),
                              ),
                              trailing: const Icon(Icons.chevron_right),
                              onTap: () async {
                                if (!context.mounted) return;
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
    if (widget.openWithSgfContent != null &&
        widget.openWithSgfContent!.trim().isNotEmpty) {
      _applyOpenWithSgfOnce(
        widget.openWithSgfContent!,
        widget.openWithSgfFileName ?? 'opened.sgf',
        widget.onOpenWithSgfConsumed,
      );
    }
    unawaited(_loadInitialRecordWinrates());
  }

  bool _openWithSgfConsumed = false;

  void _applyOpenWithSgfOnce(
    String content,
    String fileName,
    VoidCallback? onConsumed,
  ) {
    if (_openWithSgfConsumed) return;
    _openWithSgfConsumed = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _applyImportedSgf(content, fileName).then((_) {
        onConsumed?.call();
      });
    });
  }

  @override
  void didUpdateWidget(covariant RecordReviewPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.openWithSgfContent != null &&
        widget.openWithSgfContent!.trim().isNotEmpty) {
      _applyOpenWithSgfOnce(
        widget.openWithSgfContent!,
        widget.openWithSgfFileName ?? 'opened.sgf',
        widget.onOpenWithSgfConsumed,
      );
    }
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

  /// 唯一入口：先选文件夹，再在列表中选一个 SGF。优先从下载目录打开以兼容刚下载的文件。
  Future<void> _importSgf() async {
    final String? initialDir = await getInitialDirectoryForImport();
    final String? dirPath = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择包含棋谱的文件夹',
      initialDirectory: initialDir,
    );
    if (dirPath == null || dirPath.isEmpty) {
      return;
    }
    final Directory dir = Directory(dirPath);
    if (!dir.existsSync()) {
      setState(() => _status = '文件夹不存在');
      return;
    }
    List<FileSystemEntity> entities;
    try {
      entities = dir.listSync();
    } catch (e) {
      setState(() => _status = '无法读取文件夹: $e');
      return;
    }
    final List<File> sgfFiles = entities
        .whereType<File>()
        .where((File f) => f.path.toLowerCase().endsWith('.sgf'))
        .toList();
    if (sgfFiles.isEmpty) {
      setState(() => _status = '该文件夹内没有 SGF 文件');
      return;
    }
    sgfFiles.sort((File a, File b) => a.path.compareTo(b.path));
    if (!mounted) {
      return;
    }
    final File? chosen = await showDialog<File>(
      context: context,
      builder: (BuildContext ctx) {
        return SimpleDialog(
          title: const Text('选择棋谱文件'),
          children: sgfFiles.map((File f) {
            final String name = f.path.split(RegExp(r'[/\\]')).last;
            return SimpleDialogOption(
              onPressed: () => Navigator.of(ctx).pop(f),
              child: Text(name, overflow: TextOverflow.ellipsis),
            );
          }).toList(),
        );
      },
    );
    if (chosen == null) {
      return;
    }
    String content;
    try {
      content = await chosen.readAsString();
    } catch (e) {
      setState(() => _status = '读取失败: $e');
      return;
    }
    final String name = chosen.path.split(RegExp(r'[/\\]')).last;
    await _applyImportedSgf(content, name);
  }

  Future<void> _applyImportedSgf(String content, String fileName) async {
    if (content.trim().isEmpty) {
      setState(() => _status = '导入失败：文件为空');
      return;
    }
    final SgfGame parsed = _sgfParser.parse(content);
    final String ruleset =
        parsed.rules.isEmpty ? _ruleset : rulePresetFromString(parsed.rules).id;
    final GameRecord? existing =
        await _recordRepository.findImportBySgfContent(content);
    final String recordId = existing?.id ?? _recordRepository.newId(prefix: 'download');
    final String winrateJson =
        existing?.winrateJson ?? jsonEncode(<String, double>{});
    setState(() {
      _sgf = parsed;
      _ruleset = ruleset;
      _komiController.text = parsed.komi.toString();
      _path = <SgfNode>[];
      _selectedVariation = 0;
      _winrates.clear();
      _status = existing != null ? '已更新 $fileName（同棋谱去重）' : '已导入 $fileName';
    });
    _recordId = recordId;
    _recordSource = 'download';
    await _recordRepository.saveOrUpdateSourceRecord(
      id: recordId,
      source: _recordSource,
      title: fileName,
      boardSize: parsed.boardSize,
      ruleset: ruleset,
      komi: parsed.komi,
      sgf: content,
      status: 'ready',
      winrateJson: winrateJson,
    );
    unawaited(saveSgfToDownloadDirectory(content, fileName));
    if (mounted) {
      setState(() => _sourceFutures.remove('download'));
    }
    if (existing != null && existing.winrateJson.isNotEmpty) {
      try {
        final Map<String, dynamic> raw =
            jsonDecode(existing.winrateJson) as Map<String, dynamic>;
        final Map<int, double> parsedWinrates = raw.map(
          (String k, dynamic v) => MapEntry<int, double>(
            int.tryParse(k) ?? 0,
            (v as num).toDouble(),
          ),
        )..remove(0);
        if (mounted) {
          setState(() => _winrates.addAll(parsedWinrates));
        }
      } catch (_) {}
    }
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
      final String title = uri.pathSegments.isNotEmpty
          ? uri.pathSegments.last
          : 'downloaded.sgf';
      await _recordRepository.saveOrUpdateSourceRecord(
        id: _recordId,
        source: _recordSource,
        title: title,
        boardSize: parsed.boardSize,
        ruleset: parsed.rules.isEmpty
            ? _ruleset
            : rulePresetFromString(parsed.rules).id,
        komi: parsed.komi,
        sgf: content,
        status: 'ready',
        winrateJson: jsonEncode(<String, double>{}),
      );
      unawaited(saveSgfToDownloadDirectory(content, title));
      if (!mounted) {
        return;
      }
      setState(() {
        _sourceFutures.remove('download');
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

  /// 可选：若本谱来自对局且保存了更高 visits，分析当前胜率时可沿用并延长超时。
  AnalysisProfile? _gameAnalysisProfile;

  /// 分析当前胜率：默认 maxVisits=5；仅当对局传入了更高 visits 时用对局参数，超时随 visits 延长。
  AnalysisProfile _profileForCurrentWinrate() {
    if (_gameAnalysisProfile != null &&
        _gameAnalysisProfile!.maxVisits > _defaultCurrentWinrateVisits) {
      return _gameAnalysisProfile!;
    }
    return _currentWinrateProfile;
  }

  /// 超时随 visits 延长，避免默认 8s 导致分析当前胜率失败。
  int _timeoutMsForCurrentWinrate(AnalysisProfile profile) {
    return (profile.maxVisits * 800).clamp(15000, 90000);
  }

  Future<void> _analyzeCurrentWinrate() async {
    if (_sgf == null) {
      return;
    }
    setState(() {
      _analyzing = true;
      _status = '正在分析当前局面...';
    });
    try {
      final RulePreset preset = rulePresetFromString(_ruleset);
      final double komi =
          double.tryParse(_komiController.text) ?? preset.defaultKomi;
      final List<String> moveTokens = _currentLine()
          .where((SgfNode n) => n.move != null)
          .map((SgfNode n) => n.move!)
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
      final StoneColor startingPlayer = _sgf!.initialBlackStones.isNotEmpty
          ? StoneColor.white
          : StoneColor.black;
      final AnalysisProfile profile = _profileForCurrentWinrate();
      final int timeoutMs = _timeoutMsForCurrentWinrate(profile);
      final Map<int, double> data = await _analysisService.analyzeTurns(
        adapter: _katagoAdapter,
        moveTokens: moveTokens,
        boardSize: _sgf!.boardSize,
        ruleset: _ruleset,
        komi: komi,
        profile: profile,
        initialStones: initialStones,
        startingPlayer: startingPlayer,
        timeoutMs: timeoutMs,
        startTurn: _currentTurn,
        maxTurnsToAnalyze: 1,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _winrates.addAll(data);
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
      maxVisits: 20,
      thinkingTimeMs: 1000,
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
        profile: _isThirdPartyRecord ? _thirdPartyAnalysisProfile : _analysisProfile,
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

  void _goToTurn(int turn) {
    if (_sgf == null) {
      return;
    }
    final List<SgfNode> line = _currentLine();
    if (turn <= 0) {
      setState(() {
        _path = <SgfNode>[];
        _selectedVariation = 0;
        _reviewTryMode = false;
        _reviewTryState = null;
        _reviewHintPoints = <GoPoint>[];
      });
      return;
    }
    final int end = turn.clamp(1, line.length);
    setState(() {
      _path = line.sublist(0, end);
      _selectedVariation = 0;
      _reviewTryMode = false;
      _reviewTryState = null;
      _reviewHintPoints = <GoPoint>[];
    });
  }

  /// 打谱用黑方视角生成妙手/恶手文案（与复盘 buildHints 一致）
  List<String> _buildReviewHints({required bool good}) {
    if (_winrates.isEmpty) {
      return <String>[];
    }
    final List<MoveHint> hints = _analysisService.buildHints(
      _winrates,
      playerStone: GoStone.black,
      brilliantEpsilon: 0.05,
    );
    return hints
        .where(
          (MoveHint h) =>
              good ? h.kind == HintKind.brilliant : h.kind == HintKind.blunder,
        )
        .map(
          (MoveHint h) =>
              '第${h.turn}手后黑方胜率 ${(h.deltaPlayerWinrate * 100).toStringAsFixed(1)}%',
        )
        .toList();
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
    final List<String> reviewGoodHints = _buildReviewHints(good: true);
    final List<String> reviewBadHints = _buildReviewHints(good: false);
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
            label: const Text('选择 SGF'),
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
          Text(
            '${_sgf!.gameName ?? '未命名'}  (${_sgf!.blackName ?? 'Black'} vs ${_sgf!.whiteName ?? 'White'})  ${_sgf!.mainLineNodes().length}手',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        ],
        if (!compactReviewLayout) ...<Widget>[
          const SizedBox(height: 20),
          const Text('规则补录（导入时使用；SGF 内可含 RU/贴目 KM，导入后会带出）'),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            key: ValueKey<String>(_ruleset),
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
            title: null, // 隐藏标题，头部已显示棋谱信息
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
            // 传入胜率数据，让 Panel 负责渲染图表并联动
            currentTurn: _currentTurn,
            maxTurn: _currentLine().length,
            winrates: _winrates,
            onTurnSelected: _goToTurn,
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
                playStoneSound();
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
                Expanded(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text('手数: $_currentTurn'),
                      const SizedBox(width: 12),
                      Text(
                        _winrates.containsKey(_currentTurn)
                            ? '当前胜率: ${(_winrates[_currentTurn]! * 100).toStringAsFixed(1)}%'
                            : '当前胜率: --',
                        style: const TextStyle(fontSize: 13),
                      ),
                    ],
                  ),
                ),
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
                      decoration: const InputDecoration(
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                        border: OutlineInputBorder(),
                      ),
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
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (_winrates.isNotEmpty) ...<Widget>[
                  Text('妙手提示',
                      style: Theme.of(context).textTheme.titleMedium),
                  if (reviewGoodHints.isEmpty)
                    const Text('暂无明显妙手')
                  else
                    ...reviewGoodHints.map(Text.new),
                  const SizedBox(height: 8),
                  Text('恶手提示',
                      style: Theme.of(context).textTheme.titleMedium),
                  if (reviewBadHints.isEmpty)
                    const Text('暂无明显恶手')
                  else
                    ...reviewBadHints.map(Text.new),
                  const SizedBox(height: 12),
                ],
                FilledButton.icon(
                  onPressed: _analyzing ? null : _analyzeCurrentWinrate,
                  icon: _analyzing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.analytics_outlined),
                  label: const Text('分析当前胜率'),
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
  static const SgfParser _sgfParser = SgfParser();
  bool _loading = false;
  String? _status;

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    setState(() {
      _loading = true;
      _status = null;
    });
    try {
      final String? initialDir = await getInitialDirectoryForImport();
      final String? dirPath = await FilePicker.platform.getDirectoryPath(
        dialogTitle: '选择包含棋谱的文件夹',
        initialDirectory: initialDir,
      );
      if (dirPath == null || dirPath.isEmpty) {
        return;
      }
      final Directory dir = Directory(dirPath);
      if (!dir.existsSync()) {
        setState(() => _status = '文件夹不存在');
        return;
      }
      List<FileSystemEntity> entities;
      try {
        entities = dir.listSync();
      } catch (e) {
        setState(() => _status = '无法读取文件夹: $e');
        return;
      }
      final List<File> sgfFiles = entities
          .whereType<File>()
          .where((File f) => f.path.toLowerCase().endsWith('.sgf'))
          .toList();
      if (sgfFiles.isEmpty) {
        setState(() => _status = '该文件夹内没有 SGF 文件');
        return;
      }
      sgfFiles.sort((File a, File b) => a.path.compareTo(b.path));
      if (!mounted) {
        return;
      }
      final File? chosen = await showDialog<File>(
        context: context,
        builder: (BuildContext ctx) {
          return SimpleDialog(
            title: const Text('选择棋谱文件'),
            children: sgfFiles.map((File f) {
              final String name = f.path.split(RegExp(r'[/\\]')).last;
              return SimpleDialogOption(
                onPressed: () => Navigator.of(ctx).pop(f),
                child: Text(name, overflow: TextOverflow.ellipsis),
              );
            }).toList(),
          );
        },
      );
      if (chosen == null) {
        return;
      }
      final String content = await chosen.readAsString();
      final String title = chosen.path.split(RegExp(r'[/\\]')).last;
      if (!mounted) {
        return;
      }
      final SgfGame parsed = _sgfParser.parse(content);
      final String ruleset = parsed.rules.isEmpty
          ? 'chinese'
          : rulePresetFromString(parsed.rules).id;
      Navigator.of(context).pop(
        _ImportResult(
          sgf: content,
          title: title,
          source: 'download',
          ruleset: ruleset,
          komi: parsed.komi,
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
      final SgfGame parsed = _sgfParser.parse(response.body);
      final String ruleset = parsed.rules.isEmpty
          ? 'chinese'
          : rulePresetFromString(parsed.rules).id;
      Navigator.of(context).pop(
        _ImportResult(
          sgf: response.body,
          title: fileName,
          source: 'download',
          ruleset: ruleset,
          komi: parsed.komi,
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
          FilledButton.icon(
            onPressed: _loading ? null : _pickFile,
            icon: const Icon(Icons.upload_file),
            label: const Text('选择 SGF'),
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
