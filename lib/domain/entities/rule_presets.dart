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
}

const List<RulePreset> kRulePresets = <RulePreset>[
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

RulePreset rulePresetFromString(String raw) {
  final String v = raw.trim().toLowerCase();
  if (v.isEmpty) {
    return kRulePresets.first;
  }
  if (v.contains('japanese') || v.contains('japan')) {
    return kRulePresets[1];
  }
  if (v.contains('korean') || v.contains('korea')) {
    return kRulePresets[2];
  }
  if (v.contains('chinese') || v.contains('china')) {
    return kRulePresets.first;
  }
  if (v.contains('classical') || v.contains('ancient')) {
    return kRulePresets[3];
  }
  for (final RulePreset p in kRulePresets) {
    if (p.id == v) {
      return p;
    }
  }
  return kRulePresets.first;
}
