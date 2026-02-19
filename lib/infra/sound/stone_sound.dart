import 'package:audioplayers/audioplayers.dart';

/// 落子音效。需在 assets/sounds/ 下放置 stone.mp3（短促的点击或木子声），缺失时静默忽略。
void playStoneSound() {
  try {
    final AudioPlayer player = AudioPlayer();
    player.setReleaseMode(ReleaseMode.release);
    player.play(AssetSource('sounds/stone.mp3')).catchError((Object _) {
      player.dispose();
    });
    player.onPlayerComplete.listen((_) {
      player.dispose();
    });
  } catch (_) {}
}
