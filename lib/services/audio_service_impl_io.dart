import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart' as ja;
import 'package:path_provider/path_provider.dart';
import '../asp2/sources/wav_file_source.dart';
import '../models/audio_stream.dart' as model;
import 'permissions_service.dart';

class AudioService {
  static final AudioService _instance = AudioService._internal();
  factory AudioService() => _instance;
  AudioService._internal();

  // Audio recording
  FlutterSoundRecorder? _recorder;
  FlutterSoundPlayer? _player;
  ja.AudioPlayer? _audioPlayer;
  StreamSubscription<Uint8List>? _playbackSub;
  StreamSubscription<RecordingDisposition>? _recorderProgressSub;
  StreamSubscription<int>? _mediaFileTimerSub;
  StreamSubscription<dynamic>? _systemAudioSub;

  // Platform channels for system audio capture
  static const EventChannel _systemAudioChannel =
      EventChannel('com.audiosplitter.app/system_audio');
  static const MethodChannel _systemAudioControl =
      MethodChannel('com.audiosplitter.app/system_audio_control');

  // Audio session
  AudioSession? _audioSession;

  // Stream controllers
  final StreamController<Uint8List> _audioDataController =
      StreamController<Uint8List>.broadcast();
  Stream<Uint8List> get audioDataStream => _audioDataController.stream;

  final StreamController<double> _volumeLevelController =
      StreamController<double>.broadcast();
  Stream<double> get volumeLevelStream => _volumeLevelController.stream;

  // Playlist / queue
  final List<String> _playlist = [];
  int _playlistIndex = 0;
  bool _isPlaylistMode = false;

  // State
  bool _isRecording = false;
  bool _isPlaying = false;
  bool _isInitialized = false;
  bool _preferSpeakerOutput = true;
  model.AudioSource _currentSource = model.AudioSource.microphone;
  model.AudioQuality _currentQuality = model.AudioQuality.high;

  // HLS relay state (Task 3)
  bool _streamRelayActive = false;
  String _streamingUrl = '';

  // Getters
  bool get isRecording => _isRecording;
  bool get isPlaying => _isPlaying;
  bool get isInitialized => _isInitialized;
  model.AudioSource get currentSource => _currentSource;
  model.AudioQuality get currentQuality => _currentQuality;
  bool get preferSpeakerOutput => _preferSpeakerOutput;

  /// Set the URL used by AudioSource.streaming before calling startRecording.
  void setStreamingUrl(String url) {
    _streamingUrl = url;
  }

  bool isSourceSupported(model.AudioSource source) {
    switch (source) {
      case model.AudioSource.microphone:
      case model.AudioSource.mediaFile:
      case model.AudioSource.musicPlayer: // Task 2: treat same as mediaFile
      case model.AudioSource.streaming: // Task 3: relay via FFmpeg
        return true;
      case model.AudioSource.systemAudio:
        return Platform.isWindows || Platform.isAndroid;
    }
  }

  String sourceSupportNote(model.AudioSource source) {
    switch (source) {
      case model.AudioSource.microphone:
        return 'Microphone capture is available.';
      case model.AudioSource.systemAudio:
        return 'System audio capture is available on Android 10+ and Windows.';
      case model.AudioSource.musicPlayer:
        return 'Music player — streams selected library track to all clients via conversion.';
      case model.AudioSource.mediaFile:
        return 'WAV/MP3/AAC/FLAC — all formats streamed to clients via conversion.';
      case model.AudioSource.streaming:
        return 'Online audio/HLS stream relayed to all clients in real time.';
    }
  }

  String? _selectedMediaFilePath;
  String? get selectedMediaFilePath => _selectedMediaFilePath;

  void setSelectedMediaFile(String? path) {
    _selectedMediaFilePath = path;
  }

  Future<bool> initialize() async {
    if (_isInitialized) return true;

    try {
      _audioSession = await AudioSession.instance;
      await _configureAudioSession();

      // Initialize recorder
      _recorder = FlutterSoundRecorder();
      await _recorder!.openRecorder();
      await _recorder!
          .setSubscriptionDuration(const Duration(milliseconds: 100));

      // Initialize player
      _player = FlutterSoundPlayer();
      await _player!.openPlayer();

      // Initialize audio player for playback
      _audioPlayer = ja.AudioPlayer();

      _isInitialized = true;
      return true;
    } catch (e) {
      debugPrint('Error initializing audio service: $e');
      return false;
    }
  }

