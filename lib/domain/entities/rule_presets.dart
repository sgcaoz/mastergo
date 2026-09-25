import 'package:mastergo/domain/entities/game_rules.dart';

class RulePreset {
  const RulePreset({
    required this.id,
    required this.label,
    required this.defaultKomi,
    required this.scoringRule,
    required this.koRule,
    this.whiteHandicapBonusMode = 'N',
    this.supportsAiPlay = true,
  });

  final String id;
  final String label;
  final double defaultKomi;
  final ScoringRule scoringRule;
  final KoRule koRule;
  final String whiteHandicapBonusMode;
  final bool supportsAiPlay;

  GameRules toGameRules({double? komi}) {
    return GameRules(
      ruleset: id,
      komi: komi ?? defaultKomi,
      scoringRule: scoringRule,
      koRule: koRule,
      whiteHandicapBonusMode: whiteHandicapBonusMode,
    );
  }

  factory RulePreset.fromJson(Map<String, dynamic> json) {
    final String id = (json['id'] as String? ?? json['ruleset'] as String? ?? '')
        .trim();
    if (id.isEmpty) {
      throw const FormatException('Rule preset is missing id');
    }
    return RulePreset(
      id: id,
      label: (json['label'] as String? ?? json['name'] as String? ?? id).trim(),
      defaultKomi: (json['defaultKomi'] as num? ?? json['komi'] as num? ?? 7.5)
          .toDouble(),
      scoringRule: _scoringRuleFromString(
        json['scoringRule'] as String? ?? 'area',
      ),
      koRule: _koRuleFromString(json['koRule'] as String? ?? 'simple'),
      whiteHandicapBonusMode:
          json['whiteHandicapBonusMode'] as String? ?? 'N',
      supportsAiPlay: json['supportsAiPlay'] as bool? ?? true,
    );
  }
}

ScoringRule _scoringRuleFromString(String raw) {
  switch (raw.trim().toLowerCase()) {
    case 'territory':
      return ScoringRule.territory;
    default:
      return ScoringRule.area;
  }
}

KoRule _koRuleFromString(String raw) {
  switch (raw.trim().toLowerCase()) {
    case 'positionalsuperko':
    case 'positional_superko':
      return KoRule.positionalSuperko;
    case 'situationalsuperko':
    case 'situational_superko':
      return KoRule.situationalSuperko;
    default:
      return KoRule.simple;
  }
}

/// Compiled fallback so tools and tests work before assets are loaded.
const List<RulePreset> _kFallbackRulePresets = <RulePreset>[
  RulePreset(
    id: 'chinese',
    label: '中国规则',
    defaultKomi: 7.5,
    scoringRule: ScoringRule.area,
    koRule: KoRule.situationalSuperko,
  ),
  RulePreset(
    id: 'japanese',
    label: '日本规则',
    defaultKomi: 6.5,
    scoringRule: ScoringRule.territory,
    koRule: KoRule.simple,
  ),
  RulePreset(
    id: 'korean',
    label: '韩国规则',
    defaultKomi: 6.5,
    scoringRule: ScoringRule.territory,
    koRule: KoRule.simple,
  ),
  RulePreset(
    id: 'classical',
    label: '古谱规则（不贴目）',
    defaultKomi: 0,
    scoringRule: ScoringRule.territory,
    koRule: KoRule.simple,
    supportsAiPlay: false,
  ),
];

class RulePresetCatalog {
  RulePresetCatalog._();

  static List<RulePreset> _presets = List<RulePreset>.from(
    _kFallbackRulePresets,
  );

  static List<RulePreset> get presets => _presets;

  static List<RulePreset> parseDocument(Map<String, dynamic> data) {
    final Object? raw = data['presets'];
    if (raw is! List) {
      return const <RulePreset>[];
    }
    final Map<String, RulePreset> byId = <String, RulePreset>{};
    for (final Object? item in raw) {
      if (item is! Map) {
        continue;
      }
      try {
        final RulePreset preset = RulePreset.fromJson(
          Map<String, dynamic>.from(item),
        );
        byId[preset.id] = preset;
      } catch (_) {
        // Skip malformed entries; keep fallback for those ids.
      }
    }
    return byId.values.toList(growable: false);
  }

  static void applyPresets(List<RulePreset> presets) {
    if (presets.isEmpty) {
      return;
    }
    _presets = List<RulePreset>.from(presets);
  }

  static void applyDocument(Map<String, dynamic> data) {
    final List<RulePreset> parsed = parseDocument(data);
    if (parsed.isEmpty) {
      return;
    }
    _presets = parsed;
  }

  static void resetToFallback() {
    _presets = List<RulePreset>.from(_kFallbackRulePresets);
  }
}

List<RulePreset> get kRulePresets => RulePresetCatalog.presets;

RulePreset rulePresetFromString(String raw) {
  final String v = raw.trim().toLowerCase();
  final List<RulePreset> presets = kRulePresets;
  if (presets.isEmpty) {
    return _kFallbackRulePresets.first;
  }
  if (v.isEmpty) {
    return presets.first;
  }
  for (final RulePreset p in presets) {
    if (p.id.toLowerCase() == v) {
      return p;
    }
  }
  bool matches(String id) =>
      presets.any((RulePreset p) => p.id.toLowerCase() == id);
  RulePreset byId(String id) =>
      presets.firstWhere((RulePreset p) => p.id.toLowerCase() == id);

  if (v.contains('japanese') || v.contains('japan')) {
    if (matches('japanese')) {
      return byId('japanese');
    }
  }
  if (v.contains('korean') || v.contains('korea')) {
    if (matches('korean')) {
      return byId('korean');
    }
  }
  if (v.contains('classical') || v.contains('ancient')) {
    if (matches('classical')) {
      return byId('classical');
    }
  }
  if (v.contains('chinese') || v.contains('china')) {
    if (matches('chinese')) {
      return byId('chinese');
    }
  }
  return presets.first;
}
