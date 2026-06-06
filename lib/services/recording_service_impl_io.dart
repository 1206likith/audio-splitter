import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../asp2/record/wav_writer.dart';
import '../core/contracts/audio_format.dart';

class RecordingService {
  static final RecordingService _instance = RecordingService._internal();
  factory RecordingService() => _instance;
  RecordingService._internal();

  IOSink? _fileSink;
  File? _recordingFile;
  StreamSubscription<Uint8List>? _streamSub;
  bool _isRecording = false;
  int _bytesWritten = 0;
  int _sampleRate = 48000;
  int _channels = 2;

  bool get isRecording => _isRecording;

  Future<bool> startRecording(
    Stream<Uint8List> audioStream, {
    int sampleRate = 48000,
    int channels = 2,
    String? fileName,
  }) async {
    if (_isRecording) return false;
    if (kIsWeb) return false;

    try {
      _sampleRate = sampleRate;
      _channels = channels;
      _bytesWritten = 0;

      final dir = await getApplicationDocumentsDirectory();
      final name =
          fileName ?? 'recording_${DateTime.now().millisecondsSinceEpoch}.wav';
      _recordingFile = File('${dir.path}/$name');
      _fileSink = _recordingFile!.openWrite();

      // Write placeholder WAV header (will be finalized on stop)
      _fileSink!.add(_buildWavHeader(0));

      _isRecording = true;
      _streamSub = audioStream.listen((data) {
        if (!_isRecording) return;
        _fileSink?.add(data);
        _bytesWritten += data.length;
      });

      return true;
    } catch (e) {
      debugPrint('RecordingService start error: $e');
      return false;
    }
  }

  Future<String?> stopRecording() async {
    if (!_isRecording) return null;
    _isRecording = false;

    try {
      await _streamSub?.cancel();
      _streamSub = null;
      await _fileSink?.flush();
      await _fileSink?.close();
      _fileSink = null;

      // Rewrite WAV header with actual byte count
      if (_recordingFile != null && await _recordingFile!.exists()) {
        final raf = await _recordingFile!.open(mode: FileMode.writeOnlyAppend);
        await raf.setPosition(0);
        await raf.writeFrom(_buildWavHeader(_bytesWritten));
        await raf.close();
        return _recordingFile!.path;
      }
    } catch (e) {
      debugPrint('RecordingService stop error: $e');
    }
    return null;
  }

  /// Canonical 16-bit PCM WAV header. Delegates to the shared, unit-tested
  /// [WavWriter] (Phase 7) so the recorder, the stem recorder, and the
  /// session-bundle packager all emit byte-identical headers.
  Uint8List _buildWavHeader(int dataBytes) => WavWriter.header(
        format: AudioFormat(
            sampleRate: _sampleRate, channels: _channels, bitDepth: 16),
        dataBytes: dataBytes,
      );
}
