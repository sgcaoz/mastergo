// 用 App 内 SgfParser + GoGame 校验暂存棋谱，去重后写入 assets 并生成目录。
// 运行：dart run tool/validate_master_games.dart
import 'dart:convert';
import 'dart:io';

import 'package:mastergo/domain/entities/master_game_meta.dart';
import 'package:mastergo/domain/entities/rule_presets.dart';
import 'package:mastergo/domain/go/go_game.dart';
import 'package:mastergo/domain/go/go_types.dart';
import 'package:mastergo/domain/sgf/sgf_parser.dart';
import 'package:mastergo/infra/config/master_games_data.dart';
import 'package:path/path.dart' as p;

void main() {
  final String root = p.current;
  final Directory staging = Directory('/tmp/mastergo_sgf/staging');
  final Directory outDir = Directory(p.join(root, 'assets', 'master_games'));
  final File catalogFile = File(
    p.join(root, 'assets', 'config', 'master_games.json'),
  );
  const SgfParser parser = SgfParser();

  final List<_Candidate> accepted = <_Candidate>[];
  final Set<String> fingerprints = <String>{};

  void consider(_Candidate c) {
    if (c.boardSize != 19) {
      stdout.writeln('REJECT size=${c.boardSize} ${c.id}');
      return;
    }
    if (c.moveCount < (c.handicap >= 2 ? 50 : 80) && c.illegalRatio > 0) {
      stdout.writeln('REJECT short+illegal ${c.id} moves=${c.moveCount}');
      return;
    }
    if (c.moveCount < 50) {
      stdout.writeln('REJECT short ${c.id} moves=${c.moveCount}');
      return;
    }
    if (c.illegalRatio > 0.15) {
      stdout.writeln(
        'REJECT illegal ${(c.illegalRatio * 100).toStringAsFixed(0)}% ${c.id}',
      );
      return;
    }
    if (fingerprints.contains(c.fingerprint)) {
      stdout.writeln(
        'DUP ${c.id} ~ ${c.blackName} vs ${c.whiteName} ${c.year}',
      );
      return;
    }
    fingerprints.add(c.fingerprint);
    accepted.add(c);
  }

  for (final MasterGameMeta meta in masterGamesList) {
    final File sgfFile = File(p.join(root, meta.sgfAssetPath));
    final _Candidate? parsed = _analyze(
      parser,
      id: meta.id,
      sgf: sgfFile.readAsStringSync(),
      category: _categoryForExisting(meta),
      tags: _tagsForExisting(meta),
      source: meta.sgfAssetPath,
      titleOverride: meta.title,
      playersOverride: meta.players,
      eventOverride: meta.event,
      yearOverride: meta.year,
      rulesetOverride: meta.ruleset,
      komiOverride: meta.komi,
    );
    if (parsed == null) {
      stdout.writeln('REJECT existing ${meta.id}');
      continue;
    }
    consider(parsed);
  }

  if (staging.existsSync()) {
    final List<File> staged =
        staging
            .listSync()
            .whereType<File>()
            .where((File f) => f.path.endsWith('.sgf'))
            .toList()
          ..sort((File a, File b) => a.path.compareTo(b.path));
    for (final File sgfFile in staged) {
      final String id = p.basenameWithoutExtension(sgfFile.path);
      final File metaFile = File(p.join(staging.path, '$id.meta'));
      String category = 'classic';
      List<String> tags = <String>['famous'];
      String source = id;
      if (metaFile.existsSync()) {
        final Map<String, String> kv = <String, String>{};
        for (final String line in metaFile.readAsLinesSync()) {
          final int i = line.indexOf('=');
          if (i <= 0) continue;
          kv[line.substring(0, i)] = line.substring(i + 1);
        }
        category = kv['category'] ?? category;
        source = kv['source'] ?? source;
        tags = (kv['tags'] ?? '')
            .split(',')
            .map((String s) => s.trim())
            .where((String s) => s.isNotEmpty)
            .toList();
      }
      final _Candidate? parsed = _analyze(
        parser,
        id: id,
        sgf: sgfFile.readAsStringSync(),
        category: category,
        tags: tags,
        source: source,
      );
      if (parsed == null) {
        stdout.writeln('REJECT parse $id');
        continue;
      }
      consider(parsed);
    }
  }

  accepted.sort((a, b) {
    final int cat = _categoryRank(
      a.category,
    ).compareTo(_categoryRank(b.category));
    if (cat != 0) return cat;
    final int y = a.year.compareTo(b.year);
    if (y != 0) return y;
    return a.title.compareTo(b.title);
  });

  final List<Map<String, dynamic>> games = <Map<String, dynamic>>[];
  for (final _Candidate c in accepted) {
    final String rel = c.source.startsWith('assets/master_games/')
        ? c.source
        : 'assets/master_games/${c.id}.sgf';
    final File dest = File(p.join(root, rel));
    if (!c.source.startsWith('assets/master_games/')) {
      dest.writeAsStringSync(c.sgf.endsWith('\n') ? c.sgf : '${c.sgf}\n');
    }
    games.add(<String, dynamic>{
      'id': c.id,
      'title': c.title,
      'players': c.players,
      'event': c.event,
      'year': c.year,
      'boardSize': c.boardSize,
      'ruleset': c.ruleset,
      'komi': c.komi,
      'sgfAssetPath': rel,
      'category': c.category,
      'tags': <String>{c.category, ...c.tags}.toList(),
      'result': c.result,
      'moveCount': c.moveCount,
      'illegalMoves': c.illegalMoves,
    });
  }

  final Map<String, dynamic> catalog = <String, dynamic>{
    'version': 2,
    'source':
        'Andries Brouwer public-domain archive + tasuki famous games + existing MasterGo set',
    'categories': <Map<String, dynamic>>[
      <String, dynamic>{'id': 'ancient', 'sort': 1},
      <String, dynamic>{'id': 'international', 'sort': 2},
      <String, dynamic>{'id': 'classic', 'sort': 3},
      <String, dynamic>{'id': 'ai', 'sort': 4},
    ],
    'games': games,
  };
  catalogFile.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(catalog)}\n',
  );

  final Map<String, int> byCat = <String, int>{};
  for (final _Candidate c in accepted) {
    byCat[c.category] = (byCat[c.category] ?? 0) + 1;
  }
  stdout.writeln('accepted ${accepted.length}  $byCat');
  stdout.writeln('wrote ${catalogFile.path}');
}

