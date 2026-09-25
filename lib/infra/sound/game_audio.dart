import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 落子声、提子入盒声、对弈背景音乐。安卓 / iOS 共用，音乐和落子音分开静音。
class GameAudio {
  GameAudio._();

  static final GameAudio instance = GameAudio._();

  static const String legacyMutePreferenceKey = 'play_audio_muted';
  static const String stoneMutePreferenceKey = 'play_stone_muted';
  static const String musicMutePreferenceKey = 'play_music_muted';
  static const String stoneAsset = 'sounds/stone.mp3';
  static const String bowlAsset = 'sounds/capture.mp3';
  static const String ambientAsset = 'sounds/play_ambient.mp3';

  AudioPlayer? _stone;
  AudioPlayer? _bowl;
  AudioPlayer? _music;
  bool _ready = false;
  bool _stoneMuted = false;
  bool _musicMuted = false;
  bool _musicWanted = false;
  int _stoneToken = 0;
  int _bowlToken = 0;
  int _musicToken = 0;

  bool get stoneMuted => _stoneMuted;
  bool get musicMuted => _musicMuted;

  AudioContext get _effectContext => AudioContext(
    android: const AudioContextAndroid(
      audioMode: AndroidAudioMode.normal,
      contentType: AndroidContentType.sonification,
      usageType: AndroidUsageType.game,
      audioFocus: AndroidAudioFocus.none,
    ),
    iOS: AudioContextIOS(
      category: AVAudioSessionCategory.playback,
      options: const <AVAudioSessionOptions>{
        AVAudioSessionOptions.mixWithOthers,
      },
    ),
  );

  AudioContext get _musicContext => AudioContext(
    android: const AudioContextAndroid(
      audioMode: AndroidAudioMode.normal,
      contentType: AndroidContentType.music,
      usageType: AndroidUsageType.game,
      audioFocus: AndroidAudioFocus.gain,
    ),
    iOS: AudioContextIOS(
      category: AVAudioSessionCategory.playback,
      options: const <AVAudioSessionOptions>{
        AVAudioSessionOptions.mixWithOthers,
      },
    ),
  );

  Future<void> ensureReady() async {
    if (_ready) {
      return;
    }
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final bool? stonePref = prefs.getBool(stoneMutePreferenceKey);
    final bool? musicPref = prefs.getBool(musicMutePreferenceKey);
    if (stonePref == null && musicPref == null) {
      final bool legacy = prefs.getBool(legacyMutePreferenceKey) ?? false;
      _stoneMuted = legacy;
      _musicMuted = legacy;
      if (legacy) {
        await prefs.setBool(stoneMutePreferenceKey, true);
        await prefs.setBool(musicMutePreferenceKey, true);
      }
    } else {
      _stoneMuted = stonePref ?? false;
      _musicMuted = musicPref ?? false;
    }

    _stone = AudioPlayer(playerId: 'mastergo-stone');
    _bowl = AudioPlayer(playerId: 'mastergo-bowl');
    _music = AudioPlayer(playerId: 'mastergo-music');
    await _stone!.setAudioContext(_effectContext);
    await _bowl!.setAudioContext(_effectContext);
    await _music!.setAudioContext(_musicContext);
    await _stone!.setPlayerMode(PlayerMode.mediaPlayer);
    await _bowl!.setPlayerMode(PlayerMode.mediaPlayer);
    await _music!.setPlayerMode(PlayerMode.mediaPlayer);
    await _stone!.setReleaseMode(ReleaseMode.stop);
    await _bowl!.setReleaseMode(ReleaseMode.stop);
    await _music!.setReleaseMode(ReleaseMode.loop);
    await _stone!.setVolume(1);
    await _bowl!.setVolume(0.85);
    await _music!.setVolume(0.4);
    _ready = true;
  }

  /// 落子声。提子时约 90ms 后再播一声棋盒，单独播放器，不被下一手落子截断。
  Future<void> playStone({bool withBowl = false}) async {
    try {
      await ensureReady();
      if (_stoneMuted || _stone == null) {
        return;
      }
      final int token = ++_stoneToken;
      await _stone!.stop();
      if (token != _stoneToken || _stoneMuted) {
        return;
      }
      await _stone!.play(AssetSource(stoneAsset));
      if (token != _stoneToken) {
        await _stone!.stop();
        return;
      }
      if (!withBowl || _bowl == null) {
        return;
      }
      final int bowlToken = ++_bowlToken;
      unawaited(
        Future<void>.delayed(const Duration(milliseconds: 90), () async {
          if (bowlToken != _bowlToken || _stoneMuted || _bowl == null) {
            return;
          }
          try {
            await _bowl!.stop();
            if (bowlToken != _bowlToken || _stoneMuted) {
              return;
            }
            await _bowl!.play(AssetSource(bowlAsset));
            if (bowlToken != _bowlToken) {
              await _bowl!.stop();
            }
          } catch (error) {
            debugPrint('playBowl failed: $error');
          }
        }),
      );
    } catch (error) {
      debugPrint('playStone failed: $error');
    }
  }

  Future<void> startPlayMusic() async {
    _musicWanted = true;
    final int token = ++_musicToken;
    try {
      await ensureReady();
      if (token != _musicToken ||
          !_musicWanted ||
          _musicMuted ||
          _music == null) {
        return;
      }
      if (_music!.state == PlayerState.playing) {
        return;
      }
      if (_music!.state == PlayerState.paused) {
        await _music!.resume();
        return;
      }
      await _music!.setReleaseMode(ReleaseMode.loop);
      await _music!.play(AssetSource(ambientAsset));
      if (token != _musicToken) {
        await _music!.stop();
      }
    } catch (error) {
      debugPrint('startPlayMusic failed: $error');
    }
  }

  Future<void> pausePlayMusic() async {
    try {
      await _music?.pause();
    } catch (_) {}
  }

  Future<void> resumePlayMusic() async {
    if (!_musicWanted || _musicMuted) {
      return;
    }
    try {
      await ensureReady();
      if (_music == null) {
        return;
      }
      if (_music!.state == PlayerState.paused) {
        await _music!.resume();
      } else if (_music!.state != PlayerState.playing) {
        await _music!.setReleaseMode(ReleaseMode.loop);
        await _music!.play(AssetSource(ambientAsset));
      }
    } catch (error) {
      debugPrint('resumePlayMusic failed: $error');
    }
  }

  Future<void> stopPlayMusic() async {
    _musicWanted = false;
    _musicToken++;
    try {
      await _music?.stop();
    } catch (_) {}
  }

  /// 离开对局页时停掉音乐、落子声和还没响的提子声。
  Future<void> stopBattleSounds() async {
    _musicWanted = false;
    _musicToken++;
    _stoneToken++;
    _bowlToken++;
    try {
      await _music?.stop();
      await _stone?.stop();
      await _bowl?.stop();
    } catch (_) {}
  }

  Future<void> setStoneMuted(bool muted) async {
    _stoneMuted = muted;
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool(stoneMutePreferenceKey, muted);
    if (muted) {
      _bowlToken++;
      try {
        await _stone?.stop();
        await _bowl?.stop();
      } catch (_) {}
    }
  }

  Future<void> setMusicMuted(bool muted) async {
    _musicMuted = muted;
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool(musicMutePreferenceKey, muted);
    if (muted) {
      await pausePlayMusic();
    } else if (_musicWanted) {
      await resumePlayMusic();
    }
  }
}
