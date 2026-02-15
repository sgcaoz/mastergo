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