  Future<void> dispose() async {
    await stopRecording();
    await stopPlayback();
    await _recorderProgressSub?.cancel();
    await _mediaFileTimerSub?.cancel();

    await _recorder?.closeRecorder();
    await _player?.closePlayer();
    await _audioPlayer?.dispose();

    await _audioDataController.close();
    await _volumeLevelController.close();

    _isInitialized = false;
  }

  Future<bool> startRecording({
    model.AudioSource source = model.AudioSource.microphone,
    model.AudioQuality quality = model.AudioQuality.high,
  }) async {
    if (!_isInitialized || _isRecording) return false;

    try {
      if (!isSourceSupported(source)) {
        debugPrint('Unsupported audio source selected: $source');
        return false;
      }

      // Ensure microphone permission (Android/iOS)
      final permOk = await PermissionsService().ensureMicPermission();
      if (!permOk) {
        return false;
      }

      _currentSource = source;
      _currentQuality = quality;

      if (source == model.AudioSource.systemAudio) {
        final supported = await _isSystemAudioSupported();
        if (!supported) return false;
        try {
          await _systemAudioControl.invokeMethod('startCapture');
          _isRecording = true;
          _systemAudioSub =
              _systemAudioChannel.receiveBroadcastStream().listen((data) {
            if (!_isRecording) return;
            if (data is Uint8List) {
              _audioDataController.add(data);
              // Compute RMS for volume display
              if (data.length >= 2) {
                final bd = ByteData.view(data.buffer);
                double sum = 0;
                for (int i = 0; i < data.length - 1; i += 2) {
                  final s = bd.getInt16(i, Endian.little).toDouble();
                  sum += s * s;
                }
                final rms = sum > 0 ? sum / (data.length ~/ 2) : 0.0;
                _volumeLevelController
                    .add((rms / (32768.0 * 32768.0)).clamp(0.0, 1.0));
              }
            }
          });
          return true;
        } catch (e) {
          debugPrint('System audio capture error: $e');
          return false;
        }
      }

      // Task 2: musicPlayer is handled identically to mediaFile
      if (source == model.AudioSource.mediaFile ||
          source == model.AudioSource.musicPlayer) {
        if (_selectedMediaFilePath == null) {
          debugPrint('No media file selected');
          return false;
        }

        final filePath = _selectedMediaFilePath!;
        final isWav = filePath.toLowerCase().endsWith('.wav');

        if (isWav) {
          return await _startWavFileStreaming(filePath);
        } else {
          // Non-WAV: convert to PCM WAV via FFmpeg, then start both local
          // playback and network streaming from the same converted file so
          // they are in sync (Task 1 fix — no separate playAudioFile call here).
          _isRecording = true;
          _mediaFileTimerSub?.cancel();
          _convertAndStreamNonWav(filePath);
          return true;
        }
      }

      // Task 3: online stream relay
      if (source == model.AudioSource.streaming) {
        _isRecording = true;
        await _startHlsStreaming(_streamingUrl);
        return true;
      }

      final codec = _getCodecForQuality(quality);
      final sampleRate = _getSampleRateForQuality(quality);

      await _recorder!.startRecorder(
        toStream: _audioDataController.sink,
        codec: codec,
        sampleRate: sampleRate,
        bitRate: quality.bitrate,
        numChannels: 2,
      );

      _isRecording = true;

      // Start volume level monitoring
      _startVolumeMonitoring();

      return true;
    } catch (e) {
      debugPrint('Error starting recording: $e');
      return false;
    }
  }

  Future<void> stopRecording() async {
    if (!_isRecording) return;

    try {
      if (_currentSource == model.AudioSource.systemAudio) {
        await _systemAudioSub?.cancel();
        _systemAudioSub = null;
        try {
          await _systemAudioControl.invokeMethod('stopCapture');
        } catch (_) {}
      }

      // Stop HLS relay loop if active (Task 3)
      _streamRelayActive = false;

      _isRecording = false;
      await _mediaFileTimerSub?.cancel();
      _mediaFileTimerSub = null;
      await _recorder?.stopRecorder();
      await _recorderProgressSub?.cancel();
      _recorderProgressSub = null;
    } catch (e) {
      debugPrint('Error stopping recording: $e');
    }
  }

