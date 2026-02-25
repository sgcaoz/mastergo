// 将 tool/master_winrate_temp/ 下已跑过的名局胜率 JSON 写回 seed 库，不重跑 KataGo。
// 运行：dart run tool/import_master_winrate_from_temp.dart（项目根目录）
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

void main() {
  final String projectRoot = Directory.current.path;
  final String tempDirPath = p.join(projectRoot, 'tool', 'master_winrate_temp');
  final String seedPath = p.join(projectRoot, 'assets', 'master_games', 'mastergo_seed.db');

  final Directory tempDir = Directory(tempDirPath);
  if (!tempDir.existsSync()) {
    print('ERROR: temp dir not found: $tempDirPath');
    exit(1);
  }
  final File seedFile = File(seedPath);
  if (!seedFile.existsSync()) {
    print('ERROR: seed DB not found: $seedPath');
    exit(1);
  }

  final List<FileSystemEntity> files = tempDir
      .listSync()
      .where((e) => e is File && e.path.endsWith('.json'))
      .where((e) => p.basename(e.path).startsWith('master-'))
      .toList();

  if (files.isEmpty) {
    print('No master-*.json files in $tempDirPath');
    exit(0);
  }

  final Database db = sqlite3.open(seedPath);
  final int now = DateTime.now().millisecondsSinceEpoch;
  int updated = 0;
  int skipped = 0;

  for (final FileSystemEntity e in files) {
    final String path = (e as File).path;
    final String id = p.basenameWithoutExtension(path);
    String content;
    try {
      content = File(path).readAsStringSync();
    } catch (err) {
      print('Skip $id: read error $err');
      skipped++;
      continue;
    }
    final Map<String, dynamic>? decoded = jsonDecode(content) as Map<String, dynamic>?;
    if (decoded == null || decoded.isEmpty) {
      print('Skip $id: empty or invalid JSON');
      skipped++;
      continue;
    }
    final String winrateJson = jsonEncode(decoded);
    try {
      db.execute(
        'UPDATE game_records SET winrateJson = ?, updatedAtMs = ? WHERE id = ?',
        [winrateJson, now, id],
      );
      if (db.getUpdatedRowsCount() > 0) {
        updated++;
        print('OK $id (${decoded.length} turns)');
      } else {
        print('Skip $id: no row in DB');
        skipped++;
      }
    } catch (err) {
      print('Skip $id: $err');
      skipped++;
    }
  }

  db.dispose();
  print('');
  print('Done: $updated updated, $skipped skipped.');
  print('Seed: $seedPath');
}
