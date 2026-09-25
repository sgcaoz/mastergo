import 'package:flutter_test/flutter_test.dart';
import 'package:mastergo/infra/sound/game_audio.dart';

void main() {
  test('stone, bowl, and music are separate assets and switches', () {
    expect(GameAudio.stoneAsset, 'sounds/stone.mp3');
    expect(GameAudio.bowlAsset, 'sounds/capture.mp3');
    expect(GameAudio.ambientAsset, 'sounds/play_ambient.mp3');
    expect(GameAudio.stoneMutePreferenceKey, 'play_stone_muted');
    expect(GameAudio.musicMutePreferenceKey, 'play_music_muted');
    expect(GameAudio.legacyMutePreferenceKey, 'play_audio_muted');
  });
}
