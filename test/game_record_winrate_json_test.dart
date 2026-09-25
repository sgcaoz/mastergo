import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mastergo/application/batch/master_winrate_checkpoint.dart';
import 'package:mastergo/domain/entities/game_record.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test('nested main-line winrate json from the batch is treated as present', () {
    final String json = winrateJsonForDb(<int, double>{0: 0.5, 1: 0.42, 2: 0.4});
    expect(storedWinrateJsonHasMoves(json), isTrue);
    final Map<String, Map<int, double>> parsed = parseStoredWinrateJson(json);
    expect(parsed[''], isNotNull);
    expect(parsed['']![1], 0.42);
    expect(parsed['']!.containsKey(0), isFalse);
  });

  test('flat legacy winrate json still paints the main line', () {
    const String json = '{"0":0.5,"1":0.61,"2":0.58}';
    final Map<int, double> main = parseStoredWinrateJson(json)['']!;
    expect(main[1], 0.61);
    expect(main.containsKey(0), isFalse);
  });

  test('empty payloads are treated as missing', () {
    expect(storedWinrateJsonHasMoves(''), isFalse);
    expect(storedWinrateJsonHasMoves('{}'), isFalse);
    expect(storedWinrateJsonHasMoves('{"":{}}'), isFalse);
    expect(parseStoredWinrateJson('{"":{}}'), isEmpty);
  });

  test('sqlite blob columns decode as utf8 text', () {
    final Uint8List bytes = Uint8List.fromList(utf8.encode('{"1":0.5}'));
    expect(sqliteText(bytes), '{"1":0.5}');
    expect(storedWinrateJsonHasMoves(sqliteText(bytes)), isTrue);
  });

  test('bundled seed winrate json is readable by the review chart', () {
    final File seed = File('assets/master_games/mastergo_seed.db');
    expect(seed.existsSync(), isTrue);
    final Database db = sqlite3.open(seed.path, mode: OpenMode.readOnly);
    addTearDown(db.dispose);
    final ResultSet rows = db.select(
      "SELECT id, winrateJson FROM game_records WHERE source = 'master'",
    );
    int withMoves = 0;
    for (final Row row in rows) {
      final String json = sqliteText(row['winrateJson']);
      if (parseStoredWinrateJson(json).values.any(
        (Map<int, double> turns) => turns.length >= 2,
      )) {
        withMoves++;
      }
    }
    expect(withMoves, greaterThanOrEqualTo(120));
  });
}
