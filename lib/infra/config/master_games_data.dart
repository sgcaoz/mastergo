import 'dart:convert';
import 'dart:io';

import 'package:mastergo/domain/entities/master_game_meta.dart';
import 'package:path/path.dart' as p;

/// 名局目录：构建期灌库与校验工具读取。运行时 App 从 SQLite 读，不依赖此列表。
const String kMasterGamesCatalogAsset = 'assets/config/master_games.json';

List<MasterGameMeta> loadMasterGamesCatalog({String? projectRoot}) {
  final String root = projectRoot ?? Directory.current.path;
  final File file = File(p.join(root, kMasterGamesCatalogAsset));
  final Map<String, dynamic> data =
      jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  final List<dynamic> items = data['games'] as List<dynamic>? ?? <dynamic>[];
  return items
      .map(
        (dynamic item) => MasterGameMeta.fromJson(item as Map<String, dynamic>),
      )
      .toList();
}

List<MasterGameMeta> get masterGamesList => loadMasterGamesCatalog();
