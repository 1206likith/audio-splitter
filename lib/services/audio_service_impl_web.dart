import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/audio_stream.dart' as model;

class AudioService {
  static final AudioService _instance = AudioService._internal();
  factory AudioService() => _instance;
  AudioService._internal();

  // Stream controllers
  final StreamController<Uint8List> _audioDataController =
      StreamController<Uint8List>.broadcast();
  Stream<Uint8List> get audioDataStream => _audioDataController.stream;

  final StreamController<double> _volumeLevelController =
      StreamController<double>.broadcast();
  Stream<double> get volumeLevelStream => _volumeLevelController.stream;

  // State
  bool get isRecording => false;
  bool get isPlaying => false;
  bool get isInitialized => false;
  model.AudioSource get currentSource => model.AudioSource.microphone;
  model.AudioQuality get currentQuality => model.AudioQuality.high;
  bool get preferSpeakerOutput => true;

  String? get selectedMediaFilePath => null;
  void setSelectedMediaFile(String? path) {}

  void setStreamingUrl(String url) {}

  bool isSourceSupported(model.AudioSource source) => false;

  String sourceSupportNote(model.AudioSource source) =>
      'Audio capture is not available on web.';

  Future<bool> initialize() async {
    debugPrint('AudioService: not available on web');
    return false;
  }

  Future<void> dispose() async {
    await _audioDataController.close();
    await _volumeLevelController.close();
  }

  Future<bool> startRecording({
    model.AudioSource source = model.AudioSource.microphone,
    model.AudioQuality quality = model.AudioQuality.high,
  }) async =>
      false;

  Future<void> stopRecording() async {}

  Future<bool> startPlayback(
    Stream<Uint8List> audioStream, {
    int sampleRate = 48000,
    int numChannels = 2,
  }) async =>
      false;

  Future<void> stopPlayback() async {}

  Future<bool> playAudioFile(String filePath) async => false;

  Future<void> setVolume(double volume) async {}

  Future<void> setPlaybackSpeed(double speed) async {}

  Future<void> setPreferSpeakerOutput(bool preferSpeaker) async {}

  void setPlaylist(List<String> paths) {}

  Future<void> nextTrack() async {}

  Future<void> previousTrack() async {}

  List<String> get playlist => const [];
  int get playlistIndex => 0;
  bool get isPlaylistMode => false;
  String? get currentTrackName => null;
}
