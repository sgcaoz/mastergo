import 'package:flutter_test/flutter_test.dart';
import 'package:mastergo/application/analysis/game_analysis_service.dart';
import 'package:mastergo/domain/entities/analysis_profile.dart';
import 'package:mastergo/domain/entities/rule_presets.dart';
import 'package:mastergo/domain/go/go_types.dart';
import 'package:mastergo/infra/engine/katago/katago_adapter.dart';

void main() {
  const GameAnalysisService service = GameAnalysisService();

  test('buildHints marks a large drop as a blunder', () {
    final List<MoveHint> hints = service.buildHints(
      <int, double>{0: 0.55, 1: 0.20},
      playerStone: GoStone.black,
    );
    expect(hints.where((MoveHint h) => h.kind == HintKind.blunder), isNotEmpty);
        expect(hints.first.turn, 1);
  });

  test('worstBlunder picks the largest winrate drop', () {
    const List<MoveHint> hints = <MoveHint>[
      MoveHint(turn: 8, deltaPlayerWinrate: -0.12, kind: HintKind.blunder),
      MoveHint(turn: 40, deltaPlayerWinrate: -0.31, kind: HintKind.blunder),
      MoveHint(turn: 12, deltaPlayerWinrate: 0.08, kind: HintKind.brilliant),
    ];
    expect(GameAnalysisService.worstBlunder(hints)?.turn, 40);
    expect(GameAnalysisService.worstBlunder(const <MoveHint>[]), isNull);
  });

  test('analyzeTurns with mock adapter fills every requested turn', () async {
    const AnalysisProfile profile = AnalysisProfile(
      id: 't',
      name: 't',
      description: 't',
      maxVisits: 2,
      thinkingTimeMs: 10,
      includeOwnership: false,
    );
    final Map<int, double> winrates = await service.analyzeTurns(
      adapter: MockKatagoAdapter(),
      moveTokens: <String>['B:D4', 'W:Q16', 'B:D16'],
      boardSize: 19,
      ruleset: 'chinese',
      komi: 7.5,
      profile: profile,
    );
    expect(winrates.keys, containsAll(<int>[0, 1, 2, 3]));
  });

  test('rule catalog parses JSON ids without hardcoded indexes', () {
    RulePresetCatalog.applyDocument(<String, dynamic>{
      'presets': <Map<String, Object>>[
        <String, Object>{
          'id': 'chinese',
          'label': 'CN',
          'defaultKomi': 7.5,
          'scoringRule': 'area',
          'koRule': 'situationalSuperko',
          'supportsAiPlay': true,
        },
        <String, Object>{
          'id': 'japanese',
          'label': 'JP',
          'defaultKomi': 6.5,
          'scoringRule': 'territory',
          'koRule': 'simple',
          'supportsAiPlay': true,
        },
      ],
    });
    expect(rulePresetFromString('Japanese').id, 'japanese');
    expect(rulePresetFromString('chinese').defaultKomi, 7.5);
    RulePresetCatalog.resetToFallback();
  });
}
