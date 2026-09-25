enum ScoringRule { area, territory }

enum KoRule { simple, positionalSuperko, situationalSuperko }

class GameRules {
  const GameRules({
    required this.ruleset,
    required this.komi,
    required this.scoringRule,
    required this.koRule,
    this.whiteHandicapBonusMode = 'N',
  });

  final String ruleset;
  final double komi;
  final ScoringRule scoringRule;
  final KoRule koRule;
  final String whiteHandicapBonusMode;

  GameRules copyWith({
    String? ruleset,
    double? komi,
    ScoringRule? scoringRule,
    KoRule? koRule,
    String? whiteHandicapBonusMode,
  }) {
    return GameRules(
      ruleset: ruleset ?? this.ruleset,
      komi: komi ?? this.komi,
      scoringRule: scoringRule ?? this.scoringRule,
      koRule: koRule ?? this.koRule,
      whiteHandicapBonusMode:
          whiteHandicapBonusMode ?? this.whiteHandicapBonusMode,
    );
  }
}

/// KataGo 没有古谱这档。古谱按无贴目的日本规则送进去，和已经算好的胜率一致。
String kataGoRulesetName(String ruleset) {
  final String v = ruleset.trim().toLowerCase();
  if (v.isEmpty) {
    return 'chinese';
  }
  if (v == 'classical' || v.contains('ancient') || v.contains('classical')) {
    return 'japanese';
  }
  if (v == 'japanese' || v == 'korean' || v == 'chinese') {
    return v;
  }
  return ruleset.trim();
}
