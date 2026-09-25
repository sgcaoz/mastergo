import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:crypto/crypto.dart';
import 'package:mastergo/domain/entities/game_record.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
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
    // 只在本机还没有库时复制种子。已有库绝不覆盖，避免清掉对局和导入的棋谱。
    if (!await file.exists()) {
      try {
        final ByteData data = await rootBundle.load(_seedAssetPath);
        final Uint8List bytes = data.buffer.asUint8List();
        if (bytes.isNotEmpty) {
          await file.writeAsBytes(bytes, flush: true);
        }
      } catch (_) {
        // 种子缺失时仍打开空库，否则整份棋谱都读不出来。
      }
    }
    _db = await openDatabase(
      path,
      version: 3,
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
            sgfHash TEXT,
            createdAtMs INTEGER NOT NULL,
            updatedAtMs INTEGER NOT NULL
          )
        ''');
        await db.execute(
          'CREATE INDEX idx_records_source_updated ON $_table(source, updatedAtMs DESC)',
        );
        await db.execute(
          'CREATE INDEX idx_records_source_sgfHash ON $_table(source, sgfHash)',
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
                sgfHash TEXT,
                createdAtMs INTEGER NOT NULL,
                updatedAtMs INTEGER NOT NULL
              )
            ''');
            await db.execute(
              'CREATE INDEX idx_records_source_updated ON $_table(source, updatedAtMs DESC)',
            );
            await db.execute(
              'CREATE INDEX idx_records_source_sgfHash ON $_table(source, sgfHash)',
            );
          }
        }
        if (oldVersion < 2 && newVersion >= 2) {
          // 修正历史 seed 中少量名局的规则/贴目硬编码错误，避免分析偏差。
          const List<(String, String, double)> fixes =
              <(String, String, double)>[
                ('master-alphago_master_kejie_2017', 'chinese', 6.5),
                ('master-alphago_master_guli_2017', 'chinese', 6.5),
                ('master-alphago_master_park_2017', 'chinese', 6.5),
                ('master-alphago_master_nieweiping_2017', 'chinese', 6.5),
                ('master-alphago_master_iyama_2017', 'chinese', 6.5),
                ('master-alphago_master_miyuting_2017', 'chinese', 6.5),
                ('master-alphago_master_changhao_2017', 'chinese', 6.5),
                ('master-samsung10_luo_choi_g3', 'chinese', 6.5),
                ('master-samsung10_luo_lee_g1', 'chinese', 6.5),
                ('master-samsung10_luo_lee_g2', 'chinese', 6.5),
                ('master-samsung10_luo_lee_g3', 'chinese', 6.5),
                ('master-nie_xiaolin_tengen_1985', 'japanese', 5.5),
                ('master-nie_jiato_tengen_1985', 'japanese', 5.5),
                ('master-nie_fujisawa_tengen_1985', 'chinese', 5.5),
              ];
          for (final (String id, String ruleset, double komi) in fixes) {
            await db.update(
              _table,
              <String, Object?>{'ruleset': ruleset, 'komi': komi},
              where: 'id = ? AND source = ?',
              whereArgs: <Object?>[id, 'master'],
            );
          }
        }
        if (oldVersion < 3 && newVersion >= 3) {
          // 列已经加上但版本号没写上时，再 ALTER 会让整库打不开，列表就变成空的。
          if (!await _columnExists(db, 'sgfHash')) {
            await db.execute('ALTER TABLE $_table ADD COLUMN sgfHash TEXT');
          }
          await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_records_source_sgfHash ON $_table(source, sgfHash)',
          );
          final List<Map<String, Object?>> rows = await db.query(
            _table,
            columns: <String>['id', 'sgf'],
          );
          final Batch batch = db.batch();
          for (final Map<String, Object?> row in rows) {
            final String id = sqliteText(row['id']);
            final String sgf = sqliteText(row['sgf']);
            if (id.isEmpty || sgf.trim().isEmpty) {
              continue;
            }
            batch.update(
              _table,
              <String, Object?>{'sgfHash': _hashSgf(sgf)},
              where: 'id = ?',
              whereArgs: <Object?>[id],
            );
          }
          await batch.commit(noResult: true);
        }
      },
    );
    await _syncBundledMasterLibrary(_db!);
    return _db!;
  }

  static const String _seedVersionPrefKey = 'master_seed_version';
  static const String _seedMetaAssetPath =
      'assets/config/master_seed_meta.json';

  Future<void> _syncBundledMasterLibrary(Database db) async {
    try {
      final String raw = await rootBundle.loadString(_seedMetaAssetPath);
      final Object decoded = jsonDecode(raw);
      final int bundledVersion = decoded is Map<String, dynamic>
          ? (decoded['version'] as num?)?.toInt() ?? 0
          : 0;
      if (bundledVersion <= 0) {
        return;
      }
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final int localVersion = prefs.getInt(_seedVersionPrefKey) ?? 0;
      if (localVersion >= bundledVersion) {
        final int masterCount =
            Sqflite.firstIntValue(
              await db.rawQuery(
                'SELECT COUNT(*) FROM $_table WHERE source = ?',
                <Object?>['master'],
              ),
            ) ??
            0;
        // 版本号写上了但名局是空的时，再补一次，不清本机对局。
        if (masterCount > 0) {
          return;
        }
      }
      final String base = await getDatabasesPath();
      final String seedCopyPath = p.join(base, 'mastergo_seed_bundle.db');
      final ByteData data = await rootBundle.load(_seedAssetPath);
      await File(
        seedCopyPath,
      ).writeAsBytes(data.buffer.asUint8List(), flush: true);
      final Database seedDb = await _openSeedCopy(seedCopyPath);
      int failed = 0;
      int imported = 0;
      try {
        final List<Map<String, Object?>> rows = await seedDb.query(
          _table,
          where: 'source = ?',
          whereArgs: <Object?>['master'],
        );
        for (final Map<String, Object?> row in rows) {
          try {
            await _upsertMasterLibraryRow(db, row);
            imported++;
          } catch (_) {
            failed++;
          }
        }
      } finally {
        await seedDb.close();
      }
      if (failed == 0 && imported > 0) {
        await prefs.setInt(_seedVersionPrefKey, bundledVersion);
      }
    } catch (_) {
      // 名局库同步失败不影响本机对局；下次启动再试。
    }
  }

  Future<void> _upsertMasterLibraryRow(
    Database db,
    Map<String, Object?> seedRow,
  ) async {
    final String id = sqliteText(seedRow['id']);
    if (id.isEmpty) {
      return;
    }
    final List<Map<String, Object?>> existing = await db.query(
      _table,
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    if (existing.isEmpty) {
      final Map<String, Object?> row = Map<String, Object?>.from(seedRow);
      row['sgf'] = sqliteText(row['sgf']);
      row['sessionJson'] = sqliteText(row['sessionJson'], '{}');
      row['winrateJson'] = sqliteText(row['winrateJson'], '{}');
      await db.insert(_table, row);
      return;
    }
    final GameRecord current = GameRecord.fromMap(existing.first);
    final Map<String, dynamic> session = _decodeJsonMap(current.sessionJson);
    final Map<String, dynamic> seedSession = _decodeJsonMap(
      sqliteText(seedRow['sessionJson'], '{}'),
    );
    for (final String key in <String>[
      'players',
      'event',
      'year',
      'category',
      'tags',
    ]) {
      if (seedSession.containsKey(key)) {
        session[key] = seedSession[key];
      }
    }
    final Map<String, Object?> patch = <String, Object?>{
      'title': seedRow['title'],
      'boardSize': seedRow['boardSize'],
      'ruleset': seedRow['ruleset'],
      'komi': seedRow['komi'],
      'sessionJson': jsonEncode(session),
      'updatedAtMs': DateTime.now().millisecondsSinceEpoch,
    };
    final String seedSgf = sqliteText(seedRow['sgf']);
    if (seedSgf.isNotEmpty && seedSgf != current.sgf) {
      patch['sgf'] = seedSgf;
      patch['sgfHash'] = _hashSgf(seedSgf);
    }
    final String seedWinrate = sqliteText(seedRow['winrateJson'], '{}');
    if (storedWinrateJsonHasMoves(seedWinrate)) {
      patch['winrateJson'] = seedWinrate;
    }
    await db.update(_table, patch, where: 'id = ?', whereArgs: <Object?>[id]);
  }

  Map<String, dynamic> _decodeJsonMap(String raw) {
    try {
      final Object decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return Map<String, dynamic>.from(decoded);
      }
    } catch (_) {}
    return <String, dynamic>{};
  }

  String newId({String prefix = 'rec'}) {
    final int now = DateTime.now().millisecondsSinceEpoch;
    final int salt = Random().nextInt(1 << 20);
    return '$prefix-$now-$salt';
  }

  Future<void> upsert(GameRecord record) async {
    final Database db = await _database();
    final Map<String, Object?> row = record.toMap();
    row['sgfHash'] = _hashSgf(record.sgf);
    await db.insert(_table, row, conflictAlgorithm: ConflictAlgorithm.replace);
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
    int limit = 500,
  }) async {
    final Database db = await _database();
    final List<Map<String, Object?>> rows = await db.query(
      _table,
      where: 'source = ?',
      whereArgs: <Object?>[source],
      orderBy: 'updatedAtMs DESC',
      limit: limit,
    );
    final List<GameRecord> records = <GameRecord>[];
    for (final Map<String, Object?> row in rows) {
      try {
        final GameRecord record = GameRecord.fromMap(row);
        if (record.id.isEmpty) {
          continue;
        }
        records.add(record);
      } catch (_) {
        // 一条坏记录不能把整份棋谱列表变成空的。
      }
    }
    return records;
  }

  Future<bool> _columnExists(Database db, String name) async {
    final List<Map<String, Object?>> columns = await db.rawQuery(
      'PRAGMA table_info($_table)',
    );
    for (final Map<String, Object?> column in columns) {
      if (column['name'] == name) {
        return true;
      }
    }
    return false;
  }

  /// 种子库单独打开，不走版本升级，避免误删或改到本机对局库。
  Future<Database> _openSeedCopy(String path) async {
    try {
      return await openDatabase(path, readOnly: true, singleInstance: false);
    } catch (_) {
      return openDatabase(path, singleInstance: false);
    }
  }

  /// 在第三方棋谱记录中查找 SGF 内容相同的记录，用于去重（同棋谱只保留一条，更新而非新增）。
  /// 兼容历史：优先 download，同时纳入 legacy import。
  Future<GameRecord?> findImportBySgfContent(String sgfContent) async {
    final String normalized = sgfContent.trim();
    if (normalized.isEmpty) return null;
    final Database db = await _database();
    final String hash = _hashSgf(normalized);
    final List<Map<String, Object?>> rows = await db.query(
      _table,
      where: 'source IN (?, ?) AND sgfHash = ?',
      whereArgs: <Object?>['download', 'import', hash],
      orderBy: 'updatedAtMs DESC',
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    return GameRecord.fromMap(rows.first);
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

  String _hashSgf(String sgf) {
    final String normalized = sgf.trim();
    return sha256.convert(utf8.encode(normalized)).toString();
  }
}
