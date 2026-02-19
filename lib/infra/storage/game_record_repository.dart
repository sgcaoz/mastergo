import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:mastergo/domain/entities/game_record.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// Seed 库路径（由 tool/seed_master_db.dart 构建时生成）。
const String _seedAssetPath = 'assets/master_games/mastergo_seed.db';

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
    final File file = File(path);
    if (!await file.exists()) {
      final ByteData data = await rootBundle.load(_seedAssetPath);
      await file.writeAsBytes(data.buffer.asUint8List());
    }
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
      onUpgrade: (Database db, int oldVersion, int newVersion) async {
        // 从 seed 复制的库可能被识别为 version 0，升级到 1 时不再建表
        if (oldVersion == 0 && newVersion >= 1) {
          final List<Map<String, dynamic>> r = await db.rawQuery(
            "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
            [_table],
          );
          if (r.isEmpty) {
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
          }
        }
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

  Future<List<GameRecord>> listBySource(
    String source, {
    int limit = 200,
  }) async {
    final Database db = await _database();
    final List<Map<String, Object?>> rows = await db.query(
      _table,
      where: 'source = ?',
      whereArgs: <Object?>[source],
      orderBy: 'updatedAtMs DESC',
      limit: limit,
    );
    return rows.map(GameRecord.fromMap).toList();
  }

  /// 在 source='import' 中查找 SGF 内容相同的记录，用于去重（同棋谱只保留一条，更新而非新增）。
  Future<GameRecord?> findImportBySgfContent(String sgfContent) async {
    final String normalized = sgfContent.trim();
    if (normalized.isEmpty) return null;
    final List<GameRecord> list = await listBySource('import', limit: 500);
    for (final GameRecord r in list) {
      if (r.sgf.trim() == normalized) return r;
    }
    return null;
  }

  Future<GameRecord?> loadById(String id) async {
    final Database db = await _database();
    final List<Map<String, Object?>> rows = await db.query(
      _table,
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    return GameRecord.fromMap(rows.first);
  }

  Future<void> deleteById(String id) async {
    final Database db = await _database();
    await db.delete(_table, where: 'id = ?', whereArgs: <Object?>[id]);
  }

  Future<void> deleteByIds(List<String> ids) async {
    if (ids.isEmpty) {
      return;
    }
    final Database db = await _database();
    await db.transaction((Transaction txn) async {
      for (final String id in ids) {
        await txn.delete(_table, where: 'id = ?', whereArgs: <Object?>[id]);
      }
    });
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
