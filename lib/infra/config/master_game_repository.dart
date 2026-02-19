import 'package:flutter/services.dart';
import 'package:mastergo/domain/entities/master_game_meta.dart';
import 'package:mastergo/infra/config/master_games_data.dart';

class MasterGameRepository {
  MasterGameRepository();

  /// 名局元数据列表（Dart 定义），仅用于一次性灌库时读取 SGF 并写入数据库。
  Future<List<MasterGameMeta>> loadIndex() async {
    return Future.value(masterGamesList);
  }

  Future<String> loadSgfContent(String assetPath) {
    return rootBundle.loadString(assetPath);
  }
}