int _categoryRank(String id) {
  const List<String> order = <String>[
    'ancient',
    'international',
    'classic',
    'ai',
  ];
  final int i = order.indexOf(id);
  return i < 0 ? 99 : i;
}

String _categoryForExisting(MasterGameMeta meta) {
  if (meta.id.contains('alphago')) return 'ai';
  if (meta.id.contains('samsung') || meta.id.startsWith('nie_')) {
    return 'international';
  }
  if (meta.year > 0 && meta.year < 1900) return 'ancient';
  return 'classic';
}

List<String> _tagsForExisting(MasterGameMeta meta) {
  final List<String> tags = <String>['builtin'];
  if (meta.id.contains('alphago')) tags.add('alphago');
  if (meta.id.contains('samsung')) tags.add('samsung_cup');
  if (meta.id.startsWith('nie_')) tags.add('china_japan_supergo');
  if (meta.id.contains('go_seigen')) tags.add('go_seigen');
  return tags;
}

_Candidate? _analyze(
  SgfParser parser, {
  required String id,
  required String sgf,
  required String category,
  required List<String> tags,
  required String source,
  String? titleOverride,
  String? playersOverride,
  String? eventOverride,
  int? yearOverride,
  String? rulesetOverride,
  double? komiOverride,
}) {
  try {
    final parsed = parser.parse(sgf);
    final List<SgfNode> main = parsed
        .mainLineNodes()
        .where((SgfNode n) => n.move != null)
        .toList();
    int illegal = 0;
    final List<List<GoStone?>> board = List<List<GoStone?>>.generate(
      parsed.boardSize,
      (_) => List<GoStone?>.filled(parsed.boardSize, null),
    );
    for (final GoPoint pt in parsed.initialBlackStones) {
      if (pt.x >= 0 &&
          pt.y >= 0 &&
          pt.x < parsed.boardSize &&
          pt.y < parsed.boardSize) {
        board[pt.y][pt.x] = GoStone.black;
      }
    }
    for (final GoPoint pt in parsed.initialWhiteStones) {
      if (pt.x >= 0 &&
          pt.y >= 0 &&
          pt.x < parsed.boardSize &&
          pt.y < parsed.boardSize) {
        board[pt.y][pt.x] = GoStone.white;
      }
    }
    final bool handicapLike =
        parsed.initialBlackStones.isNotEmpty &&
        parsed.initialWhiteStones.isEmpty;
    GoGameState state = GoGameState(
      boardSize: parsed.boardSize,
      board: board,
      toPlay: handicapLike ? GoStone.white : GoStone.black,
    );
    for (final SgfNode node in main) {
      final GoMove move = node.move!;
      try {
        if (move.player != state.toPlay) {
          // 录谱偶发连下：插入虚着后再试。
          state = state.play(GoMove(player: state.toPlay, isPass: true));
        }
        state = state.play(move);
      } catch (_) {
        illegal += 1;
        if (move.player == state.toPlay) {
          // 无法落子则跳过该手，避免整盘中断导致后续误判。
          continue;
        }
      }
    }

    final int year = yearOverride ?? _yearFromSgf(sgf);
    final RulePreset preset = _rulesetOf(
      parsed,
      category: category,
      year: year,
    );
    final String black = (parsed.blackName ?? '').trim();
    final String white = (parsed.whiteName ?? '').trim();
    final String event =
        (eventOverride ?? _prop(sgf, 'EV') ?? parsed.gameName ?? '').trim();
    final String title = titleOverride ?? _titleOf(id, parsed, tags);
    final String players =
        playersOverride ??
        '${black.isEmpty ? "?" : black}(黑) vs ${white.isEmpty ? "?" : white}(白)';
    final String fp = _fingerprint(main, parsed.boardSize);
    return _Candidate(
      id: id,
      sgf: sgf.trim(),
      source: source,
      category: category,
      tags: tags,
      title: title,
      players: players,
      event: event.isEmpty ? _eventFromTags(tags, parsed) : event,
      year: year,
      boardSize: parsed.boardSize,
      ruleset: rulesetOverride ?? preset.id,
      komi: komiOverride ?? (category == 'ancient' ? 0 : parsed.komi),
      result: parsed.result ?? '',
      moveCount: main.length,
      illegalMoves: illegal,
      blackName: black,
      whiteName: white,
      fingerprint: fp,
      handicap: parsed.initialBlackStones.length,
    );
  } catch (e) {
    stdout.writeln('PARSE $id $e');
    return null;
  }
}