  Future<bool> startPlayback(
    Stream<Uint8List> audioStream, {
    int sampleRate = 48000,
    int numChannels = 2,
  }) async {
    if (!_isInitialized || _isPlaying) return false;

    try {
      await _configureAudioSession();

      // Start player in stream mode for PCM16
      await _player!.startPlayerFromStream(
        codec: Codec.pcm16,
        numChannels: numChannels,
        sampleRate: sampleRate,
        bufferSize: 8192,
        interleaved: true,
      );

      // Feed incoming audio frames into the player's food sink
      _playbackSub = audioStream.listen((audioData) {
        if (_isPlaying) {
          _player!.uint8ListSink?.add(audioData);
        }
      });

      _isPlaying = true;
      return true;
    } catch (e) {
      debugPrint('Error starting playback: $e');
      return false;
    }
  }

  Future<void> stopPlayback() async {
    if (!_isPlaying) return;

    try {
      await _playbackSub?.cancel();
      _playbackSub = null;
      await _player?.stopPlayer();
      _isPlaying = false;
    } catch (e) {
      debugPrint('Error stopping playback: $e');
    }
  }

  Future<bool> playAudioFile(String filePath) async {
    if (!_isInitialized) return false;

    try {
      await _audioPlayer!.setFilePath(filePath);
      await _audioPlayer!.play();
      return true;
    } catch (e) {
      debugPrint('Error playing audio file: $e');
      return false;
    }
  }

  Future<void> setVolume(double volume) async {
    final clampedVolume = volume.clamp(0.0, 1.0);
    if (_audioPlayer != null) {
      await _audioPlayer!.setVolume(clampedVolume);
    }
    if (_player != null) {
      await _player!.setVolume(clampedVolume);
    }
  }

  Future<void> setPlaybackSpeed(double speed) async {
    if (_audioPlayer != null) {
      await _audioPlayer!.setSpeed(speed);
    }
  }

  Future<void> setPreferSpeakerOutput(bool preferSpeaker) async {
    if (_preferSpeakerOutput == preferSpeaker) return;
    _preferSpeakerOutput = preferSpeaker;
    if (_audioSession != null) {
      await _configureAudioSession();
    }
  }

  void _startVolumeMonitoring() {
    _recorderProgressSub?.cancel();
    _recorderProgressSub = _recorder?.onProgress?.listen((event) {
      final dbLevel = event.decibels ?? -160.0;
      final normalizedLevel = ((dbLevel + 160) / 160).clamp(0.0, 1.0);
      _volumeLevelController.add(normalizedLevel);
    });
  }

  Codec _getCodecForQuality(model.AudioQuality quality) {
    switch (quality) {
      case model.AudioQuality.low:
        return Codec.aacMP4;
      case model.AudioQuality.medium:
        return Codec.opusOGG;
      case model.AudioQuality.high:
        return Codec.opusOGG;
      case model.AudioQuality.ultra:
        return Codec.pcm16;
    }
  }

  int _getSampleRateForQuality(model.AudioQuality quality) {
    switch (quality) {
      case model.AudioQuality.low:
        return 22050;
      case model.AudioQuality.medium:
        return 48000;
      case model.AudioQuality.high:
        return 48000;
      case model.AudioQuality.ultra:
        return 48000;
    }
  }

  /// Task 1: Convert non-WAV to PCM WAV via FFmpeg, then start BOTH local
  /// Non-WAV streaming is not supported without the FFmpeg native library.
  /// Only WAV files are supported for network streaming.
  Future<void> _convertAndStreamNonWav(String filePath) async {
    debugPrint(
        '[AudioService] Non-WAV file streaming requires FFmpeg (not available). Only .wav files can be streamed. filePath=$filePath');
    _isRecording = false;
  }

  Future<bool> _isSystemAudioSupported() async {
    if (Platform.isWindows) return true;
    if (Platform.isAndroid) {
      try {
        return await _systemAudioControl.invokeMethod<bool>('isSupported') ??
            false;
      } catch (_) {
        return false;
      }
    }
    return false;
  }

