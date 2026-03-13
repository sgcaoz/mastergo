import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory, File, Platform;
import 'dart:math' show max;

import 'package:external_path/external_path.dart';
import 'package:path/path.dart' as p;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:http/http.dart' as http;
import 'package:mastergo/app/app_i18n.dart';
import 'package:mastergo/application/analysis/game_analysis_service.dart'
    show GameAnalysisService, HintKind, MoveHint;
import 'package:mastergo/domain/entities/analysis_profile.dart';
import 'package:mastergo/domain/entities/game_record.dart';
import 'package:mastergo/domain/entities/game_rules.dart';
import 'package:mastergo/domain/entities/rule_presets.dart';
import 'package:mastergo/domain/entities/game_setup.dart';
import 'package:mastergo/domain/go/go_game.dart';
import 'package:mastergo/domain/go/go_types.dart';
import 'package:mastergo/features/ai_play/ai_play_page.dart';
import 'package:mastergo/domain/sgf/sgf_parser.dart';
import 'package:mastergo/domain/sgf/sgf_writer.dart';
import 'package:mastergo/features/common/ownership_result_sheet.dart';
import 'package:mastergo/features/common/pending_confirm_timer.dart';
import 'package:mastergo/features/common/review_board_panel.dart';
import 'package:mastergo/features/common/winrate_chart.dart';
import 'package:mastergo/infra/config/ai_profile_repository.dart';
import 'package:mastergo/infra/engine/katago/katago_adapter.dart';
import 'package:mastergo/infra/sound/stone_sound.dart';
import 'package:mastergo/infra/storage/game_record_repository.dart';

/// 默认打开的目录：下载目录。iOS 用 path_provider；Android 上 getDownloadsDirectory 不可用时用 external_path 取公共 Download 路径。
Future<String?> getInitialDirectoryForImport() async {
  if (Platform.isAndroid) {
    try {
      final String path = await ExternalPath.getExternalStoragePublicDirectory(
        ExternalPath.DIRECTORY_DOWNLOAD,
      );
      if (path.isNotEmpty) return path;
    } catch (_) {}
  }
  try {
    final Directory? downloads = await getDownloadsDirectory();
    if (downloads != null) return downloads.path;
  } catch (_) {}
  return null;
}

class _PickedSgfFile {
  const _PickedSgfFile({required this.fileName, required this.content});

  final String fileName;
  final String content;
}

bool _isSgfName(String name) => name.toLowerCase().endsWith('.sgf');

bool _looksLikeSgfContent(String content) {
  final String trimmed = content.trimLeft();
  if (trimmed.isEmpty) {
    return false;
  }
  return trimmed.startsWith('(;') || trimmed.startsWith('(');
}

void _showInvalidSgfMessage(BuildContext context) {
  final AppStrings s = AppStrings.of(context);
  final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(
          s.pick(
            zh: '文件格式错误：请选择 SGF 棋谱',
            en: 'Invalid file format: please select an SGF file',
            ja: 'ファイル形式エラー: SGF を選択してください',
            ko: '파일 형식 오류: SGF 파일을 선택하세요',
          ),
        ),
      ),
    );
}

Future<_PickedSgfFile?> _pickSgfWithDownloadPriority(
  BuildContext context,
) async {
  Future<_PickedSgfFile?> pickFromSystem({String? initialDirectory}) async {
    final FilePickerResult? pick = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const <String>['sgf'],
      allowMultiple: false,
      initialDirectory: initialDirectory,
      withData: true,
    );
    if (pick == null || pick.files.isEmpty) {
      return null;
    }
    final PlatformFile file = pick.files.first;
    final String name = file.name.isNotEmpty ? file.name : 'imported.sgf';
    final String content;
    if (file.bytes != null) {
      content = utf8.decode(file.bytes!, allowMalformed: true);
    } else if (file.path != null && file.path!.isNotEmpty) {
      final List<int> bytes = await File(file.path!).readAsBytes();
      content = utf8.decode(bytes, allowMalformed: true);
    } else {
      return null;
    }
    if (!_isSgfName(name) && !_looksLikeSgfContent(content)) {
      _showInvalidSgfMessage(context);
      return null;
    }
    return _PickedSgfFile(fileName: name, content: content);
  }

  // Android: 直接走系统文件选择器（用户可点「本周文件/最近」并切目录）。
  if (Platform.isAndroid) {
    final String? downloadDir = await getInitialDirectoryForImport();
    return pickFromSystem(initialDirectory: downloadDir);
  }

  // 其他平台：仍优先尝试下载目录作为初始目录，但不限制用户切换目录。
  final String? initialDir = await getInitialDirectoryForImport();
  return pickFromSystem(initialDirectory: initialDir);
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

/// 配置未加载时的复盘分析兜底（与 ai_profiles 挑战档一致，思考 20s 避免 iOS 超时）。
const AnalysisProfile _fallbackReviewProfile = AnalysisProfile(
  id: 'review-fallback',
  name: '挑战',
  description: '复盘分析',
  maxVisits: 50,
  thinkingTimeMs: 20000,
  includeOwnership: false,
);

class _RecordReviewPageState extends State<RecordReviewPage> {
  final SgfParser _sgfParser = const SgfParser();
  final KatagoAdapter _katagoAdapter = PlatformKatagoAdapter();
  final GameAnalysisService _analysisService = const GameAnalysisService();
  final GameRecordRepository _recordRepository = GameRecordRepository();
  final AIProfileRepository _profileRepository = AIProfileRepository();
  final TextEditingController _komiController = TextEditingController(
    text: '6.5',
  );
  final TextEditingController _urlController = TextEditingController();

  /// 从 ai_profiles.json 加载的档位；未加载完或为空时用 _fallbackReviewProfile。
  List<AnalysisProfile> _reviewProfiles = <AnalysisProfile>[];

  /// 当前选中的档位下标，默认 1（挑战）。
  int _reviewProfileIndex = 1;

  AnalysisProfile get _analysisProfile => _reviewProfiles.isNotEmpty
      ? _reviewProfiles[_reviewProfileIndex.clamp(
          0,
          _reviewProfiles.length - 1,
        )]
      : _fallbackReviewProfile;

  /// 第三方/名局等复盘用快速档（首档）。
  AnalysisProfile get _thirdPartyAnalysisProfile =>
      _reviewProfiles.isNotEmpty ? _reviewProfiles[0] : _fallbackReviewProfile;

  /// 分析当前胜率与提示共用选中的档位。
  AnalysisProfile get _currentWinrateProfile => _analysisProfile;

  String _ruleset = 'chinese';
  SgfGame? _sgf;
  List<SgfNode> _path = <SgfNode>[];
  int _selectedVariation = 0;
  bool _analyzing = false;
  bool _downloading = false;
  bool _reviewTryMode = false;
  GoGameState? _reviewTryState;
  /// 试下时双击确认：首次点击仅记录待确认点，再次点击同一点才落子；3 秒无操作自动确认。
  GoPoint? _reviewTryPendingPoint;
  final PendingConfirmTimer _reviewTryPendingConfirmTimer = PendingConfirmTimer();
  List<GoPoint> _reviewHintPoints = <GoPoint>[];
  bool _reviewHintLoading = false;
  bool _reviewOwnershipLoading = false;
  bool _selectMode = false;
  final Set<String> _selectedIds = <String>{};
  final Map<String, Future<List<GameRecord>>> _sourceFutures =
      <String, Future<List<GameRecord>>>{};
  /// 主战线胜率（兼容旧逻辑与续下传入）；实际多分支数据在 [_winratesByBranch]。
  Map<int, double> get _winrates => _winratesByBranch[''] ?? <int, double>{};
  /// 各变化图分支胜率：分支 key（见 [_pathToBranchKey]）-> 手数 -> 黑方胜率。
  final Map<String, Map<int, double>> _winratesByBranch =
      <String, Map<int, double>>{};
  /// 胜率升降记录：分支 key -> 手数串 -> 文案（如「第5手 -12%」），存 sessionJson，不随用户编辑笔记改变。
  final Map<String, Map<String, String>> _winrateNotes =
      <String, Map<String, String>>{};
  bool _isFillingWinrate = false;
  String? _status;
  String? _recordId;
  String _recordSource = 'download';
  late AppLanguage _language;
  AppLanguage _effectiveLanguage() {
    try {
      return AppStrings.resolveFromLocale(Localizations.localeOf(context));
    } catch (_) {
      return _language;
    }
  }

  AppStrings get _s => AppStrings(_effectiveLanguage());
  String _t({
    required String zh,
    required String en,
    required String ja,
    required String ko,
  }) => _s.pick(zh: zh, en: en, ja: ja, ko: ko);

  bool get _isBattleRecord =>
      _recordSource == 'battle_local' || _recordSource == 'battle_temp';
  bool get _isThirdPartyRecord =>
      _recordSource == 'import' || // legacy compatibility
      _recordSource == 'download' ||
      _recordSource == 'master';

  /// 当前记录是否可写（本机对局、临时对局、下载的棋谱可保存笔记/变化图）。
  bool get _canSaveRecord =>
      _recordId != null &&
      (_recordSource == 'battle_local' ||
          _recordSource == 'battle_temp' ||
          _recordSource == 'download');

  String _sgfProp(String sgf, String key) {
    final RegExp reg = RegExp('$key\\[([^\\]]*)\\]');
    final Match? m = reg.firstMatch(sgf);
    return m == null ? '' : (m.group(1) ?? '').trim();
  }

