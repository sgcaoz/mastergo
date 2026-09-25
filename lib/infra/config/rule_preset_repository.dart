import 'package:mastergo/domain/entities/rule_presets.dart';
import 'package:mastergo/infra/config/json_asset_loader.dart';

class RulePresetRepository {
  RulePresetRepository({JsonAssetLoader? loader})
    : _loader = loader ?? const JsonAssetLoader();

  static const String assetPath = 'assets/config/rule_presets.json';

  final JsonAssetLoader _loader;

  Future<List<RulePreset>> loadPresets() async {
    final Map<String, dynamic> data = await _loader.loadMap(assetPath);
    return RulePresetCatalog.parseDocument(data);
  }
}
