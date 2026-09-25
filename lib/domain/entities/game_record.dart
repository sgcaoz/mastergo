import 'dart:convert';
import 'dart:typed_data';

int sqliteInt(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return int.parse(value.toString());
}

double sqliteDouble(Object? value) {
  if (value is num) {
    return value.toDouble();
  }
  return double.parse(value.toString());
}

String sqliteText(Object? value, [String fallback = '']) {
  if (value == null) {
    return fallback;
  }
  if (value is String) {
    return value;
  }
  if (value is Uint8List) {
    return utf8.decode(value);
  }
  return value.toString();
}

Map<int, double> _turnWinratesFromMap(Map<dynamic, dynamic> raw) {
  final Map<int, double> parsed = <int, double>{};
  for (final MapEntry<dynamic, dynamic> entry in raw.entries) {
    final int? turn = int.tryParse(entry.key.toString());
    final dynamic value = entry.value;
    if (turn == null || turn <= 0 || value is! num) {
      continue;
    }
    parsed[turn] = value.toDouble();
  }
  return parsed;
}

/// 本地/种子库胜率 JSON → 分支 key（主战线为 ""）→ 手数 → 黑方胜率。
/// 兼容扁平 `{ "1": 0.55 }` 与按分支 `{ "": { "1": 0.55 } }`。
Map<String, Map<int, double>> parseStoredWinrateJson(String raw) {
  final String trimmed = raw.trim();
  if (trimmed.isEmpty || trimmed == '{}') {
    return <String, Map<int, double>>{};
  }
  try {
    final Object decoded = jsonDecode(trimmed);
    if (decoded is! Map || decoded.isEmpty) {
      return <String, Map<int, double>>{};
    }
    final Map<dynamic, dynamic> root = Map<dynamic, dynamic>.from(decoded);
    final dynamic firstValue = root.values.first;
    if (firstValue is num) {
      final Map<int, double> main = _turnWinratesFromMap(root);
      if (main.isEmpty) {
        return <String, Map<int, double>>{};
      }
      return <String, Map<int, double>>{'': main};
    }
    final Map<String, Map<int, double>> loaded = <String, Map<int, double>>{};
    for (final MapEntry<dynamic, dynamic> entry in root.entries) {
      final dynamic value = entry.value;
      if (value is! Map) {
        continue;
      }
      final Map<int, double> branch = _turnWinratesFromMap(value);
      if (branch.isNotEmpty) {
        loaded[entry.key.toString()] = branch;
      }
    }
    return loaded;
  } catch (_) {
    return <String, Map<int, double>>{};
  }
}

bool storedWinrateJsonHasMoves(String raw) {
  return parseStoredWinrateJson(
    raw,
  ).values.any((Map<int, double> turns) => turns.isNotEmpty);
}

class GameRecord {
  const GameRecord({
    required this.id,
    required this.source,
    required this.title,
    required this.boardSize,
    required this.ruleset,
    required this.komi,
    required this.sgf,
    required this.status,
    required this.sessionJson,
    required this.winrateJson,
    required this.createdAtMs,
    required this.updatedAtMs,
  });

  final String id;
  final String source;
  final String title;
  final int boardSize;
  final String ruleset;
  final double komi;
  final String sgf;
  final String status;
  final String sessionJson;
  final String winrateJson;
  final int createdAtMs;
  final int updatedAtMs;

  Map<String, Object?> toMap() {
    return <String, Object?>{
      'id': id,
      'source': source,
      'title': title,
      'boardSize': boardSize,
      'ruleset': ruleset,
      'komi': komi,
      'sgf': sgf,
      'status': status,
      'sessionJson': sessionJson,
      'winrateJson': winrateJson,
      'createdAtMs': createdAtMs,
      'updatedAtMs': updatedAtMs,
    };
  }

  factory GameRecord.fromMap(Map<String, Object?> map) {
    return GameRecord(
      id: sqliteText(map['id']),
      source: sqliteText(map['source']),
      title: sqliteText(map['title']),
      boardSize: sqliteInt(map['boardSize']),
      ruleset: sqliteText(map['ruleset']),
      komi: sqliteDouble(map['komi']),
      sgf: sqliteText(map['sgf']),
      status: sqliteText(map['status']),
      sessionJson: sqliteText(map['sessionJson'], '{}'),
      winrateJson: sqliteText(map['winrateJson'], '{}'),
      createdAtMs: sqliteInt(map['createdAtMs']),
      updatedAtMs: sqliteInt(map['updatedAtMs']),
    );
  }
}
