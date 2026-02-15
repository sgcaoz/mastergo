class KatagoModel {
  const KatagoModel({
    required this.id,
    required this.name,
    required this.engineFamily,
    required this.tier,
    required this.assetPath,
    required this.networkName,
    required this.sourceUrl,
    required this.sha256,
    this.notes,
  });

  final String id;
  final String name;
  final String engineFamily;
  final String tier;
  final String assetPath;
  final String networkName;
  final String sourceUrl;
  final String sha256;
  final String? notes;

  factory KatagoModel.fromJson(Map<String, dynamic> json) {
    return KatagoModel(
      id: json['id'] as String,
      name: json['name'] as String,
      engineFamily: json['engineFamily'] as String,
      tier: json['tier'] as String,
      assetPath: json['assetPath'] as String,
      networkName: json['networkName'] as String,
      sourceUrl: json['sourceUrl'] as String,
      sha256: json['sha256'] as String,
      notes: json['notes'] as String?,
    );
  }
}
