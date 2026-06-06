import 'dart:typed_data';

import '../../core/contracts/audio_format.dart';

/// Pure-Dart canonical **WAV (RIFF/PCM)** writer — the live, no-dependency
/// lossless recording format. Two uses:
///
///  * [header] builds the 44-byte canonical header for a known data length,
///    which the streaming recorder writes as a placeholder up front and
///    finalizes on stop (the crash-safe pattern the legacy [RecordingService]
///    already used — now shared and unit-tested here).
///  * [encode] builds a complete in-memory `.wav` from a PCM buffer (used by
///    the stem recorder and the session-bundle packager).
///
/// Only 16-bit integer PCM is emitted (`AudioFormat.bitDepth == 16`), matching
/// every source/codec in the pipeline. The header is byte-for-byte the same as
/// the v1 recorder's so existing recordings stay readable.
class WavWriter {
  WavWriter._();

  /// "RIFF", "WAVE", "fmt ", "data" magic, all little-endian.
  static const int _riff = 0x46464952; // 'RIFF'
  static const int _wave = 0x45564157; // 'WAVE'
  static const int _fmt = 0x20746d66; // 'fmt '
  static const int _data = 0x61746164; // 'data'

  /// The fixed canonical header size for PCM (RIFF + fmt(16) + data chunk).
  static const int headerBytes = 44;

  /// Build the 44-byte canonical WAV header describing [dataBytes] of PCM in
  /// [format]. When the final length is unknown up front, pass `0`, stream the
  /// PCM, then rewrite the first 44 bytes with the real [dataBytes].
  static Uint8List header({
    required AudioFormat format,
    required int dataBytes,
  }) {
    assert(format.bitDepth == 16, 'WavWriter emits 16-bit PCM only');
    final h = ByteData(headerBytes);
    final byteRate = format.sampleRate * format.frameBytes;

    h.setUint32(0, _riff, Endian.little);
    h.setUint32(4, 36 + dataBytes, Endian.little); // RIFF chunk size
    h.setUint32(8, _wave, Endian.little);

    h.setUint32(12, _fmt, Endian.little);
    h.setUint32(16, 16, Endian.little); // fmt chunk size
    h.setUint16(20, 1, Endian.little); // audio format = PCM
    h.setUint16(22, format.channels, Endian.little);
    h.setUint32(24, format.sampleRate, Endian.little);
    h.setUint32(28, byteRate, Endian.little);
    h.setUint16(32, format.frameBytes, Endian.little); // block align
    h.setUint16(34, format.bitDepth, Endian.little);

    h.setUint32(36, _data, Endian.little);
    h.setUint32(40, dataBytes, Endian.little);
    return h.buffer.asUint8List();
  }

  /// Build a complete in-memory `.wav` (header + PCM) for [pcm] in [format].
  static Uint8List encode(AudioFormat format, Uint8List pcm) {
    final out = Uint8List(headerBytes + pcm.length);
    out.setRange(0, headerBytes, header(format: format, dataBytes: pcm.length));
    out.setRange(headerBytes, out.length, pcm);
    return out;
  }
}
