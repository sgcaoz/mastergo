import 'package:flutter/services.dart';
import 'package:mastergo/domain/entities/master_game_meta.dart';
import 'package:mastergo/infra/config/json_asset_loader.dart';

class MasterGameRepository {
  MasterGameRepository({JsonAssetLoader? loader})
    : _loader = loader ?? const JsonAssetLoader();

  static const String _indexAssetPath = 'assets/master_games/index.json';

  final JsonAssetLoader _loader;

  Future<List<MasterGameMeta>> loadIndex() async {
    final Map<String, dynamic> data = await _loader.loadMap(_indexAssetPath);
    final List<dynamic> items = data['games'] as List<dynamic>? ?? <dynamic>[];
    return items
        .map(
          (dynamic item) =>
              MasterGameMeta.fromJson(item as Map<String, dynamic>),
        )
        .toList();
  }

  Future<String> loadSgfContent(String assetPath) {
    return rootBundle.loadString(assetPath);
  }
}