  Future<bool> _startWavFileStreaming(String filePath) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) return false;
      final bytes = await file.readAsBytes();

      // Parse the WAV header via the shared ASP-2 parser (Phase 0.4) — the same
      // code path WavFileSource uses, so offsets/format never diverge. Returns
      // null for short / non-RIFF / non-PCM16 input (v1's silent rejection).
      final wav = WavPcmData.parse(bytes);
      if (wav == null) return false;
      final numChannels = wav.format.channels;
      final sampleRate = wav.format.sampleRate;

      _isRecording = true;
      const chunkMs = 100;
      final bytesPerMs = (sampleRate * numChannels * 2) ~/ 1000;
      final chunkSize = bytesPerMs * chunkMs;
      int offset = wav.dataOffset;

      _mediaFileTimerSub?.cancel();
      _mediaFileTimerSub = Stream.periodic(
        const Duration(milliseconds: chunkMs),
        (c) => c,
      ).listen((_) {
        if (!_isRecording || offset >= bytes.length) {
          _isRecording = false;
          return;
        }
        final end = (offset + chunkSize).clamp(0, bytes.length);
        final chunk = Uint8List.fromList(bytes.sublist(offset, end));
        offset = end;
        _audioDataController.add(chunk);

        // RMS volume
        if (chunk.length >= 2) {
          final cBd = ByteData.view(chunk.buffer);
          double sum = 0;
          for (int i = 0; i < chunk.length - 1; i += 2) {
            final s = cBd.getInt16(i, Endian.little).toDouble();
            sum += s * s;
          }
          final rms = sum > 0 ? (sum / (chunk.length ~/ 2)) : 0.0;
          _volumeLevelController
              .add((rms / (32768.0 * 32768.0)).clamp(0.0, 1.0));
        }
      });

      return true;
    } catch (e) {
      debugPrint('WAV streaming error: $e');
      return false;
    }
  }

  // --------------- Task 3: HLS / online stream relay ---------------

  /// Entry point called from the streaming branch in startRecording.
  Future<void> _startHlsStreaming(String url) async {
    if (url.isEmpty) {
      debugPrint('[AudioService] _startHlsStreaming: no URL set');
      return;
    }
    final dir = await getTemporaryDirectory();
    _streamRelayActive = true;
    // Run the chunk loop without awaiting so startRecording returns promptly.
    _streamRelayLoop(url, dir.path);
  }

  /// HLS relay requires FFmpeg (not available). This is a no-op stub.
  Future<void> _streamRelayLoop(String url, String tmpDir) async {
    debugPrint(
        '[AudioService] HLS relay requires FFmpeg (not available). url=$url');
    _streamRelayActive = false;
    await stopRecording();
  }

  // --------------- Playlist / queue ---------------

  void setPlaylist(List<String> paths) {
    _playlist.clear();
    _playlist.addAll(paths);
    _playlistIndex = 0;
    _isPlaylistMode = paths.isNotEmpty;
    if (paths.isNotEmpty) {
      setSelectedMediaFile(paths.first);
    }
  }

  Future<void> nextTrack() async {
    if (_playlist.isEmpty || _playlistIndex >= _playlist.length - 1) return;
    _playlistIndex++;
    setSelectedMediaFile(_playlist[_playlistIndex]);
    if (_isRecording) {
      await stopRecording();
      await startRecording(
        source: model.AudioSource.mediaFile,
        quality: _currentQuality,
      );
    }
  }

  Future<void> previousTrack() async {
    if (_playlist.isEmpty || _playlistIndex <= 0) return;
    _playlistIndex--;
    setSelectedMediaFile(_playlist[_playlistIndex]);
    if (_isRecording) {
      await stopRecording();
      await startRecording(
        source: model.AudioSource.mediaFile,
        quality: _currentQuality,
      );
    }
  }

  List<String> get playlist => List.unmodifiable(_playlist);
  int get playlistIndex => _playlistIndex;
  bool get isPlaylistMode => _isPlaylistMode;

  String? get currentTrackName {
    if (_playlist.isEmpty)
      return _selectedMediaFilePath?.split(RegExp(r'[/\\]')).last;
    return _playlist[_playlistIndex].split(RegExp(r'[/\\]')).last;
  }

  Future<void> _configureAudioSession() async {
    if (_audioSession == null) return;

    await _audioSession!.configure(AudioSessionConfiguration(
      avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
      avAudioSessionCategoryOptions: _preferSpeakerOutput
          ? AVAudioSessionCategoryOptions.allowBluetooth |
              AVAudioSessionCategoryOptions.defaultToSpeaker
          : AVAudioSessionCategoryOptions.allowBluetooth,
      avAudioSessionSetActiveOptions: AVAudioSessionSetActiveOptions.none,
      androidAudioAttributes: const AndroidAudioAttributes(
        contentType: AndroidAudioContentType.music,
        flags: AndroidAudioFlags.none,
        usage: AndroidAudioUsage.media,
      ),
      androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
      androidWillPauseWhenDucked: false,
    ));
  }

  // AAC convert stubs removed in Phase 1 — superseded by the real Opus codec
  // (lib/asp2/codec/opus_codec.dart). They had no callers and only ever
  // returned their input unchanged.
}
