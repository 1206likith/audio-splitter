// To enable background audio: call BackgroundAudioService().initialize()
// from HomeScreen.initState() after _audioService.initialize().

import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Registers the app as an audio service so it can run in the background
/// on Android (foreground service) and iOS (background audio mode).
class BackgroundAudioService {
  static final BackgroundAudioService _instance =
      BackgroundAudioService._internal();
  factory BackgroundAudioService() => _instance;
  BackgroundAudioService._internal();

  AudioHandler? _handler;
  bool _initialized = false;

  bool get isInitialized => _initialized;

  void Function()? _onPlay;
  void Function()? _onPause;
  void Function()? _onStop;

  void setMediaButtonCallbacks({
    void Function()? onPlay,
    void Function()? onPause,
    void Function()? onStop,
  }) {
    _onPlay = onPlay;
    _onPause = onPause;
    _onStop = onStop;
  }

  void clearMediaButtonCallbacks() {
    _onPlay = null;
    _onPause = null;
    _onStop = null;
  }

  Future<void> initialize() async {
    if (_initialized || kIsWeb) return;
    try {
      _handler = await AudioService.init(
        builder: () => _AudioSplitterHandler(),
        config: const AudioServiceConfig(
          androidNotificationChannelId: 'com.audiosplitter.app.channel.audio',
          androidNotificationChannelName: 'Audio Splitter',
          androidNotificationOngoing: true,
          notificationColor: Color(0xFF6750A4),
        ),
      );
      _initialized = true;
      debugPrint('BackgroundAudioService initialized');
    } catch (e) {
      debugPrint('BackgroundAudioService init failed: $e');
    }
  }

  Future<void> setPlayingState({required bool playing, String? title}) async {
    if (_handler == null) return;
    try {
      if (playing) {
        await _handler!.play();
        if (title != null) {
          await _handler!.updateMediaItem(MediaItem(
            id: 'audio_stream',
            title: title,
            artist: 'Audio Splitter',
            album: 'Live Stream',
          ));
        }
      } else {
        await _handler!.pause();
      }
    } catch (e) {
      debugPrint('BackgroundAudioService state error: $e');
    }
  }

  Future<void> stop() async {
    if (_handler == null) return;
    try {
      await _handler!.stop();
    } catch (e) {
      debugPrint('BackgroundAudioService stop error: $e');
    }
  }
}

class _AudioSplitterHandler extends BaseAudioHandler {
  @override
  Future<void> play() async {
    playbackState.add(playbackState.value.copyWith(
      playing: true,
      controls: [MediaControl.pause, MediaControl.stop],
      processingState: AudioProcessingState.ready,
      systemActions: const {
        MediaAction.play,
        MediaAction.pause,
        MediaAction.stop
      },
    ));
    BackgroundAudioService()._onPlay?.call();
  }

  @override
  Future<void> pause() async {
    playbackState.add(playbackState.value.copyWith(
      playing: false,
      controls: [MediaControl.play, MediaControl.stop],
      processingState: AudioProcessingState.ready,
      systemActions: const {
        MediaAction.play,
        MediaAction.pause,
        MediaAction.stop
      },
    ));
    BackgroundAudioService()._onPause?.call();
  }

  @override
  Future<void> stop() async {
    playbackState.add(playbackState.value.copyWith(
      playing: false,
      processingState: AudioProcessingState.idle,
    ));
    BackgroundAudioService()._onStop?.call();
  }
}
