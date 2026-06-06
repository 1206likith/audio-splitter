import 'dart:async';
import 'package:flutter/foundation.dart';

class RecordingService {
  static final RecordingService _instance = RecordingService._internal();
  factory RecordingService() => _instance;
  RecordingService._internal();

  bool get isRecording => false;

  Future<bool> startRecording(
    Stream<Uint8List> audioStream, {
    int sampleRate = 48000,
    int channels = 2,
    String? fileName,
  }) async {
    debugPrint('RecordingService: not available on web');
    return false;
  }

  Future<String?> stopRecording() async => null;
}