  String _localizedResultFromRe(String rawRe) {
    final String re = rawRe.trim();
    if (re.isEmpty) {
      return _t(zh: '结果未知', en: 'Unknown result', ja: '結果不明', ko: '결과 미상');
    }
    final String upper = re.toUpperCase();
    if (upper == '0' ||
        upper == 'DRAW' ||
        upper == 'JIGO' ||
        re == '和棋' ||
        re == '持碁' ||
        re == '무승부') {
      return _t(zh: '和棋', en: 'Draw', ja: '持碁', ko: '무승부');
    }
    final RegExp sgfCode = RegExp(
      r'^([BW])\+([0-9]+(?:\.[0-9]+)?|R|RESIGN|T|TIME|F|FORFEIT)$',
      caseSensitive: false,
    );
    final Match? m = sgfCode.firstMatch(re);
    if (m != null) {
      final bool blackWin = (m.group(1) ?? '').toUpperCase() == 'B';
      final String value = (m.group(2) ?? '').toUpperCase();
      if (value == 'R' || value == 'RESIGN') {
        return blackWin
            ? _t(
                zh: '黑中盘胜',
                en: 'Black wins by resignation',
                ja: '黒中押し勝ち',
                ko: '흑 불계승',
              )
            : _t(
                zh: '白中盘胜',
                en: 'White wins by resignation',
                ja: '白中押し勝ち',
                ko: '백 불계승',
              );
      }
      if (value == 'T' || value == 'TIME') {
        return blackWin
            ? _t(
                zh: '黑超时胜',
                en: 'Black wins on time',
                ja: '黒の時間勝ち',
                ko: '흑 시간승',
              )
            : _t(
                zh: '白超时胜',
                en: 'White wins on time',
                ja: '白の時間勝ち',
                ko: '백 시간승',
              );
      }
      if (value == 'F' || value == 'FORFEIT') {
        return blackWin
            ? _t(
                zh: '黑弃权胜',
                en: 'Black wins by forfeit',
                ja: '黒の不戦勝',
                ko: '흑 부전승',
              )
            : _t(
                zh: '白弃权胜',
                en: 'White wins by forfeit',
                ja: '白の不戦勝',
                ko: '백 부전승',
              );
      }
      return blackWin
          ? _t(
              zh: '黑胜 $value 目',
              en: 'Black wins by $value',
              ja: '黒 $value 目勝ち',
              ko: '흑 $value 집 승',
            )
          : _t(
              zh: '白胜 $value 目',
              en: 'White wins by $value',
              ja: '白 $value 目勝ち',
              ko: '백 $value 집 승',
            );
    }
    final Match? blackByPoints = RegExp(
      r'^黑胜\s*([0-9]+(?:\.[0-9]+)?)\s*目$',
    ).firstMatch(re);
    if (blackByPoints != null) {
      final String value = blackByPoints.group(1)!;
      return _t(
        zh: '黑胜 $value 目',
        en: 'Black wins by $value',
        ja: '黒 $value 目勝ち',
        ko: '흑 $value 집 승',
      );
    }
    final Match? whiteByPoints = RegExp(
      r'^白胜\s*([0-9]+(?:\.[0-9]+)?)\s*目$',
    ).firstMatch(re);
    if (whiteByPoints != null) {
      final String value = whiteByPoints.group(1)!;
      return _t(
        zh: '白胜 $value 目',
        en: 'White wins by $value',
        ja: '白 $value 目勝ち',
        ko: '백 $value 집 승',
      );
    }
    if (re.contains('AI认输') || re.contains('AI 投了')) {
      return _t(
        zh: 'AI认输，你胜',
        en: 'AI resigned, you win',
        ja: 'AIが投了、あなたの勝ち',
        ko: 'AI 기권, 당신 승리',
      );
    }
    if (re.contains('你认输') || re.contains('YOU RESIGNED')) {
      return _t(
        zh: '你认输，AI胜',
        en: 'You resigned, AI wins',
        ja: 'あなたが投了、AI勝ち',
        ko: '당신 기권, AI 승리',
      );
    }
    return re;
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
    await _applyImportedSgf(result.sgf, result.title);
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
    if (!mounted) return;
    setState(() {
      _sourceFutures
        ..remove('battle_local')
        ..remove('download');
    });
  }

  Future<List<GameRecord>> _loadLocalBattleRecords() async {
    // Data correction: promote legacy temp records once they exceed 20 moves.
    final List<GameRecord> temp = await _recordRepository.listBySource(
      'battle_temp',
    );
    for (final GameRecord r in temp) {
      int moves = 0;
      try {
        final Map<String, dynamic> data =
            jsonDecode(r.sessionJson) as Map<String, dynamic>;
        moves = (data['moves'] as List<dynamic>? ?? <dynamic>[]).length;
      } catch (_) {
        try {
          moves = _sgfParser.parse(r.sgf).mainLineNodes().length;
        } catch (_) {
          moves = 0;
        }
      }
      if (moves >= 20) {
        await _recordRepository.upsert(
          GameRecord(
            id: r.id,
            source: 'battle_local',
            title: r.title,
            boardSize: r.boardSize,
            ruleset: r.ruleset,
            komi: r.komi,
            sgf: r.sgf,
            status: r.status,
            sessionJson: r.sessionJson,
            winrateJson: r.winrateJson,
            createdAtMs: r.createdAtMs,
            updatedAtMs: r.updatedAtMs,
          ),
        );
      }
    }
    return _recordRepository.listBySource('battle_local');
  }

