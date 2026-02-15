class AnalysisProfile {
  const AnalysisProfile({
    required this.id,
    required this.name,
    required this.description,
    required this.maxVisits,
    required this.thinkingTimeMs,
    required this.includeOwnership,
  });

  final String id;
  final String name;
  final String description;
  final int maxVisits;
  final int thinkingTimeMs;
  final bool includeOwnership;

  factory AnalysisProfile.fromJson(Map<String, dynamic> json) {
    return AnalysisProfile(
      id: json['id'] as String,
      name: json['name'] as String,
      description: json['description'] as String,
      maxVisits: json['maxVisits'] as int,
      thinkingTimeMs: json['thinkingTimeMs'] as int,
      includeOwnership: json['includeOwnership'] as bool? ?? false,
    );
  }
}
