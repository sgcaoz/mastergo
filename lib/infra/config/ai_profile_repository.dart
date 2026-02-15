import 'package:mastergo/domain/entities/analysis_profile.dart';
import 'package:mastergo/infra/config/json_asset_loader.dart';

class AIProfileRepository {
  AIProfileRepository({JsonAssetLoader? loader})
    : _loader = loader ?? const JsonAssetLoader();

  static const String _assetPath = 'assets/config/ai_profiles.json';

  final JsonAssetLoader _loader;

  Future<List<AnalysisProfile>> loadProfiles() async {
    final Map<String, dynamic> data = await _loader.loadMap(_assetPath);
    final List<dynamic> items =
        data['profiles'] as List<dynamic>? ?? <dynamic>[];
    return items
        .map(
          (dynamic item) =>
              AnalysisProfile.fromJson(item as Map<String, dynamic>),
        )
        .toList();
  }
}