  Widget _buildRecordList(String source) {
    final Future<List<GameRecord>> future = source == 'battle_local'
        ? _loadLocalBattleRecords()
        : (_sourceFutures[source] ??= () async {
            if (source != 'download') {
              return _recordRepository.listBySource(source);
            }
            // 单一可见列表：下载页兼容展示历史 import 与当前 download。
            final List<GameRecord> download = await _recordRepository
                .listBySource('download');
            final List<GameRecord> legacyImport = await _recordRepository
                .listBySource('import');
            final Map<String, GameRecord> merged = <String, GameRecord>{};
            for (final GameRecord r in <GameRecord>[
              ...download,
              ...legacyImport,
            ]) {
              final GameRecord? old = merged[r.id];
              if (old == null || r.updatedAtMs > old.updatedAtMs) {
                merged[r.id] = r;
              }
            }
            final List<GameRecord> list = merged.values.toList()
              ..sort(
                (GameRecord a, GameRecord b) =>
                    b.updatedAtMs.compareTo(a.updatedAtMs),
              );
            return list;
          }());
    return FutureBuilder<List<GameRecord>>(
      future: future,
      builder: (BuildContext context, AsyncSnapshot<List<GameRecord>> snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        final List<GameRecord> records = snapshot.data ?? <GameRecord>[];
        if (records.isEmpty) {
          return Center(
            child: Text(
              _t(
                zh: '暂无棋谱',
                en: 'No records yet',
                ja: '棋譜はありません',
                ko: '기보가 없습니다',
              ),
            ),
          );
        }
        return ListView.separated(
          itemCount: records.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (_, int i) {
            final GameRecord r = records[i];
            final String pb = _sgfProp(r.sgf, 'PB');
            final String pw = _sgfProp(r.sgf, 'PW');
            final String re = _sgfProp(r.sgf, 'RE');
            final String localizedResult = _localizedResultFromRe(re);
            final int moves = _sgfParser.parse(r.sgf).mainLineNodes().length;
            final String title = (pb.isNotEmpty || pw.isNotEmpty)
                ? '${pb.isEmpty ? 'Black' : pb} vs ${pw.isEmpty ? 'White' : pw}'
                : r.title;
            return ListTile(
              title: Text(title),
              subtitle: Text(
                _t(
                  zh: '${_fmtTs(r.updatedAtMs)}  ·  手数$moves  ·  $localizedResult',
                  en: '${_fmtTs(r.updatedAtMs)}  ·  Moves $moves  ·  $localizedResult',
                  ja: '${_fmtTs(r.updatedAtMs)}  ·  手数$moves  ·  $localizedResult',
                  ko: '${_fmtTs(r.updatedAtMs)}  ·  수순$moves  ·  $localizedResult',
                ),
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
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        if (source == 'battle_local' && r.status != 'finished')
                          TextButton(
                            onPressed: () async {
                              await Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) => Scaffold(
                                    appBar: AppBar(title: Text(_s.tabAiPlay)),
                                    body: AIPlayPage(
                                      initialRestoreRecordId: r.id,
                                    ),
                                  ),
                                ),
                              );
                              if (!mounted) return;
                              setState(() {});
                            },
                            child: Text(
                              _t(
                                zh: '恢复对局',
                                en: 'Resume',
                                ja: '対局再開',
                                ko: '대국 복원',
                              ),
                            ),
                          ),
                        IconButton(
                          tooltip: _t(
                            zh: '删除',
                            en: 'Delete',
                            ja: '削除',
                            ko: '삭제',
                          ),
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => _deleteOne(r),
                        ),
                      ],
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
          title: Text(
            _t(zh: '删除棋谱', en: 'Delete record', ja: '棋譜削除', ko: '기보 삭제'),
          ),
          content: Text(
            _t(
              zh: '确定删除「${record.title}」吗？',
              en: 'Delete "${record.title}"?',
              ja: '「${record.title}」を削除しますか？',
              ko: '"${record.title}"을(를) 삭제할까요?',
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(_t(zh: '取消', en: 'Cancel', ja: 'キャンセル', ko: '취소')),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(_t(zh: '删除', en: 'Delete', ja: '削除', ko: '삭제')),
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
      _status = _t(
        zh: '已删除 1 条棋谱',
        en: 'Deleted 1 record',
        ja: '1件の棋譜を削除しました',
        ko: '기보 1건 삭제됨',
      );
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
          title: Text(
            _t(zh: '批量删除', en: 'Bulk delete', ja: '一括削除', ko: '일괄 삭제'),
          ),
          content: Text(
            _t(
              zh: '确定删除已选 ${_selectedIds.length} 条棋谱吗？',
              en: 'Delete ${_selectedIds.length} selected records?',
              ja: '選択した ${_selectedIds.length} 件を削除しますか？',
              ko: '선택한 ${_selectedIds.length}개 기보를 삭제할까요?',
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(_t(zh: '取消', en: 'Cancel', ja: 'キャンセル', ko: '취소')),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(_t(zh: '删除', en: 'Delete', ja: '削除', ko: '삭제')),
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
      _status = _t(
        zh: '已删除 ${_selectedIds.length} 条棋谱',
        en: 'Deleted ${_selectedIds.length} records',
        ja: '${_selectedIds.length} 件の棋譜を削除しました',
        ko: '기보 ${_selectedIds.length}건 삭제됨',
      );
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
                        Expanded(
                          child: Text(
                            _t(
                              zh: '已选择 ${_selectedIds.length} 条',
                              en: 'Selected ${_selectedIds.length}',
                              ja: '${_selectedIds.length} 件選択中',
                              ko: '${_selectedIds.length}개 선택됨',
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: () {
                            setState(() {
                              _selectedIds.clear();
                              _selectMode = false;
                            });
                          },
                          child: Text(
                            _t(
                              zh: '取消选择',
                              en: 'Clear',
                              ja: '選択解除',
                              ko: '선택 해제',
                            ),
                          ),
                        ),
                        FilledButton(
                          onPressed: _selectedIds.isEmpty
                              ? null
                              : _deleteSelected,
                          child: Text(
                            _t(
                              zh: '批量删除',
                              en: 'Bulk Delete',
                              ja: '一括削除',
                              ko: '일괄 삭제',
                            ),
                          ),
                        ),
                      ],
                    )
                  : const SizedBox.shrink(),
            ),
          ),
          TabBar(
            tabs: <Tab>[
              Tab(
                text: _t(
                  zh: '本机对局',
                  en: 'Local Games',
                  ja: 'ローカル対局',
                  ko: '로컬 대국',
                ),
              ),
              Tab(
                text: _t(
                  zh: '下载棋谱',
                  en: 'Downloads',
                  ja: 'ダウンロード棋譜',
                  ko: '다운로드 기보',
                ),
              ),
              Tab(
                text: _t(zh: '名局', en: 'Master Games', ja: '名局', ko: '명국'),
              ),
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
                            child: Text(
                              _t(
                                zh: '加载名局失败: ${snapshot.error}',
                                en: 'Failed to load master games: ${snapshot.error}',
                                ja: '名局読み込み失敗: ${snapshot.error}',
                                ko: '명국 불러오기 실패: ${snapshot.error}',
                              ),
                            ),
                          );
                        }
                        final List<GameRecord> games =
                            snapshot.data ?? <GameRecord>[];
                        if (games.isEmpty) {
                          return Center(
                            child: Text(
                              _t(
                                zh: '暂无名局',
                                en: 'No master games',
                                ja: '名局がありません',
                                ko: '명국이 없습니다',
                              ),
                            ),
                          );
                        }
                        return ListView.separated(
                          itemCount: games.length,
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (_, int i) {
                            final GameRecord record = games[i];
                            return ListTile(
                              title: Text(record.title),
                              subtitle: Text(_masterRecordSubtitle(record)),
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
              label: Text(
                _t(
                  zh: '导入棋谱（文件/URL）',
                  en: 'Import SGF (File/URL)',
                  ja: '棋譜インポート（ファイル/URL）',
                  ko: '기보 가져오기(파일/URL)',
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _language = AppStrings.resolveFromLocale(
      WidgetsBinding.instance.platformDispatcher.locale,
    );
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
          ? _t(
              zh: '已加载棋谱',
              en: 'SGF loaded',
              ja: '棋譜を読み込みました',
              ko: '기보 불러오기 완료',
            )
          : _t(
              zh: '已加载 ${widget.initialTitle}',
              en: 'Loaded ${widget.initialTitle}',
              ja: '${widget.initialTitle} を読み込みました',
              ko: '${widget.initialTitle} 불러오기 완료',
            );
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
    unawaited(_loadReviewProfiles());
    if (widget.initialRecordId != null && widget.initialSgfContent != null) {
      unawaited(_applyPhotoContinuationInitialStonesIfNeeded());
    }
  }

  /// 拍照续下记录：复盘时用 session 里的 initialStones 补全根节点局面，保证显示原始位置。
  /// 若重装后仅通过导入 SGF 恢复，开局需依赖 SGF 中的 AB/AW（保存时已写入）。
  Future<void> _applyPhotoContinuationInitialStonesIfNeeded() async {
    if (_recordId == null || _sgf == null) return;
    final GameRecord? rec = await _recordRepository.loadById(_recordId!);
    if (rec == null || rec.sessionJson.isEmpty) return;
    try {
      final Map<String, dynamic> data =
          jsonDecode(rec.sessionJson) as Map<String, dynamic>;
      final List<dynamic>? raw = data['initialStones'] as List<dynamic>?;
      if (raw == null || raw.isEmpty) return;
      final int boardSize = _sgf!.boardSize;
      final List<GoPoint> black = <GoPoint>[];
      final List<GoPoint> white = <GoPoint>[];
      for (final dynamic item in raw) {
        final Map<String, dynamic> s = item as Map<String, dynamic>;
        final String player = s['player'] as String? ?? 'black';
        final int? x = (s['x'] as num?)?.toInt();
        final int? y = (s['y'] as num?)?.toInt();
        if (x == null || y == null ||
            x < 0 || x >= boardSize || y < 0 || y >= boardSize) continue;
        if (player == 'white') {
          white.add(GoPoint(x, y));
        } else {
          black.add(GoPoint(x, y));
        }
      }
      if (black.isEmpty && white.isEmpty) return;
      if (!mounted) return;
      setState(() {
        _sgf = SgfGame(
          boardSize: _sgf!.boardSize,
          komi: _sgf!.komi,
          rules: _sgf!.rules,
          root: _sgf!.root,
          initialBlackStones: black,
          initialWhiteStones: white,
          blackName: _sgf!.blackName,
          whiteName: _sgf!.whiteName,
          gameName: _sgf!.gameName,
          result: _sgf!.result,
        );
      });
    } catch (_) {}
  }

  Future<void> _loadReviewProfiles() async {
    try {
      final List<AnalysisProfile> list = await _profileRepository
          .loadProfiles();
      if (!mounted) return;
      setState(() {
        _reviewProfiles = list;
        _reviewProfileIndex = _reviewProfileIndex.clamp(
          0,
          list.isEmpty ? 0 : list.length - 1,
        );
      });
    } catch (_) {}
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _language = _effectiveLanguage();
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
    if (rec == null) {
      return;
    }
    _loadWinrateNotesFromSession(rec.sessionJson);
    if (rec.winrateJson.isEmpty) {
      return;
    }
    try {
      final Map<String, dynamic> raw =
          jsonDecode(rec.winrateJson) as Map<String, dynamic>;
      final Map<String, Map<int, double>> loaded = <String, Map<int, double>>{};
      final dynamic firstValue = raw.isNotEmpty ? raw.values.first : null;
      if (firstValue is num) {
        // 旧格式：扁平 { "1": 0.55, "2": 0.52 } -> 主战线
        final Map<int, double> parsed = raw.map(
          (String k, dynamic v) => MapEntry<int, double>(
            int.tryParse(k) ?? 0,
            (v as num).toDouble(),
          ),
        )..remove(0);
        if (parsed.isNotEmpty) {
          loaded[''] = parsed;
        }
      } else if (firstValue is Map) {
        // 新格式：按分支 { "": { "1": 0.55 }, "0-1": { "4": 0.48 } }
        for (final MapEntry<String, dynamic> entry in raw.entries) {
          final Map<String, dynamic> branchRaw =
              (entry.value as Map<dynamic, dynamic>?)
                  ?.map((dynamic k, dynamic v) =>
                      MapEntry<String, dynamic>(k.toString(), v)) ??
              <String, dynamic>{};
          final Map<int, double> branch = branchRaw.map(
            (String k, dynamic v) => MapEntry<int, double>(
              int.tryParse(k) ?? 0,
              (v as num).toDouble(),
            ),
          )..remove(0);
          if (branch.isNotEmpty) {
            loaded[entry.key] = branch;
          }
        }
      }
      if (!mounted || loaded.isEmpty) {
        return;
      }
      setState(() {
        _winratesByBranch
          ..clear()
          ..addAll(loaded);
        if (_isBattleRecord) {
          _status = _t(
            zh: '已加载对局内胜率数据',
            en: 'Loaded in-game winrate data',
            ja: '対局内勝率データを読み込みました',
            ko: '대국 내 승률 데이터 로드 완료',
          );
        }
      });
    } catch (_) {
      // ignore invalid stored winrate JSON
    }
  }

  void _loadWinrateNotesFromSession(String sessionJson) {
    if (sessionJson.isEmpty) return;
    try {
      final Map<String, dynamic> data =
          jsonDecode(sessionJson) as Map<String, dynamic>;
      final dynamic raw = data['winrateNotes'];
      if (raw is! Map) return;
      final Map<String, Map<String, String>> loaded =
          <String, Map<String, String>>{};
      for (final MapEntry<dynamic, dynamic> entry in (raw as Map<dynamic, dynamic>).entries) {
        final String branchKey = entry.key.toString();
        final dynamic val = entry.value;
        if (val is! Map) continue;
        loaded[branchKey] = (val as Map<dynamic, dynamic>).map(
          (dynamic k, dynamic v) => MapEntry<String, String>(k.toString(), v.toString()),
        );
      }
      _winrateNotes
        ..clear()
        ..addAll(loaded);
    } catch (_) {}
  }

  /// 胜率跌幅 >10% 或 涨幅 >2% 时记入笔记（不随用户编辑改变），并持久化到 sessionJson。
  static const double _winrateDropThreshold = 0.10;
  static const double _winrateRiseThreshold = 0.02;

  void _recordWinrateDelta(String branchKey, int turn, double delta) {
    if (delta > _winrateRiseThreshold || delta < -_winrateDropThreshold) {
      final String pct = (delta >= 0 ? '+' : '') + (delta * 100).toStringAsFixed(1);
      _winrateNotes[branchKey] ??= <String, String>{};
      _winrateNotes[branchKey]![turn.toString()] = _t(
        zh: '第${turn}手 $pct%',
        en: 'Move $turn $pct%',
        ja: '${turn}手目 $pct%',
        ko: '${turn}수 $pct%',
      );
      unawaited(_persistSessionWinrateNotes());
    }
  }

  Future<void> _persistSessionWinrateNotes() async {
    if (_recordId == null) return;
    final GameRecord? rec = await _recordRepository.loadById(_recordId!);
    if (rec == null) return;
    try {
      final Map<String, dynamic> data = rec.sessionJson.isEmpty
          ? <String, dynamic>{}
          : Map<String, dynamic>.from(
              jsonDecode(rec.sessionJson) as Map<String, dynamic>);
      data['winrateNotes'] = _winrateNotes.map(
        (String k, Map<String, String> v) =>
            MapEntry<String, dynamic>(k, v),
      );
      final int now = DateTime.now().millisecondsSinceEpoch;
      await _recordRepository.upsert(GameRecord(
        id: rec.id,
        source: rec.source,
        title: rec.title,
        boardSize: rec.boardSize,
        ruleset: rec.ruleset,
        komi: rec.komi,
        sgf: rec.sgf,
        status: rec.status,
        sessionJson: jsonEncode(data),
        winrateJson: rec.winrateJson,
        createdAtMs: rec.createdAtMs,
        updatedAtMs: now,
      ));
    } catch (_) {}
  }

  @override
  void dispose() {
    unawaited(_katagoAdapter.shutdown());
    _reviewTryPendingConfirmTimer.cancel();
    _komiController.dispose();
    _urlController.dispose();
    super.dispose();
  }

  /// 唯一入口：先选文件夹，再在列表中选一个 SGF。优先从下载目录打开以兼容刚下载的文件。
  Future<void> _importSgf() async {
    final _PickedSgfFile? picked = await _pickSgfWithDownloadPriority(context);
    if (picked == null) {
      return;
    }
    try {
      await _applyImportedSgf(picked.content, picked.fileName);
    } catch (e) {
      setState(() {
        _status =
            '${_t(zh: '读取失败', en: 'Read failed', ja: '読み込み失敗', ko: '읽기 실패')}: $e';
      });
    }
  }

  Future<void> _applyImportedSgf(String content, String fileName) async {
    if (content.trim().isEmpty) {
      setState(() {
        _status = _t(
          zh: '导入失败：文件为空',
          en: 'Import failed: file is empty',
          ja: 'インポート失敗: ファイルが空です',
          ko: '가져오기 실패: 파일이 비어 있습니다',
        );
      });
      return;
    }
    late final SgfGame parsed;
    try {
      parsed = _sgfParser.parse(content);
    } catch (_) {
      setState(() {
        _status = _t(
          zh: '导入失败：文件格式错误（非SGF）',
          en: 'Import failed: invalid SGF format',
          ja: 'インポート失敗: SGF形式エラー',
          ko: '가져오기 실패: SGF 형식 오류',
        );
      });
      return;
    }
    final String ruleset = parsed.rules.isEmpty
        ? _ruleset
        : rulePresetFromString(parsed.rules).id;
    final GameRecord? existing = await _recordRepository.findImportBySgfContent(
      content,
    );
    final String recordId =
        existing?.id ?? _recordRepository.newId(prefix: 'download');
    final String winrateJson =
        existing?.winrateJson ?? jsonEncode(<String, double>{});
    setState(() {
      _sgf = parsed;
      _ruleset = ruleset;
      _komiController.text = parsed.komi.toString();
      _path = <SgfNode>[];
      _selectedVariation = 0;
      _winratesByBranch.clear();
      _winrateNotes.clear();
      _status = existing != null
          ? _t(
              zh: '重复棋谱：已存在，未重复导入',
              en: 'Duplicate SGF: already exists, import skipped',
              ja: '重複棋譜: 既に存在するためインポートをスキップしました',
              ko: '중복 기보: 이미 존재하여 가져오기를 건너뜁니다',
            )
          : _t(
              zh: '已导入 $fileName',
              en: 'Imported $fileName',
              ja: '$fileName をインポート',
              ko: '$fileName 가져오기 완료',
            );
    });
    _recordId = recordId;
    _recordSource = 'download';
    if (existing == null) {
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
    }
    if (mounted) {
      setState(() => _sourceFutures.remove('download'));
    }
    if (existing != null && existing.winrateJson.isNotEmpty) {
      try {
        final Map<String, dynamic> raw =
            jsonDecode(existing.winrateJson) as Map<String, dynamic>;
        final dynamic firstValue = raw.isNotEmpty ? raw.values.first : null;
        if (firstValue is num) {
          final Map<int, double> parsed = raw.map(
            (String k, dynamic v) => MapEntry<int, double>(
              int.tryParse(k) ?? 0,
              (v as num).toDouble(),
            ),
          )..remove(0);
          if (mounted && parsed.isNotEmpty) {
            setState(() => _winratesByBranch[''] = Map<int, double>.from(parsed));
          }
        } else if (firstValue is Map && mounted) {
          for (final MapEntry<String, dynamic> entry in raw.entries) {
            final Map<String, dynamic> br =
                (entry.value as Map<dynamic, dynamic>?)?.map(
                  (dynamic k, dynamic v) =>
                      MapEntry<String, dynamic>(k.toString(), v),
                ) ?? <String, dynamic>{};
            final Map<int, double> branch = br.map(
              (String k, dynamic v) => MapEntry<int, double>(
                int.tryParse(k) ?? 0,
                (v as num).toDouble(),
              ),
            )..remove(0);
            if (branch.isNotEmpty) {
              setState(() => _winratesByBranch[entry.key] =
                  Map<int, double>.from(branch));
            }
          }
        }
      } catch (_) {}
    }
  }

  Future<void> _downloadSgf() async {
    final String url = _urlController.text.trim();
    if (url.isEmpty) {
      setState(() {
        _status = _t(
          zh: '请输入 SGF 下载链接',
          en: 'Please enter an SGF URL',
          ja: 'SGF ダウンロードURLを入力してください',
          ko: 'SGF 다운로드 링크를 입력하세요',
        );
      });
      return;
    }
    setState(() {
      _downloading = true;
      _status = _t(
        zh: '下载中...',
        en: 'Downloading...',
        ja: 'ダウンロード中...',
        ko: '다운로드 중...',
      );
    });
    try {
      final Uri uri = Uri.parse(url);
      final http.Response response = await http.get(uri);
      if (response.statusCode != 200) {
        throw StateError('HTTP ${response.statusCode}');
      }
      final String content = response.body;
      if (content.trim().isEmpty) {
        throw StateError(
          _t(
            zh: '下载内容为空',
            en: 'Downloaded content is empty',
            ja: 'ダウンロード内容が空です',
            ko: '다운로드 내용이 비어 있습니다',
          ),
        );
      }
      final SgfGame parsed = _sgfParser.parse(content);
      final String title = uri.pathSegments.isNotEmpty
          ? uri.pathSegments.last
          : 'downloaded.sgf';
      final GameRecord? existing = await _recordRepository
          .findImportBySgfContent(content);
      if (existing == null) {
        _recordId = _recordRepository.newId(prefix: 'download');
        _recordSource = 'download';
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
      } else {
        _recordId = existing.id;
        _recordSource = existing.source;
      }
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
        _winratesByBranch.clear();
        _winrateNotes.clear();
        _status = existing == null
            ? _t(
                zh: '下载并导入成功',
                en: 'Download and import succeeded',
                ja: 'ダウンロードとインポートに成功しました',
                ko: '다운로드 및 가져오기 성공',
              )
            : _t(
                zh: '重复棋谱：已存在，未重复导入',
                en: 'Duplicate SGF: already exists, import skipped',
                ja: '重複棋譜: 既に存在するためインポートをスキップしました',
                ko: '중복 기보: 이미 존재하여 가져오기를 건너뜁니다',
              );
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status =
            '${_t(zh: '下载失败', en: 'Download failed', ja: 'ダウンロード失敗', ko: '다운로드 실패')}: $e';
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

  /// 导出当前棋谱为 SGF 文件并调起系统分享（无需登录）。
  Future<void> _shareSgf() async {
    if (_sgf == null) return;
    try {
      final String sgfString = serializeSgf(_sgf!);
      final Directory dir = await getTemporaryDirectory();
      final String path = p.join(dir.path, 'game.sgf');
      final File file = File(path);
      await file.writeAsString(sgfString, encoding: utf8);
      await Share.shareXFiles(
        <XFile>[XFile(path)],
        text: _sgf!.gameName?.isNotEmpty == true
            ? _sgf!.gameName
            : _t(zh: '棋谱', en: 'SGF game record', ja: '棋譜', ko: '기보'),
      );
    } on Exception catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${_t(zh: '分享失败', en: 'Share failed', ja: '共有失敗', ko: '공유 실패')}: $e',
          ),
        ),
      );
    }
  }

  /// 打谱续下：默认沿用原谱规则，只选难度；当前玩家先下，下一步 AI 下。
  Future<void> _openContinuePlay() async {
    final GoGameState? state = _stateAtPath();
    if (state == null || _sgf == null) {
      return;
    }
    final List<AnalysisProfile> profiles = _reviewProfiles.isNotEmpty
        ? _reviewProfiles
        : <AnalysisProfile>[_fallbackReviewProfile];
    int selectedIndex = _reviewProfileIndex.clamp(0, profiles.length - 1);
    if (!mounted) return;
    final int? chosen = await showDialog<int>(
      context: context,
      builder: (BuildContext context) {
        int index = selectedIndex;
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
                      _t(
                        zh: '选择 AI 难度（规则沿用当前棋谱）',
                        en: 'Select AI strength (rules from current SGF)',
                        ja: 'AI強さを選択（ルールは棋譜に従う）',
                        ko: 'AI 난이도 선택 (규칙은 현재 기보 따름)',
                      ),
                    ),
                    const SizedBox(height: 12),
                    DropdownButton<int>(
                      value: index.clamp(0, profiles.length - 1),
                      isExpanded: true,
                      items: List<DropdownMenuItem<int>>.generate(
                        profiles.length,
                        (int i) => DropdownMenuItem<int>(
                          value: i,
                          child: Text(
                            '${_s.aiProfileName(profiles[i].id, profiles[i].name)} (${profiles[i].maxVisits})',
                          ),
                        ),
                      ),
                      onChanged: (int? value) {
                        if (value != null) {
                          setDialogState(() => index = value);
                        }
                      },
                    ),
                  ],
                ),
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(_t(zh: '取消', en: 'Cancel', ja: 'キャンセル', ko: '취소')),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(index),
                  child: Text(_t(zh: '开始', en: 'Start', ja: '開始', ko: '시작')),
                ),
              ],
            );
          },
        );
      },
    );
    if (chosen == null || !mounted) return;
    selectedIndex = chosen.clamp(0, profiles.length - 1);
    final AnalysisProfile profile = profiles[selectedIndex];
    final GameRules rules = rulePresetFromString(_sgf!.rules).toGameRules(komi: _sgf!.komi);
    await AIPlayPage.pushContinuePlay(
      context,
      initialGameState: state,
      profile: profile,
      rules: rules,
      prefixMoveCount: state.moves.length,
      originalKomi: _sgf!.komi,
      originalRuleset: _sgf!.rules,
      originalInitialBlack: _sgf!.initialBlackStones,
      originalInitialWhite: _sgf!.initialWhiteStones,
      prefixWinrates: _winratesForCurrentBranch.isEmpty
          ? null
          : Map<int, double>.from(_winratesForCurrentBranch),
    );
  }

  /// 可选：若本谱来自对局且保存了更高 visits，分析当前胜率时可沿用并延长超时。
  AnalysisProfile? _gameAnalysisProfile;

  /// 分析当前胜率：对局传入的 profile 优先，否则用当前选中的复盘档位。
  AnalysisProfile _profileForCurrentWinrate() {
    if (_gameAnalysisProfile != null && _gameAnalysisProfile!.maxVisits > 0) {
      return _gameAnalysisProfile!;
    }
    return _currentWinrateProfile;
  }

  /// 读取超时 = 建议思考时间的两倍（与对局一致）。
  int _timeoutMsForCurrentWinrate(AnalysisProfile profile) {
    return profile.thinkingTimeMs * 2;
  }

  /// 打谱提示/局势分析：读取超时 = 建议思考时间的两倍。
  int _timeoutMsForReviewProfile(AnalysisProfile profile) {
    return profile.thinkingTimeMs * 2;
  }

  /// 胜率补全固定使用快速档位（效率优先），与当前选中的复盘档位无关。
  AnalysisProfile _profileForWinrateFill() {
    for (final AnalysisProfile p in _reviewProfiles) {
      if (p.id == 'beginner') return p;
    }
    return _reviewProfiles.isNotEmpty
        ? _reviewProfiles.first
        : _fallbackReviewProfile;
  }

  /// 胜率补全不设单步超时，避免长棋谱中途被判定超时（传较大值给引擎）。
  static const int _winrateFillTimeoutMs = 86400000; // 24h


  Future<void> _analyzeCurrentWinrate() async {
    if (_sgf == null || _analyzing) {
      return;
    }
    setState(() {
      _analyzing = true;
      _status = _t(
        zh: '正在分析当前局面...',
        en: 'Analyzing current position...',
        ja: '現在局面を解析中...',
        ko: '현재 국면 분석 중...',
      );
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
      final String branchKey = _currentBranchKey;
      final double prevWr = _currentTurn <= 1
          ? 0.5
          : (_winratesByBranch[branchKey]?[_currentTurn - 1] ?? 0.5);
      setState(() {
        _winratesByBranch[branchKey] ??= <int, double>{};
        _winratesByBranch[branchKey]!.addAll(data);
        _status = _t(
          zh: '分析完成',
          en: 'Analysis complete',
          ja: '解析完了',
          ko: '분석 완료',
        );
      });
      final double newWr = data[_currentTurn] ?? prevWr;
      _recordWinrateDelta(branchKey, _currentTurn, newWr - prevWr);
      await _persistWinrates();
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
        _status =
            '${_t(zh: '分析失败', en: 'Analysis failed', ja: '解析失敗', ko: '분석 실패')}: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _analyzing = false;
        });
      }
    }
  }

  /// 当前分支胜率未全覆盖时为 true；已完整不显示「胜率自动补全」。
  bool get _isWinrateIncomplete {
    final int total = _path
        .where((SgfNode n) => n.move != null)
        .length;
    if (total <= 0) return false;
    final Map<int, double>? branch = _winratesByBranch[_currentBranchKey];
    for (int t = 1; t <= total; t++) {
      if (branch == null || !branch.containsKey(t)) return true;
    }
    return false;
  }

  Future<void> _persistWinrates() async {
    if (_recordId == null) return;
    final GameRecord? rec = await _recordRepository.loadById(_recordId!);
    if (rec == null) return;
    final Map<String, dynamic> byBranch = <String, dynamic>{};
    for (final MapEntry<String, Map<int, double>> entry
        in _winratesByBranch.entries) {
      if (entry.value.isEmpty) continue;
      byBranch[entry.key] = entry.value
          .map((int k, double v) => MapEntry<String, dynamic>(k.toString(), v));
    }
    // 主战线键 "" 若本次未写入，则保留原记录中的主战线胜率，避免丢失
    if (!byBranch.containsKey('') && rec.winrateJson.isNotEmpty) {
      try {
        final Map<String, dynamic> raw =
            jsonDecode(rec.winrateJson) as Map<String, dynamic>;
        final dynamic firstValue = raw.isNotEmpty ? raw.values.first : null;
        if (firstValue is num) {
          final Map<int, double> parsed = raw.map(
            (String k, dynamic v) => MapEntry<int, double>(
              int.tryParse(k) ?? 0,
              (v as num).toDouble(),
            ),
          )..remove(0);
          if (parsed.isNotEmpty) {
            byBranch[''] = parsed
                .map((int k, double v) => MapEntry<String, dynamic>(k.toString(), v));
          }
        } else if (firstValue is Map && raw[''] != null) {
          final Map<String, dynamic>? mainRaw =
              (raw[''] as Map<dynamic, dynamic>?)?.map(
                (dynamic k, dynamic v) =>
                    MapEntry<String, dynamic>(k.toString(), v),
              );
          if (mainRaw != null && mainRaw.isNotEmpty) {
            byBranch[''] = mainRaw;
          }
        }
      } catch (_) {}
    }
    final String winrateJson = jsonEncode(byBranch);
    final int now = DateTime.now().millisecondsSinceEpoch;
    await _recordRepository.upsert(GameRecord(
      id: rec.id,
      source: rec.source,
      title: rec.title,
      boardSize: rec.boardSize,
      ruleset: rec.ruleset,
      komi: rec.komi,
      sgf: rec.sgf,
      status: rec.status,
      sessionJson: rec.sessionJson,
      winrateJson: winrateJson,
      createdAtMs: rec.createdAtMs,
      updatedAtMs: now,
    ));
  }

  /// 枚举主战线与所有变化图分支：(branchKey, 该分支的 moveTokens)。
  List<({String branchKey, List<String> moveTokens})> _allBranchMoveTokens() {
    if (_sgf == null) return <({String branchKey, List<String> moveTokens})>[];
    final List<SgfNode> mainLine = _sgf!.mainLineNodes();
    final List<({String branchKey, List<String> moveTokens})> out =
        <({String branchKey, List<String> moveTokens})>[];
    List<String> tokens(List<SgfNode> path) {
      return path
          .where((SgfNode n) => n.move != null)
          .map((SgfNode n) => n.move!)
          .map((GoMove m) => m.toProtocolToken(_sgf!.boardSize))
          .toList();
    }
    out.add((branchKey: '', moveTokens: tokens(mainLine)));
    for (int idx = 0; idx < mainLine.length; idx++) {
      final SgfNode node = mainLine[idx];
      if (node.children.length <= 1) continue;
      for (int i = 1; i < node.children.length; i++) {
        final List<SgfNode> variationPath = mainLine.sublist(0, idx + 1) +
            _pathToLeaf(node.children[i]);
        final String key = _pathToBranchKey(variationPath);
        out.add((branchKey: key, moveTokens: tokens(variationPath)));
      }
    }
    return out;
  }

  /// 从某节点起沿 children.first 到叶，返回从该节点起的路径（含该节点）。
  List<SgfNode> _pathToLeaf(SgfNode node) {
    final List<SgfNode> path = <SgfNode>[node];
    SgfNode cur = node;
    while (cur.children.isNotEmpty) {
      cur = cur.children.first;
      path.add(cur);
    }
    return path;
  }

  /// 从第 1 步起逐手补全主战线及所有变化图分支的黑方胜率；已有胜率的步跳过。每步完成后立即刷新曲线并写回记录。
  Future<void> _fillWinrates() async {
    if (_sgf == null || _analyzing || _isFillingWinrate) return;
    final List<({String branchKey, List<String> moveTokens})> branches =
        _allBranchMoveTokens();
    if (branches.isEmpty) return;
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
    final RulePreset preset = rulePresetFromString(_ruleset);
    final double komi = double.tryParse(_komiController.text) ?? preset.defaultKomi;
    final AnalysisProfile profile = _profileForWinrateFill();

    setState(() {
      _isFillingWinrate = true;
      _status = _t(
        zh: '胜率计算中，当前第 0 步',
        en: 'Computing winrate, step 0',
        ja: '勝率計算中、0手目',
        ko: '승률 계산 중, 0수',
      );
    });
    try {
      int stepCount = 0;
      for (final (:branchKey, :moveTokens) in branches) {
        final int totalTurns = moveTokens.length;
        if (totalTurns <= 0) continue;
        _winratesByBranch[branchKey] ??= <int, double>{};
        for (int turn = 1; turn <= totalTurns; turn++) {
          if (!mounted) break;
          if (_winratesByBranch[branchKey]!.containsKey(turn)) continue;
          stepCount++;
          setState(() {
            _status = _t(
              zh: '胜率计算中，当前第 $stepCount 步',
              en: 'Computing winrate, step $stepCount',
              ja: '勝率計算中、$stepCount 手目',
              ko: '승률 계산 중, $stepCount수',
            );
          });
          final Map<int, double> data = await _analysisService.analyzeTurns(
            adapter: _katagoAdapter,
            moveTokens: moveTokens,
            boardSize: _sgf!.boardSize,
            ruleset: _ruleset,
            komi: komi,
            profile: profile,
            initialStones: initialStones,
            startingPlayer: startingPlayer,
            timeoutMs: _winrateFillTimeoutMs,
            startTurn: turn,
            maxTurnsToAnalyze: 1,
          );
          if (!mounted) break;
          setState(() {
            _winratesByBranch[branchKey]!.addAll(data);
          });
          final double prevWr = turn <= 1
              ? 0.5
              : (_winratesByBranch[branchKey]![turn - 1] ?? 0.5);
          final double newWr = data[turn] ?? prevWr;
          _recordWinrateDelta(branchKey, turn, newWr - prevWr);
          await _persistWinrates();
        }
      }
      if (mounted) {
        setState(() {
          _isFillingWinrate = false;
          _status = _isWinrateIncomplete
              ? _t(
                  zh: '胜率补全已暂停（可再次点击继续）',
                  en: 'Winrate fill paused (tap again to continue)',
                  ja: '勝率補完を一時停止（再タップで続行）',
                  ko: '승률 보완 일시 중지 (다시 탭하여 계속)',
                )
              : _t(
                  zh: '胜率补全完成',
                  en: 'Winrate fill complete',
                  ja: '勝率補完完了',
                  ko: '승률 보완 완료',
                );
        });
      }
    } on PlatformException catch (e) {
      if (mounted) {
        setState(() {
          _isFillingWinrate = false;
          _status = e.code == 'ENGINE_TIMEOUT'
              ? _t(
                  zh: '分析超时，可再次点击继续未完成步数',
                  en: 'Analysis timed out. Tap again to continue.',
                  ja: '解析タイムアウト。再タップで続行できます。',
                  ko: '분석 시간 초과. 다시 탭하면 이어서 진행됩니다.',
                )
              : '${_t(zh: '胜率补全失败', en: 'Winrate fill failed', ja: '勝率補完失敗', ko: '승률 보완 실패')}: ${e.message ?? e.code}';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isFillingWinrate = false;
          _status =
              '${_t(zh: '胜率补全失败', en: 'Winrate fill failed', ja: '勝率補完失敗', ko: '승률 보완 실패')}: $e';
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

  Future<KatagoAnalyzeResult> _requestOwnershipAnalysis(
    GoGameState state,
  ) async {
    if (_sgf == null) {
      throw StateError(
        _t(zh: '无棋谱', en: 'No SGF loaded', ja: '棋譜がありません', ko: '기보가 없습니다'),
      );
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
    final StoneColor gameStartingPlayer = _sgf!.initialBlackStones.isNotEmpty
        ? StoneColor.white
        : StoneColor.black;

    /// 复盘局势分析：思考 10s 与对局一致，避免 iOS 超时。
    final AnalysisProfile ownershipProfile = AnalysisProfile(
      id: '${_analysisProfile.id}-ownership-fast',
      name: _analysisProfile.name,
      description: _analysisProfile.description,
      maxVisits: 20,
      thinkingTimeMs: 10000,
      includeOwnership: true,
    );
    final AnalysisProfile reviewProfile = _isThirdPartyRecord
        ? _thirdPartyAnalysisProfile
        : _analysisProfile;
    final int timeoutMs = max(
      _timeoutMsForReviewProfile(ownershipProfile),
      _timeoutMsForReviewProfile(reviewProfile),
    );
    return _katagoAdapter.analyze(
      KatagoAnalyzeRequest(
        queryId: 'review-ownership-${DateTime.now().millisecondsSinceEpoch}',
        moves: moveTokens,
        initialStones: initialStones,
        gameSetup: GameSetup(
          boardSize: _sgf!.boardSize,
          startingPlayer: gameStartingPlayer,
        ),
        rules: preset.toGameRules(komi: komi),
        profile: ownershipProfile,
        includeOwnership: true,
        timeoutMs: timeoutMs,
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
    final StoneColor gameStartingPlayer = _sgf!.initialBlackStones.isNotEmpty
        ? StoneColor.white
        : StoneColor.black;
    final AnalysisProfile hintProfile = _isThirdPartyRecord
        ? _thirdPartyAnalysisProfile
        : _analysisProfile;
    final int timeoutMs = _timeoutMsForReviewProfile(hintProfile);
    final KatagoAnalyzeResult analyzed = await _katagoAdapter.analyze(
      KatagoAnalyzeRequest(
        queryId: 'review-hint-${DateTime.now().millisecondsSinceEpoch}',
        moves: moveTokens,
        initialStones: initialStones,
        gameSetup: GameSetup(
          boardSize: _sgf!.boardSize,
          startingPlayer: gameStartingPlayer,
        ),
        rules: preset.toGameRules(komi: komi),
        profile: hintProfile,
        timeoutMs: timeoutMs,
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
          ? _t(zh: '暂无可用提示点', en: 'No hint points', ja: '候補手なし', ko: '추천 수 없음')
          : _t(
              zh: '提示点已标注（${_reviewHintPoints.length}个）',
              en: 'Hint points marked (${_reviewHintPoints.length})',
              ja: '候補手を表示しました（${_reviewHintPoints.length}件）',
              ko: '추천 수 표시 완료(${_reviewHintPoints.length}개)',
            );
    });
  }

  SgfNode? get _currentNode =>
      _sgf == null ? null : (_path.isEmpty ? _sgf!.root : _path.last);

  int get _currentTurn => _path.length;

  /// 主战线总手数（固定，不随当前是否在变化图而变）。
  int get _mainLineLength =>
      _sgf == null ? 0 : _sgf!.mainLineNodes().length;

  /// 胜率图高亮手数：主战线为当前手数，变化图为分支点手数（便于与主战线尺度一致）。
  int get _chartHighlightTurn {
    if (_currentBranchKey.isEmpty) return _currentTurn;
    final List<String> parts = _currentBranchKey.split('-');
    return parts.isEmpty ? 0 : parts.length;
  }

  /// 变化图分支点手数（主战线上的第几手）；主战线时为 0。
  int get _variationBranchTurn {
    if (_currentBranchKey.isEmpty) return 0;
    final List<String> parts = _currentBranchKey.split('-');
    return parts.isEmpty ? 0 : parts.length;
  }

  /// 变化图内第几手（从分支点算）；主战线时为 0。
  int get _variationLocalTurn {
    if (_currentBranchKey.isEmpty) return 0;
    return _currentTurn - _variationBranchTurn;
  }

  /// 当前路径对应的分支 key（主战线 = ""，变化图 = "0-0-1" 等，到首次偏离为止），用于按分支存胜率。
  String get _currentBranchKey => _pathToBranchKey(_path);

  /// 从根到 path 的子索引序列；主战线（全 0）返回 ""，否则返回到首次非 0 子索引为止的 key。
  String _pathToBranchKey(List<SgfNode> path) {
    if (_sgf == null || path.isEmpty) {
      return '';
    }
    final List<int> indices = <int>[];
    SgfNode parent = _sgf!.root;
    for (final SgfNode node in path) {
      final int i = parent.children.indexOf(node);
      if (i < 0) {
        break;
      }
      indices.add(i);
      parent = node;
    }
    if (indices.isEmpty) return '';
    final int firstNonZero = indices.indexWhere((int i) => i != 0);
    if (firstNonZero < 0) {
      return '';
    }
    return indices.sublist(0, firstNonZero + 1).join('-');
  }

  /// 当前分支的胜率 Map，用于显示与续下传入。
  Map<int, double> get _winratesForCurrentBranch {
    final Map<int, double>? branch = _winratesByBranch[_currentBranchKey];
    if (branch != null && branch.isNotEmpty) {
      return branch;
    }
    return _winrates;
  }

  /// 变化图胜率曲线用色（主战线用 primary，其余循环使用），支持任意数量分支。
  static const List<Color> _variationChartColors = <Color>[
    Colors.orange,
    Colors.green,
    Colors.purple,
    Colors.teal,
    Colors.deepOrange,
    Colors.indigo,
    Colors.amber,
    Colors.cyan,
    Colors.pink,
    Colors.lime,
    Colors.brown,
    Colors.blueGrey,
  ];

  /// 构建多分支胜率曲线列表（主战线 + 各变化图），供图表多色绘制。
  /// 主战线：整条 1..N。变化图：仅从分支点开始的那几手，例如第31手有 5 手变化 → 只画 31–36 一段曲线。
  List<WinrateSeries> _buildWinrateSeries(BuildContext context) {
    if (_winratesByBranch.isEmpty) {
      return <WinrateSeries>[];
    }
    final List<String> keys = _winratesByBranch.keys
        .where((String k) => _winratesByBranch[k]!.isNotEmpty)
        .toList()
      ..sort((String a, String b) {
        if (a.isEmpty) return -1;
        if (b.isEmpty) return 1;
        return a.compareTo(b);
      });
    if (keys.isEmpty) return <WinrateSeries>[];
    final int mainLen = _mainLineLength;
    final Color primary = Theme.of(context).colorScheme.primary;
    final List<WinrateSeries> result = <WinrateSeries>[];
    for (int i = 0; i < keys.length; i++) {
      final String key = keys[i];
      Map<int, double> data = _winratesByBranch[key]!;
      if (key.isNotEmpty) {
        final int branchTurn = key.split('-').length;
        data = Map<int, double>.fromEntries(
          data.entries.where((MapEntry<int, double> e) =>
              e.key >= branchTurn && e.key <= mainLen),
        );
      } else {
        data = Map<int, double>.fromEntries(
          data.entries.where((MapEntry<int, double> e) => e.key <= mainLen),
        );
      }
      if (data.length < 2) continue;
      final Color color = key.isEmpty
          ? primary
          : _variationChartColors[(i - 1) % _variationChartColors.length];
      result.add(WinrateSeries(
        winrates: data,
        color: color,
        label: key.isEmpty ? null : key,
      ));
    }
    return result;
  }

  /// 将当前 SGF 树序列化并写回记录（仅当 _canSaveRecord 时）。
  Future<void> _persistSgf() async {
    if (!_canSaveRecord || _sgf == null || _recordId == null) {
      return;
    }
    final GameRecord? record =
        await _recordRepository.loadById(_recordId!);
    if (record == null || !mounted) {
      return;
    }
    final int now = DateTime.now().millisecondsSinceEpoch;
    final GameRecord updated = GameRecord(
      id: record.id,
      source: record.source,
      title: record.title,
      boardSize: record.boardSize,
      ruleset: record.ruleset,
      komi: record.komi,
      sgf: serializeSgf(_sgf!),
      status: record.status,
      sessionJson: record.sessionJson,
      winrateJson: record.winrateJson,
      createdAtMs: record.createdAtMs,
      updatedAtMs: now,
    );
    await _recordRepository.upsert(updated);
  }

  /// 打开当前节点笔记编辑弹窗；保存后写回 SGF 并持久化。
  Future<void> _openNoteEditor() async {
    final SgfNode? node = _currentNode;
    if (node == null || !_canSaveRecord) {
      return;
    }
    final TextEditingController ctrl = TextEditingController(text: node.comment ?? '');
    if (!mounted) return;
    final String? result = await showDialog<String>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text(
            _t(zh: '打谱笔记', en: 'Note', ja: '棋譜メモ', ko: '기보 메모'),
          ),
          content: TextField(
            controller: ctrl,
            maxLines: 5,
            decoration: InputDecoration(
              hintText: _t(
                zh: '在此输入本手笔记…',
                en: 'Enter note for this move…',
                ja: 'この手のメモを入力…',
                ko: '이 수에 대한 메모 입력…',
              ),
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(ctrl.text),
              child: Text(MaterialLocalizations.of(context).okButtonLabel),
            ),
          ],
        );
      },
    );
    if (result != null && mounted) {
      setState(() {
        node.comment = result.trim().isEmpty ? null : result.trim();
      });
      await _persistSgf();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _t(zh: '笔记已保存', en: 'Note saved', ja: 'メモを保存しました', ko: '메모 저장됨'),
            ),
          ),
        );
      }
    }
  }

  /// 试下保存为变化图：将试下着法作为新分支挂在当前节点，可选标注，然后结束试下。
  Future<void> _saveTryAsVariation() async {
    final GoGameState? boardState = _stateAtPath();
    if (_reviewTryState == null ||
        boardState == null ||
        _sgf == null ||
        _currentNode == null ||
        !_canSaveRecord) {
      return;
    }
    if (_reviewTryState!.moves.length <= boardState.moves.length) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _t(
                zh: '请先试下至少一手',
                en: 'Play at least one try move first',
                ja: '試し打ちを1手以上行ってください',
                ko: '시험 수를 한 수 이상 두세요',
              ),
            ),
          ),
        );
      }
      return;
    }
    final List<GoMove> tryMoves = _reviewTryState!.moves
        .sublist(boardState.moves.length);
    final SgfNode parent = _currentNode!;
    SgfNode? first;
    SgfNode? prev;
    for (final GoMove m in tryMoves) {
      final int moveNum = (prev?.moveNumber ?? parent.moveNumber) + 1;
      final SgfNode n = SgfNode(move: m, moveNumber: moveNum);
      if (first == null) {
        first = n;
      } else {
        prev!.children.add(n);
      }
      prev = n;
    }
    if (first == null) {
      return;
    }
    parent.children.add(first);
    if (mounted) {
      final String? label = await showDialog<String>(
        context: context,
        builder: (BuildContext context) {
          final TextEditingController c = TextEditingController();
          return AlertDialog(
            title: Text(
              _t(zh: '变化图标注', en: 'Variation label', ja: '変化図ラベル', ko: '변화도 라벨'),
            ),
            content: TextField(
              controller: c,
              decoration: InputDecoration(
                hintText: _t(
                  zh: '可选：输入变化图说明',
                  en: 'Optional: variation description',
                  ja: '任意：変化の説明',
                  ko: '선택: 변화도 설명',
                ),
              ),
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(c.text.trim().isEmpty ? null : c.text.trim()),
                child: Text(MaterialLocalizations.of(context).okButtonLabel),
              ),
            ],
          );
        },
      );
      if (label != null && label.isNotEmpty) {
        first.comment = label;
      }
    }
    await _persistSgf();
    if (mounted) {
      setState(() {
        _reviewTryMode = false;
        _reviewTryState = null;
        _reviewTryPendingConfirmTimer.cancel();
        _reviewTryPendingPoint = null;
        _reviewHintPoints = <GoPoint>[];
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _t(zh: '已保存为变化图', en: 'Saved as variation', ja: '変化図として保存しました', ko: '변화도로 저장됨'),
          ),
        ),
      );
    }
  }

  /// 从笔记区点击「变化图k」进入第 k 个变化分支（k≥1 表示非主线的第 k 个续着）。
  /// 变化图链接只出现在「变化发生的那一手」的笔记里：当前手有多个续着时，笔记区显示「本手有 N 个变化图」及链接；棋谱可有多处有变化图，走到哪一手就显示哪一手的内容。
  void _goToVariation(int childIndex) {
    final SgfNode? node = _currentNode;
    if (node == null ||
        childIndex <= 0 ||
        childIndex >= node.children.length) {
      return;
    }
    setState(() {
      _path = <SgfNode>[..._path, node.children[childIndex]];
      _selectedVariation = 0;
      _reviewTryMode = false;
      _reviewTryState = null;
      _reviewTryPendingConfirmTimer.cancel();
      _reviewTryPendingPoint = null;
      _reviewHintPoints = <GoPoint>[];
    });
  }

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
      _reviewTryPendingConfirmTimer.cancel();
      _reviewTryPendingPoint = null;
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
      _reviewTryPendingConfirmTimer.cancel();
      _reviewTryPendingPoint = null;
      _reviewHintPoints = <GoPoint>[];
      _selectMode = false;
      _selectedIds.clear();
    });
  }

  /// 退出变化图，回到分支点（变化图开始的那一手）。
  void _exitVariation() {
    if (_sgf == null || _currentBranchKey.isEmpty) return;
    final List<SgfNode> mainLine = _sgf!.mainLineNodes();
    final int end = _variationBranchTurn.clamp(0, mainLine.length);
    setState(() {
      _path = mainLine.sublist(0, end);
      _selectedVariation = 0;
      _reviewTryMode = false;
      _reviewTryState = null;
      _reviewTryPendingConfirmTimer.cancel();
      _reviewTryPendingPoint = null;
      _reviewHintPoints = <GoPoint>[];
    });
  }

  /// 点击胜率图跳转：X 轴为主战线，故始终跳到主战线第 turn 手。
  void _goToTurn(int turn) {
    if (_sgf == null) {
      return;
    }
    final List<SgfNode> mainLine = _sgf!.mainLineNodes();
    if (turn <= 0) {
      setState(() {
        _path = <SgfNode>[];
        _selectedVariation = 0;
        _reviewTryMode = false;
        _reviewTryState = null;
        _reviewTryPendingConfirmTimer.cancel();
        _reviewTryPendingPoint = null;
        _reviewHintPoints = <GoPoint>[];
      });
      return;
    }
    final int end = turn.clamp(1, mainLine.length);
    setState(() {
      _path = mainLine.sublist(0, end);
      _selectedVariation = 0;
      _reviewTryMode = false;
      _reviewTryState = null;
      _reviewTryPendingConfirmTimer.cancel();
      _reviewTryPendingPoint = null;
      _reviewHintPoints = <GoPoint>[];
    });
  }

  /// 打谱用黑方视角生成妙手/恶手文案（与复盘 buildHints 一致）；用当前分支胜率。
  List<String> _buildReviewHints({required bool good}) {
    if (_winratesForCurrentBranch.isEmpty) {
      return <String>[];
    }
    final List<MoveHint> hints = _analysisService.buildHints(
      _winratesForCurrentBranch,
      playerStone: GoStone.black,
      brilliantEpsilon: 0.05,
    );
    return hints
        .where(
          (MoveHint h) =>
              good ? h.kind == HintKind.brilliant : h.kind == HintKind.blunder,
        )
        .map(
          (MoveHint h) => _t(
            zh: '第${h.turn}手后${_blackWinrateLabel()} ${(h.deltaPlayerWinrate * 100).toStringAsFixed(1)}%',
            en: 'After move ${h.turn}: ${_blackWinrateLabel()} ${(h.deltaPlayerWinrate * 100).toStringAsFixed(1)}%',
            ja: '${h.turn}手後: ${_blackWinrateLabel()} ${(h.deltaPlayerWinrate * 100).toStringAsFixed(1)}%',
            ko: '${h.turn}수 후: ${_blackWinrateLabel()} ${(h.deltaPlayerWinrate * 100).toStringAsFixed(1)}%',
          ),
        )
        .toList();
  }

  String _blackWinrateLabel() {
    final String blackName = (_sgf?.blackName ?? '').trim();
    if (blackName.isEmpty) {
      return _t(zh: '黑方胜率', en: 'Black winrate', ja: '黒勝率', ko: '흑 승률');
    }
    return _t(
      zh: '黑方（$blackName）胜率',
      en: 'Black ($blackName) winrate',
      ja: '黒（$blackName）勝率',
      ko: '흑($blackName) 승률',
    );
  }

  Future<void> _showFullBlackName() async {
    final String blackName = (_sgf?.blackName ?? '').trim();
    if (blackName.isEmpty) {
      return;
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text(
            _t(zh: '黑方全名', en: 'Black full name', ja: '黒番フルネーム', ko: '흑 전체 이름'),
          ),
          content: SelectableText(blackName),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(_t(zh: '关闭', en: 'Close', ja: '閉じる', ko: '닫기')),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_sgf == null) {
      final Widget home = _buildLibraryHome(context);
      final ModalRoute<dynamic>? route = ModalRoute.of(context);
      final bool isPushedPage = route?.canPop == true;
      if (isPushedPage) {
        return Scaffold(
          appBar: AppBar(
            title: Text(
              _t(zh: '打谱复盘', en: 'SGF Review', ja: '棋譜復盤', ko: '기보 복기'),
            ),
          ),
          body: home,
        );
      }
      return Material(child: home);
    }
    final GoGameState? boardState = _stateAtPath();
    final bool compactReviewLayout = _recordId != null;
    final List<String> reviewGoodHints = _buildReviewHints(good: true);
    final List<String> reviewBadHints = _buildReviewHints(good: false);
    final List<WinrateSeries> winrateSeriesList = _buildWinrateSeries(context);
    final Widget content = ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        if (!compactReviewLayout) ...<Widget>[
          Text(_s.tabReview, style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 12),
          Text(
            _t(
              zh: '导入棋谱后会先校验规则信息。若 SGF 缺失贴目或规则，将在导入流程中要求补录，避免分析结果偏差。',
              en: 'After import, rules metadata is validated first. If RU/KM is missing in SGF, you will be asked to complete it.',
              ja: '棋譜インポート後、ルール情報を先に検証します。RU/KM欠落時は補完入力を求めます。',
              ko: '기보 가져오기 후 규칙 정보를 먼저 검증합니다. SGF에 RU/KM이 없으면 보완 입력을 요청합니다.',
            ),
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: _importSgf,
            icon: const Icon(Icons.upload_file),
            label: Text(
              _t(zh: '选择 SGF', en: 'Select SGF', ja: 'SGF選択', ko: 'SGF 선택'),
            ),
          ),
          const SizedBox(height: 8),
          TextFormField(
            controller: _urlController,
            decoration: InputDecoration(
              border: OutlineInputBorder(),
              labelText: _t(
                zh: '在线棋谱链接（SGF URL）',
                en: 'Online SGF URL',
                ja: 'オンライン棋譜URL（SGF）',
                ko: '온라인 SGF 링크',
              ),
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
            label: Text(
              _t(
                zh: '下载并导入棋谱',
                en: 'Download & Import',
                ja: 'ダウンロードしてインポート',
                ko: '다운로드 및 가져오기',
              ),
            ),
          ),
        ],
        if (_sgf != null) ...<Widget>[
          const SizedBox(height: 12),
          Text(
            '${_sgf!.gameName ?? _t(zh: '未命名', en: 'Untitled', ja: '無題', ko: '제목 없음')}  (${_sgf!.blackName ?? 'Black'} vs ${_sgf!.whiteName ?? 'White'})  ${_t(zh: '${_sgf!.mainLineNodes().length}手', en: '${_sgf!.mainLineNodes().length} moves', ja: '${_sgf!.mainLineNodes().length}手', ko: '${_sgf!.mainLineNodes().length}수')}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        ],
        if (!compactReviewLayout) ...<Widget>[
          const SizedBox(height: 20),
          Text(
            _t(
              zh: '规则补录（导入时使用；SGF 内可含 RU/贴目 KM，导入后会带出）',
              en: 'Rule completion (used for import; RU/KM in SGF will be prefilled)',
              ja: 'ルール補完（インポート時使用。SGFのRU/KMは自動反映）',
              ko: '규칙 보완(가져오기 시 사용. SGF의 RU/KM 자동 반영)',
            ),
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            key: ValueKey<String>(_ruleset),
            initialValue: _ruleset,
            items: kRulePresets
                .map(
                  (RulePreset p) => DropdownMenuItem<String>(
                    value: p.id,
                    child: Text(_s.ruleLabel(p.id)),
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
            decoration: InputDecoration(
              border: OutlineInputBorder(),
              labelText: _t(zh: '规则', en: 'Rules', ja: 'ルール', ko: '규칙'),
            ),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _komiController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              border: OutlineInputBorder(),
              labelText: _t(zh: '贴目', en: 'Komi', ja: 'コミ', ko: '덤'),
            ),
          ),
          if (_reviewProfiles.isNotEmpty) ...<Widget>[
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              value: _reviewProfileIndex.clamp(0, _reviewProfiles.length - 1),
              items: List<DropdownMenuItem<int>>.generate(
                _reviewProfiles.length,
                (int i) => DropdownMenuItem<int>(
                  value: i,
                  child: Text(
                    '${_s.aiProfileName(_reviewProfiles[i].id, _reviewProfiles[i].name)} (${_reviewProfiles[i].maxVisits})',
                  ),
                ),
              ),
              onChanged: (int? value) {
                if (value != null) setState(() => _reviewProfileIndex = value);
              },
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                labelText: _t(zh: '难度', en: 'Difficulty', ja: '難易度', ko: '난이도'),
              ),
            ),
          ],
          const SizedBox(height: 20),
        ],
        if (_sgf != null && boardState != null) ...<Widget>[
          if (compactReviewLayout) ...<Widget>[
            if (_reviewProfiles.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: <Widget>[
                    Text(
                      _t(zh: '难度:', en: 'Difficulty:', ja: '難易度:', ko: '난이도:'),
                      style: const TextStyle(fontSize: 13),
                    ),
                    const SizedBox(width: 8),
                    DropdownButton<int>(
                      value: _reviewProfileIndex.clamp(
                        0,
                        _reviewProfiles.length - 1,
                      ),
                      isDense: true,
                      items: List<DropdownMenuItem<int>>.generate(
                        _reviewProfiles.length,
                        (int i) => DropdownMenuItem<int>(
                          value: i,
                          child: Text(
                            '${_s.aiProfileName(_reviewProfiles[i].id, _reviewProfiles[i].name)} (${_reviewProfiles[i].maxVisits})',
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                      ),
                      onChanged: (int? value) {
                        if (value != null)
                          setState(() => _reviewProfileIndex = value);
                      },
                    ),
                  ],
                ),
              ),
          ],
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
                : _t(
                    zh: '已标注 ${_reviewHintPoints.length} 个提示点',
                    en: '${_reviewHintPoints.length} hint points marked',
                    ja: '候補手 ${_reviewHintPoints.length} 件を表示',
                    ko: '추천 수 ${_reviewHintPoints.length}개 표시',
                  ),
            hintLoading: _reviewHintLoading,
            ownershipLoading: _reviewOwnershipLoading,
            // 传入胜率数据（多分支时用不同颜色）；maxTurn 固定为主战线长度，保证主战线胜率完整显示
            currentTurn: _chartHighlightTurn,
            maxTurn: _mainLineLength,
            winrates: winrateSeriesList.isEmpty ? _winrates : null,
            winrateSeries: winrateSeriesList.isEmpty ? null : winrateSeriesList,
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
                _reviewTryPendingConfirmTimer.cancel();
        _reviewTryPendingPoint = null;
                _reviewHintPoints = <GoPoint>[];
              });
            },
            onSaveAsVariation: _canSaveRecord ? _saveTryAsVariation : null,
            tentativePoint: _reviewTryMode ? _reviewTryPendingPoint : null,
            tentativeStone: _reviewTryMode ? (_reviewTryState ?? boardState).toPlay : null,
            onTryPlay: (GoPoint p) {
              _reviewTryPendingConfirmTimer.handleTap(
                p,
                _reviewTryPendingPoint,
                (GoPoint point) {
                  setState(() {
                    _reviewTryPendingPoint = point;
                    _status = _t(
                      zh: '再次点击同一位置确认落子',
                      en: 'Tap the same point again to confirm',
                      ja: '同じ点を再タップで確定',
                      ko: '같은 점을 다시 눌러 확정',
                    );
                  });
                },
                (GoPoint point) {
                  if (_reviewTryPendingPoint != point) return;
                  final GoGameState state = _reviewTryState ?? boardState;
                  try {
                    final GoGameState next = state.play(
                      GoMove(player: state.toPlay, point: point),
                    );
                    _reviewTryPendingConfirmTimer.cancel();
                    setState(() {
                      _reviewTryPendingPoint = null;
                      _reviewTryState = next;
                      _reviewHintPoints = <GoPoint>[];
                    });
                    playStoneSound();
                  } catch (_) {
                    setState(() {
                      _reviewTryPendingConfirmTimer.cancel();
                      _reviewTryPendingPoint = null;
                    });
                  }
                },
              );
            },
            onRequestHint: () async {
              if (_reviewHintLoading || _reviewOwnershipLoading) {
                return;
              }
              setState(() => _reviewHintLoading = true);
              setState(() {
                _status = _t(
                  zh: '正在计算提示点...',
                  en: 'Calculating hint points...',
                  ja: '候補手を計算中...',
                  ko: '추천 수 계산 중...',
                );
              });
              try {
                await _requestReviewHint(_reviewTryState ?? boardState);
              } on PlatformException catch (e) {
                if (!mounted) return;
                final String msg = e.code == 'ENGINE_TIMEOUT'
                    ? _t(
                        zh: '分析超时，请选择较低难度或使用性能更好的设备',
                        en: 'Analysis timed out. Try a lower difficulty or use a faster device.',
                        ja: '解析がタイムアウトしました。難易度を下げるか、性能の良い端末をお試しください。',
                        ko: '분석 시간 초과. 난이도를 낮추거나 성능이 좋은 기기를 사용해 보세요.',
                      )
                    : '${_t(zh: '提示失败', en: 'Hint failed', ja: '候補手取得失敗', ko: '추천 수 실패')}: ${e.message ?? e.code}';
                setState(() {
                  _reviewHintPoints = <GoPoint>[];
                  _status = msg;
                });
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text(msg)));
              } catch (e) {
                if (mounted) {
                  setState(() {
                    _reviewHintPoints = <GoPoint>[];
                    _status =
                        '${_t(zh: '提示失败', en: 'Hint failed', ja: '候補手取得失敗', ko: '추천 수 실패')}: $e';
                  });
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        '${_t(zh: '提示失败', en: 'Hint failed', ja: '候補手取得失敗', ko: '추천 수 실패')}: $e',
                      ),
                    ),
                  );
                }
              }
              if (mounted) setState(() => _reviewHintLoading = false);
            },
            onRequestOwnership: () async {
              if (_reviewOwnershipLoading || _reviewHintLoading) {
                return;
              }
              final GoGameState state = _reviewTryState ?? boardState;
              setState(() => _reviewOwnershipLoading = true);
              setState(() {
                _status = _t(
                  zh: '正在分析局势...',
                  en: 'Analyzing position...',
                  ja: '局勢解析中...',
                  ko: '형세 분석 중...',
                );
              });
              try {
                final KatagoAnalyzeResult res = await _requestOwnershipAnalysis(
                  state,
                );
                if (!mounted) return;
                setState(() => _reviewOwnershipLoading = false);
                showOwnershipResultSheet(context, state, res);
              } on PlatformException catch (e) {
                if (mounted) {
                  setState(() => _reviewOwnershipLoading = false);
                  final String msg = e.code == 'ENGINE_TIMEOUT'
                      ? _t(
                          zh: '分析超时，请选择较低难度或使用性能更好的设备',
                          en: 'Analysis timed out. Try a lower difficulty or use a faster device.',
                          ja: '解析がタイムアウトしました。難易度を下げるか、性能の良い端末をお試しください。',
                          ko: '분석 시간 초과. 난이도를 낮추거나 성능이 좋은 기기를 사용해 보세요.',
                        )
                      : '${_t(zh: '局势分析失败', en: 'Position analysis failed', ja: '局勢解析失敗', ko: '형세 분석 실패')}: ${e.message ?? e.code}';
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(SnackBar(content: Text(msg)));
                }
              } catch (e) {
                if (mounted) {
                  setState(() => _reviewOwnershipLoading = false);
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
            turnNavigation: Row(
              children: <Widget>[
                IconButton(
                  onPressed: _path.isNotEmpty ? _prev : null,
                  icon: const Icon(Icons.chevron_left),
                ),
                if (_currentBranchKey.isNotEmpty)
                  TextButton(
                    onPressed: _exitVariation,
                    child: Text(
                      _t(
                        zh: '退出变化图',
                        en: 'Exit variation',
                        ja: '変化図を出る',
                        ko: '변화도 나가기',
                      ),
                    ),
                  ),
                Expanded(
                  child: Row(
                    children: <Widget>[
                      Flexible(
                        child: Text(
                          _currentBranchKey.isEmpty
                              ? _t(
                                  zh: '手数: $_currentTurn / $_mainLineLength',
                                  en: 'Turn: $_currentTurn / $_mainLineLength',
                                  ja: '手数: $_currentTurn / $_mainLineLength',
                                  ko: '수순: $_currentTurn / $_mainLineLength',
                                )
                              : _t(
                                  zh: '第 $_variationBranchTurn 手 · 变化 第 $_variationLocalTurn 手  (共 $_mainLineLength 手)',
                                  en: 'Move $_variationBranchTurn · Var $_variationLocalTurn  (of $_mainLineLength)',
                                  ja: '$_variationBranchTurn手目 · 変化 $_variationLocalTurn手  (全$_mainLineLength手)',
                                  ko: '$_variationBranchTurn수 · 변화 $_variationLocalTurn수  (총 $_mainLineLength수)',
                                ),
                          style: const TextStyle(fontSize: 13),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: InkWell(
                          onTap: _showFullBlackName,
                          borderRadius: BorderRadius.circular(4),
                          child: Text(
                            _winratesForCurrentBranch.containsKey(_currentTurn)
                                ? '${_blackWinrateLabel()}: ${(_winratesForCurrentBranch[_currentTurn]! * 100).toStringAsFixed(1)}%'
                                : '${_blackWinrateLabel()}: --',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed:
                      (_currentNode != null &&
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
                if (_currentNode != null) ...<Widget>[
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        _t(zh: '笔记', en: 'Note', ja: 'メモ', ko: '메모'),
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            // 笔记区 = 当前这一手的内容。用户笔记、本手变化图链接、胜率升降分别展示。
                            if ((_currentNode!.comment ?? '').trim().isNotEmpty)
                              Text(
                                _currentNode!.comment!.trim(),
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 13),
                              ),
                            if (_currentNode!.children.length > 1) ...<Widget>[
                              if ((_currentNode!.comment ?? '').trim().isNotEmpty)
                                const SizedBox(height: 4),
                              Text(
                                _t(
                                  zh: '本手有 ${_currentNode!.children.length - 1} 个变化图：',
                                  en: '${_currentNode!.children.length - 1} variation(s) at this move:',
                                  ja: '本手に変化図${_currentNode!.children.length - 1}件：',
                                  ko: '이 수에 변화도 ${_currentNode!.children.length - 1}개:',
                                ),
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Theme.of(context).colorScheme.secondary,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Wrap(
                                spacing: 8,
                                runSpacing: 4,
                                children: List<Widget>.generate(
                                  _currentNode!.children.length - 1,
                                  (int i) {
                                    final int childIndex = i + 1;
                                    return InkWell(
                                      onTap: () => _goToVariation(childIndex),
                                      borderRadius: BorderRadius.circular(4),
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 6,
                                          vertical: 2,
                                        ),
                                        child: Text(
                                          _t(
                                            zh: '变化图$childIndex',
                                            en: 'Variation $childIndex',
                                            ja: '変化図$childIndex',
                                            ko: '변화도 $childIndex',
                                          ),
                                          style: TextStyle(
                                            fontSize: 13,
                                            color: Theme.of(context)
                                                .colorScheme.primary,
                                            decoration: TextDecoration.underline,
                                          ),
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              ),
                            ],
                            if (_winrateNotes[_currentBranchKey]
                                    ?.containsKey(_currentTurn.toString()) ==
                                true) ...<Widget>[
                              if ((_currentNode!.comment ?? '').trim().isNotEmpty ||
                                  _currentNode!.children.length > 1)
                                const SizedBox(height: 4),
                              Text(
                                _winrateNotes[_currentBranchKey]![_currentTurn.toString()]!,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Theme.of(context).colorScheme.secondary,
                                ),
                              ),
                            ],
                            if ((_currentNode!.comment ?? '').trim().isEmpty &&
                                _currentNode!.children.length <= 1 &&
                                _winrateNotes[_currentBranchKey]
                                    ?.containsKey(_currentTurn.toString()) !=
                                    true)
                              Text(
                                '—',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: Theme.of(context).hintColor,
                                ),
                              ),
                          ],
                        ),
                      ),
                      if (_canSaveRecord)
                        TextButton.icon(
                          onPressed: _openNoteEditor,
                          icon: const Icon(Icons.edit_note, size: 20),
                          label: Text(
                            _t(zh: '编辑', en: 'Edit', ja: '編集', ko: '편집'),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                ],
                if (_winratesByBranch.isNotEmpty &&
                    _winratesByBranch.values.any(
                        (Map<int, double> m) => m.isNotEmpty)) ...<Widget>[
                  Text(
                    _t(zh: '妙手提示', en: 'Brilliant Moves', ja: '妙手', ko: '묘수'),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  if (reviewGoodHints.isEmpty)
                    Text(
                      _t(
                        zh: '暂无明显妙手',
                        en: 'No obvious brilliant moves',
                        ja: '目立つ妙手なし',
                        ko: '뚜렷한 묘수 없음',
                      ),
                    )
                  else
                    ...reviewGoodHints.map(Text.new),
                  const SizedBox(height: 8),
                  Text(
                    _t(zh: '恶手提示', en: 'Blunders', ja: '悪手', ko: '악수'),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  if (reviewBadHints.isEmpty)
                    Text(
                      _t(
                        zh: '暂无明显恶手',
                        en: 'No obvious blunders',
                        ja: '目立つ悪手なし',
                        ko: '뚜렷한 악수 없음',
                      ),
                    )
                  else
                    ...reviewBadHints.map(Text.new),
                  const SizedBox(height: 12),
                ],
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    if (_isWinrateIncomplete && !_isFillingWinrate) ...[
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        ),
                        onPressed: _analyzing ? null : _fillWinrates,
                        icon: const Icon(Icons.auto_fix_high, size: 18),
                        label: Text(
                          _t(
                            zh: '胜率自动补全',
                            en: 'Fill winrate',
                            ja: '勝率を自動補完',
                            ko: '승률 자동 보완',
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      ),
                      onPressed: (_analyzing || _isFillingWinrate) ? null : _analyzeCurrentWinrate,
                      icon: _analyzing
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.analytics_outlined, size: 18),
                      label: Text(
                        _t(
                          zh: '分析当前胜率',
                          en: 'Analyze current winrate',
                          ja: '現在勝率を解析',
                          ko: '현재 승률 분석',
                        ),
                      ),
                    ),
                  ],
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
        appBar: AppBar(
          title: Text(
            _t(zh: '打谱复盘', en: 'SGF Review', ja: '棋譜復盤', ko: '기보 복기'),
          ),
          actions: <Widget>[
            IconButton(
              onPressed: _sgf == null ? null : _shareSgf,
              icon: const Icon(Icons.share, size: 22),
              tooltip: _t(zh: '分享棋谱', en: 'Share SGF', ja: '棋譜を共有', ko: '기보 공유'),
            ),
            TextButton.icon(
              onPressed: _stateAtPath() == null ? null : _openContinuePlay,
              icon: const Icon(Icons.play_arrow, size: 20),
              label: Text(_t(zh: '续下', en: 'Continue', ja: '続き対局', ko: '계속 대국')),
            ),
          ],
        ),
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
  AppStrings get _s => AppStrings.of(context);
  String _t({
    required String zh,
    required String en,
    required String ja,
    required String ko,
  }) => _s.pick(zh: zh, en: en, ja: ja, ko: ko);

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
      final _PickedSgfFile? picked = await _pickSgfWithDownloadPriority(
        context,
      );
      if (picked == null) {
        return;
      }
      if (!mounted) {
        return;
      }
      late final SgfGame parsed;
      try {
        parsed = _sgfParser.parse(picked.content);
      } catch (_) {
        setState(() {
          _status = _t(
            zh: '导入失败：文件格式错误（非SGF）',
            en: 'Import failed: invalid SGF format',
            ja: 'インポート失敗: SGF形式エラー',
            ko: '가져오기 실패: SGF 형식 오류',
          );
        });
        return;
      }
      final String ruleset = parsed.rules.isEmpty
          ? 'chinese'
          : rulePresetFromString(parsed.rules).id;
      Navigator.of(context).pop(
        _ImportResult(
          sgf: picked.content,
          title: picked.fileName,
          source: 'download',
          ruleset: ruleset,
          komi: parsed.komi,
        ),
      );
    } catch (e) {
      setState(() {
        _status =
            '${_t(zh: '导入失败', en: 'Import failed', ja: 'インポート失敗', ko: '가져오기 실패')}: $e';
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
        _status = _t(
          zh: '请输入 SGF URL',
          en: 'Please input SGF URL',
          ja: 'SGF URL を入力してください',
          ko: 'SGF URL을 입력하세요',
        );
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
        _status =
            '${_t(zh: '下载失败', en: 'Download failed', ja: 'ダウンロード失敗', ko: '다운로드 실패')}: $e';
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
      appBar: AppBar(
        title: Text(
          _t(zh: '导入棋谱', en: 'Import SGF', ja: '棋譜インポート', ko: '기보 가져오기'),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          FilledButton.icon(
            onPressed: _loading ? null : _pickFile,
            icon: const Icon(Icons.upload_file),
            label: Text(
              _t(zh: '选择 SGF', en: 'Select SGF', ja: 'SGF選択', ko: 'SGF 선택'),
            ),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _urlController,
            decoration: InputDecoration(
              border: OutlineInputBorder(),
              labelText: _t(
                zh: 'SGF URL',
                en: 'SGF URL',
                ja: 'SGF URL',
                ko: 'SGF URL',
              ),
            ),
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _loading ? null : _downloadByUrl,
            icon: const Icon(Icons.download),
            label: Text(
              _t(
                zh: '下载并导入',
                en: 'Download & Import',
                ja: 'ダウンロードしてインポート',
                ko: '다운로드 및 가져오기',
              ),
            ),
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
