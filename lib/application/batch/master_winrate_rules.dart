import 'package:mastergo/domain/entities/rule_presets.dart';

/// Rules actually sent to KataGo for a master-game winrate batch.
class MasterWinrateEngineRules {
  const MasterWinrateEngineRules({
    required this.presetId,
    required this.kataGoRules,
    required this.komi,
    required this.category,
    required this.ancient,
  });

  /// App preset id stored on the record (`chinese` / `japanese` / `korean` / `classical`).
  final String presetId;

  /// Name KataGo's analysis engine accepts.
  final String kataGoRules;
  final double komi;
  final String category;
  final bool ancient;
}

/// Resolve engine rules from the seed row, not from SGF KM/RU.
/// Ancient games (`classical`, komi 0) must not fall back to Chinese 7.5.
MasterWinrateEngineRules resolveMasterWinrateRules({
  required String dbRuleset,
  required double dbKomi,
  String category = '',
}) {
  final String cat = category.trim();
  final bool ancient = cat == 'ancient';
  final RulePreset preset = rulePresetFromString(
    dbRuleset.trim().isEmpty && ancient ? 'classical' : dbRuleset,
  );
  final String kataGoRules = switch (preset.id) {
    'classical' => 'japanese',
    'japanese' => 'japanese',
    'korean' => 'korean',
    _ => 'chinese',
  };
  return MasterWinrateEngineRules(
    presetId: preset.id,
    kataGoRules: kataGoRules,
    komi: dbKomi,
    category: cat,
    ancient: ancient || preset.id == 'classical',
  );
}

bool winrateTurnsComplete(Map<int, double> winrates, int totalMoves) {
  if (totalMoves < 0) {
    return false;
  }
  for (int turn = 1; turn <= totalMoves; turn++) {
    if (!winrates.containsKey(turn)) {
      return false;
    }
  }
  return true;
}

int nextMissingTurn(Map<int, double> winrates, int totalMoves) {
  for (int turn = 0; turn <= totalMoves; turn++) {
    if (!winrates.containsKey(turn)) {
      return turn;
    }
  }
  return totalMoves + 1;
}
