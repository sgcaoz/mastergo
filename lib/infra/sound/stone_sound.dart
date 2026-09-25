import 'package:mastergo/domain/go/go_game.dart';
import 'package:mastergo/infra/sound/game_audio.dart';

/// 落子声。提子时再接一声收进棋盒。落子音静音时两者都不响。
void playMoveSounds(GoGameState before, GoGameState after) {
  final int beforeCaptures = before.blackCaptures + before.whiteCaptures;
  final int afterCaptures = after.blackCaptures + after.whiteCaptures;
  GameAudio.instance.playStone(withBowl: afterCaptures > beforeCaptures);
}
