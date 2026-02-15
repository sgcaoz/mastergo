import 'dart:math';

import 'package:mastergo/domain/entities/game_record.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

class GameRecordRepository {
  GameRecordRepository();

  static const String _table = 'game_records';
  static Database? _db;

  Future<Database> _database() async {
    if (_db != null) {
      return _db!;
    }
    final String base = await getDatabasesPath();
    final String path = p.join(base, 'mastergo_records.db');
    _db = await openDatabase(
      path,
      version: 1,
      onCreate: (Database db, int version) async {
        await db.execute('''
          CREATE TABLE $_table(
            id TEXT PRIMARY KEY,
            source TEXT NOT NULL,
            title TEXT NOT NULL,
            boardSize INTEGER NOT NULL,
            ruleset TEXT NOT NULL,
            komi REAL NOT NULL,
            sgf TEXT NOT NULL,
            status TEXT NOT NULL,
            sessionJson TEXT NOT NULL,
            winrateJson TEXT NOT NULL,
            createdAtMs INTEGER NOT NULL,
            updatedAtMs INTEGER NOT NULL
          )
        ''');
        await db.execute(
          'CREATE INDEX idx_records_source_updated ON $_table(source, updatedAtMs DESC)',
        );
      },
    );
    return _db!;
  }

  String newId({String prefix = 'rec'}) {
    final int now = DateTime.now().millisecondsSinceEpoch;
    final int salt = Random().nextInt(1 << 20);
    return '$prefix-$now-$salt';
  }

  Future<void> upsert(GameRecord record) async {
    final Database db = await _database();
    await db.insert(
      _table,
      record.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<GameRecord?> loadLatestBySource(String source) async {
    final Database db = await _database();
    final List<Map<String, Object?>> rows = await db.query(
      _table,
      where: 'source = ?',
      whereArgs: <Object?>[source],
      orderBy: 'updatedAtMs DESC',
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    return GameRecord.fromMap(rows.first);
  }

  Future<void> saveMasterGame({
    required String id,
    required String title,
    required int boardSize,
    required String ruleset,
    required double komi,
    required String sgf,
  }) async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    final GameRecord record = GameRecord(
      id: id,
      source: 'master',
      title: title,
      boardSize: boardSize,
      ruleset: ruleset,
      komi: komi,
      sgf: sgf,
      status: 'ready',
      sessionJson: '{}',
      winrateJson: '{}',
      createdAtMs: now,
      updatedAtMs: now,
    );
    await upsert(record);
  }

  Future<void> saveOrUpdateSourceRecord({
    String? id,
    required String source,
    required String title,
    required int boardSize,
    required String ruleset,
    required double komi,
    required String sgf,
    String status = 'ready',
    String sessionJson = '{}',
    String winrateJson = '{}',
  }) async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    final String recordId = id ?? newId(prefix: source);
    final GameRecord record = GameRecord(
      id: recordId,
      source: source,
      title: title,
      boardSize: boardSize,
      ruleset: ruleset,
      komi: komi,
      sgf: sgf,
      status: status,
      sessionJson: sessionJson,
      winrateJson: winrateJson,
      createdAtMs: now,
      updatedAtMs: now,
    );
    await upsert(record);
  }
}