int _yearFromSgf(String sgf) {
  final Match? m = RegExp(r'DT\[(\d{4})').firstMatch(sgf);
  return int.tryParse(m?.group(1) ?? '') ?? 0;
}

String? _prop(String sgf, String key) {
  final Match? m = RegExp('$key\\[(.*?)\\]').firstMatch(sgf);
  return m?.group(1);
}

RulePreset _rulesetOf(
  SgfGame parsed, {
  required String category,
  required int year,
}) {
  if (category == 'ancient' || (year > 0 && year < 1900)) {
    return rulePresetFromString('classical');
  }
  return rulePresetFromString(parsed.rules);
}

String _titleOf(String id, SgfGame parsed, List<String> tags) {
  const Map<String, String> famous = <String, String>{
    'shusaku_126': '耳赤之局',
    'famous_1846': '耳赤之局',
    'famous_1835': '吐血之局',
    'ancient_honinbo_jowa_276': '吐血之局',
    'dosaku_122': '道策一生杰作',
    'dosaku_059': '道策天元开局',
    'famous_1582': '三劫循环之局',
    'famous_1683': '道策一生杰作',
    'famous_1945': '原爆下的对局',
    'famous_1933': '吴清源 十六士',
    'famous_1934': '吴清源 vs 本因坊秀哉（名人）',
    'famous_1939': '镰仓十番棋',
    'alphago_may2017_4': '乌镇团体赛 五人 vs AlphaGo',
  };
  if (famous.containsKey(id)) {
    return famous[id]!;
  }
  if (id.startsWith('ancient_old_chinese_dh')) {
    final String n = id.replaceAll(RegExp(r'[^0-9]'), '');
    return '当湖十局 第${int.tryParse(n) ?? n}局';
  }
  final String gn = (parsed.gameName ?? '').trim();
  if (gn.isNotEmpty && gn.length <= 40) {
    return gn;
  }
  final String black = (parsed.blackName ?? '?').trim();
  final String white = (parsed.whiteName ?? '?').trim();
  return '$black vs $white';
}

String _eventFromTags(List<String> tags, SgfGame parsed) {
  const Map<String, String> names = <String, String>{
    'ing_cup': 'Ing Cup',
    'lg_cup': 'LG Cup',
    'samsung_cup': 'Samsung Cup',
    'chunlan_cup': 'Chunlan Cup',
    'mlily_cup': 'Mlily Cup',
    'toyota_denso_cup': 'Toyota Denso Cup',
    'asian_tv_cup': 'Asian TV Cup',
    'fujitsu_cup': 'Fujitsu Cup',
    'danghu': '当湖十局',
    'alphago': 'AlphaGo',
    'fan_hui': 'AlphaGo vs Fan Hui',
    'wuzhen': 'Future of Go Summit',
    'famous': 'Famous game',
  };
  for (final String tag in tags) {
    final String? n = names[tag];
    if (n != null) return n;
  }
  return parsed.gameName ?? '';
}

String _fingerprint(List<SgfNode> main, int boardSize) {
  final StringBuffer sb = StringBuffer();
  final int n = main.length < 40 ? main.length : 40;
  for (int i = 0; i < n; i++) {
    final GoMove? m = main[i].move;
    if (m == null || m.isPass || m.point == null) {
      sb.write('p');
    } else {
      sb.write('${m.player.sgfColor}${m.point!.x},${m.point!.y};');
    }
  }
  return '$boardSize:${main.length}:$sb';
}

class _Candidate {
  _Candidate({
    required this.id,
    required this.sgf,
    required this.source,
    required this.category,
    required this.tags,
    required this.title,
    required this.players,
    required this.event,
    required this.year,
    required this.boardSize,
    required this.ruleset,
    required this.komi,
    required this.result,
    required this.moveCount,
    required this.illegalMoves,
    required this.blackName,
    required this.whiteName,
    required this.fingerprint,
    required this.handicap,
  });

  final String id;
  final String sgf;
  final String source;
  final String category;
  final List<String> tags;
  final String title;
  final String players;
  final String event;
  final int year;
  final int boardSize;
  final String ruleset;
  final double komi;
  final String result;
  final int moveCount;
  final int illegalMoves;
  final String blackName;
  final String whiteName;
  final String fingerprint;
  final int handicap;

  double get illegalRatio => moveCount == 0 ? 1 : illegalMoves / moveCount;
}
