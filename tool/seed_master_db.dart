// 构建时执行一次：将名局 SGF 灌入 SQLite，产出 assets/master_games/mastergo_seed.db
// 运行：dart run tool/seed_master_db.dart（在项目根目录）
import 'dart:convert';
import 'dart:io';

import 'package:mastergo/domain/entities/master_game_meta.dart';
import 'package:mastergo/infra/config/master_games_data.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

void main() {
  final String projectRoot = p.current;
  final String outPath = p.join(projectRoot, 'assets', 'master_games', 'mastergo_seed.db');
  final File outFile = File(outPath);
  if (outFile.existsSync()) outFile.deleteSync();

  final Database db = sqlite3.open(outPath);

  db.execute('''
    CREATE TABLE game_records(
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
  db.execute(
    'CREATE INDEX idx_records_source_updated ON game_records(source, updatedAtMs DESC)',
  );

  final int now = DateTime.now().millisecondsSinceEpoch;
  final List<MasterGameMeta> list = masterGamesList;

  for (final MasterGameMeta meta in list) {
    final String sgfPath = p.join(projectRoot, meta.sgfAssetPath);
    final String sgf = File(sgfPath).readAsStringSync();
    final String sessionJson = jsonEncode(<String, dynamic>{
      'players': meta.players,
      'event': meta.event,
      'year': meta.year,
    });
    final String id = 'master-${meta.id}';

    final stmt = db.prepare('''
      INSERT INTO game_records(
        id, source, title, boardSize, ruleset, komi, sgf,
        status, sessionJson, winrateJson, createdAtMs, updatedAtMs
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ''');
    stmt.execute([
      id,
      'master',
      meta.title,
      meta.boardSize,
      meta.ruleset,
      meta.komi,
      sgf,
      'ready',
      sessionJson,
      '{}',
      now,
      now,
    ]);
    stmt.dispose();
  }

  // 与 App 端 openDatabase(version: 1) 一致，避免复制后打开时误触 onCreate 导致 "table already exists"
  db.execute('PRAGMA user_version = 1');

  db.dispose();
  print('Generated $outPath with ${list.length} master games.');
}
