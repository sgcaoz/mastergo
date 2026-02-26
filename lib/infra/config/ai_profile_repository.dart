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
    final Map<String, AnalysisProfile> profilesById =
        <String, AnalysisProfile>{};
    for (final dynamic item in items) {
      final AnalysisProfile profile = AnalysisProfile.fromJson(
        item as Map<String, dynamic>,
      );
      final String normalizedId = profile.id.trim();
      if (normalizedId.isEmpty) {
        continue;
      }
      // Keep the latest entry when duplicated ids exist in config.
      profilesById[normalizedId] = AnalysisProfile(
        id: normalizedId,
        name: profile.name.trim(),
        description: profile.description.trim(),
        maxVisits: profile.maxVisits,
        thinkingTimeMs: profile.thinkingTimeMs,
        includeOwnership: profile.includeOwnership,
      );
    }
    return profilesById.values.toList();
  }
}
