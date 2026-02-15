import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:mastergo/domain/entities/analysis_profile.dart';
import 'package:mastergo/domain/entities/game_rules.dart';
import 'package:mastergo/domain/entities/game_setup.dart';
import 'package:mastergo/domain/go/go_game.dart';
import 'package:mastergo/domain/go/go_types.dart';
import 'package:mastergo/domain/sgf/sgf_parser.dart';
import 'package:mastergo/features/common/go_board_widget.dart';
import 'package:mastergo/infra/engine/katago/katago_adapter.dart';

class RecordReviewPage extends StatefulWidget {
  const RecordReviewPage({super.key});

  @override
  State<RecordReviewPage> createState() => _RecordReviewPageState();
}

class _RecordReviewPageState extends State<RecordReviewPage> {
  final SgfParser _sgfParser = const SgfParser();
  final KatagoAdapter _katagoAdapter = PlatformKatagoAdapter();
  final TextEditingController _komiController = TextEditingController(
    text: '6.5',
  );
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
  final Map<int, double> _winrates = <int, double>{};
  String? _status;

  @override
  void dispose() {
    unawaited(_katagoAdapter.shutdown());
    _komiController.dispose();
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
      _ruleset = parsed.rules.isEmpty ? _ruleset : parsed.rules;
      _komiController.text = parsed.komi.toString();
      _path = <SgfNode>[];
      _selectedVariation = 0;
      _winrates.clear();
      _status = '已导入 ${file.name}';
    });
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
      await _katagoAdapter.ensureStarted();
      final double komi = double.tryParse(_komiController.text) ?? _sgf!.komi;
      final List<SgfNode> line = _currentLine();
      for (int turn = 0; turn <= line.length; turn++) {
        final List<String> moveTokens = line
            .take(turn)
            .where((SgfNode n) => n.move != null)
            .map((SgfNode n) => n.move!)
            .map((GoMove m) => m.toProtocolToken(_sgf!.boardSize))
            .toList();

        final KatagoAnalyzeResult res = await _katagoAdapter.analyze(
          KatagoAnalyzeRequest(
            queryId: 'review-$turn-${DateTime.now().millisecondsSinceEpoch}',
            moves: moveTokens,
            gameSetup: GameSetup(
              boardSize: _sgf!.boardSize,
              startingPlayer: StoneColor.black,
            ),
            rules: GameRules(
              ruleset: _ruleset,
              komi: komi,
              scoringRule: _ruleset == 'japanese'
                  ? ScoringRule.territory
                  : ScoringRule.area,
              koRule: _ruleset == 'japanese'
                  ? KoRule.simple
                  : KoRule.situationalSuperko,
            ),
            profile: _analysisProfile,
          ),
        );
        if (!mounted) {
          return;
        }
        setState(() {
          _winrates[turn] = res.winrate;
          _status = '分析中: $turn/${line.length}';
        });
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

    return ListView(
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
          items: const <DropdownMenuItem<String>>[
            DropdownMenuItem<String>(value: 'chinese', child: Text('中国规则')),
            DropdownMenuItem<String>(value: 'japanese', child: Text('日本规则')),
            DropdownMenuItem<String>(value: 'korean', child: Text('韩国规则')),
          ],
          onChanged: (String? value) {
            if (value == null) {
              return;
            }
            setState(() {
              _ruleset = value;
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
            child: _WinrateChart(
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
  }
}

class _WinrateChart extends StatelessWidget {
  const _WinrateChart({required this.winrates, required this.maxTurn});

  final Map<int, double> winrates;
  final int maxTurn;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _WinratePainter(
        winrates: winrates,
        maxTurn: maxTurn,
        lineColor: Theme.of(context).colorScheme.primary,
      ),
      child: Container(
        decoration: BoxDecoration(border: Border.all(color: Colors.black12)),
      ),
    );
  }
}

class _WinratePainter extends CustomPainter {
  const _WinratePainter({
    required this.winrates,
    required this.maxTurn,
    required this.lineColor,
  });

  final Map<int, double> winrates;
  final int maxTurn;
  final Color lineColor;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint axisPaint = Paint()
      ..color = Colors.black26
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(0, size.height),
      Offset(size.width, size.height),
      axisPaint,
    );
    canvas.drawLine(const Offset(0, 0), Offset(0, size.height), axisPaint);

    if (winrates.length < 2 || maxTurn <= 0) {
      return;
    }

    final List<int> turns = winrates.keys.toList()..sort();
    final Path path = Path();
    for (int i = 0; i < turns.length; i++) {
      final int t = turns[i];
      final double wr = winrates[t]!.clamp(0.0, 1.0);
      final double x = size.width * (t / maxTurn);
      final double y = size.height * (1 - wr);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = lineColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(covariant _WinratePainter oldDelegate) {
    return oldDelegate.winrates != winrates || oldDelegate.maxTurn != maxTurn;
  }
}
