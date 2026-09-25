import 'package:flutter_test/flutter_test.dart';
import 'package:mastergo/application/batch/master_winrate_checkpoint.dart';
import 'package:mastergo/application/batch/master_winrate_rules.dart';
import 'package:mastergo/domain/entities/game_rules.dart';

void main() {
  test('classical is sent to KataGo as japanese so komi 0 still analyzes', () {
    expect(kataGoRulesetName('classical'), 'japanese');
    expect(kataGoRulesetName('chinese'), 'chinese');
    expect(kataGoRulesetName('japanese'), 'japanese');
  });

  test('classical ancient games go to KataGo japanese with stored komi 0', () {
    final MasterWinrateEngineRules rules = resolveMasterWinrateRules(
      dbRuleset: 'classical',
      dbKomi: 0,
      category: 'ancient',
    );
    expect(rules.presetId, 'classical');
    expect(rules.kataGoRules, 'japanese');
    expect(rules.komi, 0);
    expect(rules.ancient, isTrue);
  });

  test('chinese and japanese keep their own komi from the database', () {
    expect(
      resolveMasterWinrateRules(
        dbRuleset: 'chinese',
        dbKomi: 6.5,
        category: 'ai',
      ).komi,
      6.5,
    );
    expect(
      resolveMasterWinrateRules(
        dbRuleset: 'japanese',
        dbKomi: 5.5,
        category: 'classic',
      ).kataGoRules,
      'japanese',
    );
  });

  test('empty ruleset on an ancient game still uses classical', () {
    final MasterWinrateEngineRules rules = resolveMasterWinrateRules(
      dbRuleset: '',
      dbKomi: 0,
      category: 'ancient',
    );
    expect(rules.presetId, 'classical');
    expect(rules.ancient, isTrue);
  });

  test('winrate completeness ignores turn 0 but requires every played move', () {
    expect(winrateTurnsComplete(<int, double>{0: 0.5, 1: 0.4, 2: 0.3}, 2), isTrue);
    expect(winrateTurnsComplete(<int, double>{1: 0.4, 2: 0.3}, 2), isTrue);
    expect(winrateTurnsComplete(<int, double>{0: 0.5, 1: 0.4}, 2), isFalse);
    expect(nextMissingTurn(<int, double>{0: 0.5, 1: 0.4}, 3), 2);
  });

  test('db winrate json uses the main-line nested shape the app already reads', () {
    final String json = winrateJsonForDb(<int, double>{0: 0.5, 1: 0.42, 2: 0.4});
    expect(json, contains('"1":0.42'));
    expect(json.contains('"0"'), isFalse);
  });
}
