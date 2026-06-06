import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audio_splitter_app/asp2/codec/opus_codec.dart';
import 'package:audio_splitter_app/core/contracts/i_codec.dart';
import 'package:flutter_test/flutter_test.dart';

/// Build 20 ms of a stereo 440 Hz sine as PCM16 (one Opus frame at 48 kHz).
Uint8List sineFrame({int channels = 2, double freq = 440}) {
  const n = OpusCodec.samplesPerChannel;
  final out = Uint8List(n * channels * 2);
  final bd = ByteData.view(out.buffer);
  for (int i = 0; i < n; i++) {
    final s = (math.sin(2 * math.pi * freq * i / OpusCodec.sampleRate) * 20000)
        .round();
    for (int c = 0; c < channels; c++) {
      bd.setInt16((i * channels + c) * 2, s, Endian.little);
    }
  }
  return out;
}

/// Normalised cross-correlation of two equal-length PCM16 buffers.
double correlation(Uint8List a, Uint8List b) {
  final n = math.min(a.length, b.length) ~/ 2;
  final va = ByteData.view(a.buffer, a.offsetInBytes);
  final vb = ByteData.view(b.buffer, b.offsetInBytes);
  double sa = 0, sb = 0, saa = 0, sbb = 0, sab = 0;
  for (int i = 0; i < n; i++) {
    final x = va.getInt16(i * 2, Endian.little).toDouble();
    final y = vb.getInt16(i * 2, Endian.little).toDouble();
    sa += x;
    sb += y;
    saa += x * x;
    sbb += y * y;
    sab += x * y;
  }
  final cov = sab - sa * sb / n;
  final da = math.sqrt(saa - sa * sa / n);
  final db = math.sqrt(sbb - sb * sb / n);
  if (da == 0 || db == 0) return 0;
  return cov / (da * db);
}

void main() {
  group('OpusCodec (native libopus)', () {
    test('codec id is opus regardless of native availability', () {
      // Pure-constant check, no library needed.
      expect(CodecId.opus, 1);
    });

    test('tryCreate never throws; returns null when libopus is absent', () {
      // The whole point of the load-probe: graceful degradation to PCM16.
      final codec = OpusCodec.tryCreate();
      if (codec == null) {
        // Expected on this CI/dev box (no vendored binary yet).
        return;
      }
      addTearDown(codec.dispose);
      expect(codec.codecId, CodecId.opus);
      expect(codec.format.sampleRate, OpusCodec.sampleRate);
    });

    test('encode→decode round-trip correlates >0.95 [needs libopus]', () {
      final codec = OpusCodec.tryCreate();
      if (codec == null) {
        markTestSkipped(
            'libopus not present — drop a binary per third_party/README.md');
        return;
      }
      addTearDown(codec.dispose);

      final pcm = sineFrame();
      final packet = codec.encode(pcm);
      expect(packet, isNotEmpty);
      expect(packet.length, lessThan(pcm.length),
          reason: 'Opus should compress vs PCM16');

      final decoded = codec.decode(packet);
      expect(decoded.length, pcm.length);
      // Opus is lossy + has ~6.5ms look-ahead; correlation, not equality.
      expect(correlation(pcm, decoded), greaterThan(0.95));
    });

    test(
        'PLC: empty payload yields a full 20ms frame, not a gap [needs libopus]',
        () {
      final codec = OpusCodec.tryCreate();
      if (codec == null) {
        markTestSkipped('libopus not present');
        return;
      }
      addTearDown(codec.dispose);

      // Prime the decoder with one real packet so PLC has state to extrapolate.
      codec.decode(codec.encode(sineFrame()));
      final concealed = codec.decode(Uint8List(0));
      expect(concealed.length, codec.frameBytes,
          reason: 'PLC must fill the gap with a full frame, never zero-length');
    });
  });
}
