import 'package:mastergo/domain/entities/katago_model.dart';
import 'package:mastergo/infra/config/json_asset_loader.dart';

class KatagoModelRepository {
  KatagoModelRepository({JsonAssetLoader? loader})
    : _loader = loader ?? const JsonAssetLoader();

  static const String _assetPath = 'assets/config/katago_models.json';

  final JsonAssetLoader _loader;

  Future<KatagoModel> loadDefaultModel() async {
    final Map<String, dynamic> data = await _loader.loadMap(_assetPath);
    final String defaultId = data['defaultModelId'] as String;
    final List<dynamic> items = data['models'] as List<dynamic>? ?? <dynamic>[];

    final List<KatagoModel> models = items
        .map(
          (dynamic item) => KatagoModel.fromJson(item as Map<String, dynamic>),
        )
        .toList();

    return models.firstWhere(
      (KatagoModel model) => model.id == defaultId,
      orElse: () =>
          throw StateError('Default KataGo model id not found: $defaultId'),
    );
  }
}
