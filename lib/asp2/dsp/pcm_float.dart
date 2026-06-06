import 'dart:typed_data';

import '../../core/contracts/audio_format.dart';

/// Conversion helpers between interleaved little-endian PCM16 (the ASP-2 wire
/// currency) and the normalized `[-1.0, 1.0]` floating-point domain DSP runs in.
///
/// Kept in one place so every effect uses identical scaling and identical
/// saturating round-trip rules (off-by-one scale errors between effects produce
/// DC offsets and gain mismatches that are maddening to debug).
class PcmFloat {
  PcmFloat._();

  /// PCM16 spans [-32768, 32767]; we scale by 32768 so full-scale negative maps
  /// to exactly -1.0 (the asymmetric +32767 just reaches +0.99997, as expected).
  static const double scale = 32768.0;

  static double toFloat(int sample) => sample / scale;

  /// Saturating conversion back to a 16-bit sample.
  static int toPcm16(double v) {
    final s = (v * scale).round();
    if (s > 32767) return 32767;
    if (s < -32768) return -32768;
    return s;
  }

  /// Deinterleave PCM16 bytes into one `Float64List` per channel.
  static List<Float64List> deinterleave(Uint8List pcm, AudioFormat format) {
    final ch = format.channels;
    final frames = pcm.length ~/ (2 * ch);
    final out = List.generate(ch, (_) => Float64List(frames));
    final bd = ByteData.view(pcm.buffer, pcm.offsetInBytes, pcm.length);
    var i = 0;
    for (var f = 0; f < frames; f++) {
      for (var c = 0; c < ch; c++) {
        out[c][f] = toFloat(bd.getInt16(i, Endian.little));
        i += 2;
      }
    }
    return out;
  }

  /// Re-interleave per-channel float buffers into a fresh PCM16 byte buffer.
  static Uint8List interleave(List<Float64List> channels, AudioFormat format) {
    final ch = channels.length;
    final frames = ch == 0 ? 0 : channels[0].length;
    final out = Uint8List(frames * ch * 2);
    final bd = ByteData.view(out.buffer);
    var i = 0;
    for (var f = 0; f < frames; f++) {
      for (var c = 0; c < ch; c++) {
        bd.setInt16(i, toPcm16(channels[c][f]), Endian.little);
        i += 2;
      }
    }
    return out;
  }
}
