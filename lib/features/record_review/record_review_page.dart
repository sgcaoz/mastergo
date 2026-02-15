import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:mastergo/application/analysis/game_analysis_service.dart';
import 'package:mastergo/domain/entities/analysis_profile.dart';
import 'package:mastergo/domain/entities/rule_presets.dart';
import 'package:mastergo/domain/go/go_game.dart';
import 'package:mastergo/domain/go/go_types.dart';
import 'package:mastergo/domain/sgf/sgf_parser.dart';
import 'package:mastergo/features/common/go_board_widget.dart';
import 'package:mastergo/features/common/winrate_chart.dart';
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

  String _ruleset = 'chinese';
  SgfGame? _sgf;
  List<SgfNode> _path = <SgfNode>[];
  int _selectedVariation = 0;
  bool _analyzing = false;
  bool _downloading = false;
  final Map<int, double> _winrates = <int, double>{};
  String? _status;
  String? _recordId;
  String _recordSource = 'import';

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
    GoGameState state = GoGameState(boardSize: _sgf!.boardSize);
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
        profile: _analysisProfile,
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
    });
  }

  void _prev() {
    if (_path.isEmpty) {
      return;
    }
    setState(() {
      _path = _path.sublist(0, _path.length - 1);
      _selectedVariation = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    final GoGameState? boardState = _stateAtPath();
    final Widget content = ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
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
        if (_sgf != null) ...<Widget>[
          const SizedBox(height: 12),
          Text('棋谱: ${_sgf!.gameName ?? '未命名'}'),
          Text(
            '对局: ${_sgf!.blackName ?? 'Black'} vs ${_sgf!.whiteName ?? 'White'}',
          ),
          Text('主线步数: ${_sgf!.mainLineNodes().length}'),
        ],
        const SizedBox(height: 20),
        const Text('规则补录（导入时使用）'),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          initialValue: _ruleset,
          items: kRulePresets
              .map(
                (RulePreset p) =>
                    DropdownMenuItem<String>(value: p.id, child: Text(p.label)),
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
        if (_sgf != null && boardState != null) ...<Widget>[
          SizedBox(
            height: 320,
            child: GoBoardWidget(
              boardSize: boardState.boardSize,
              board: boardState.board,
            ),
          ),
          const SizedBox(height: 8),
          Row(
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
                      if (v == null) {
                        return;
                      }
                      setState(() {
                        _selectedVariation = v;
                      });
                    },
                  ),
                ),
              IconButton(
                onPressed:
                    (_currentNode != null && _currentNode!.children.isNotEmpty)
                    ? _next
                    : null,
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
          const SizedBox(height: 10),
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
