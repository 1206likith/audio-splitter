import 'dart:typed_data';

import 'package:audio_splitter_app/asp2/frame/legacy_frame.dart';
import 'package:flutter_test/flutter_test.dart';

/// Original v1 implementation, copied verbatim from
/// `StreamingService._buildBinaryAudioFrame` (streaming_service.dart). The
/// golden test below asserts [LegacyFrameCodec.encode] is byte-identical to
/// this, so the Phase 0 refactor cannot silently change the wire format that
/// shipped v1 clients and the embedded browser client depend on.
Uint8List v1BuildBinaryAudioFrame(Uint8List audioData, int ts) {
  final header = Uint8List(9);
  header[0] = 1; // audio frame type
  final bd = ByteData.view(header.buffer);
  bd.setInt64(1, ts, Endian.little);
  return Uint8List.fromList([...header, ...audioData]);
}

void main() {
  Uint8List bytes(List<int> v) => Uint8List.fromList(v);

  group('LegacyFrameCodec golden', () {
    test('encode is byte-identical to v1 _buildBinaryAudioFrame', () {
      final payloads = <Uint8List>[
        bytes([]),
        bytes([0x00]),
        bytes(List<int>.generate(320, (i) => i & 0xFF)),
        bytes(List<int>.generate(4096, (i) => (i * 7) & 0xFF)),
      ];
      final timestamps = <int>[0, 1, 1717500000000, -1, 9007199254740991];

      for (final p in payloads) {
        for (final ts in timestamps) {
          expect(
            LegacyFrameCodec.encode(p, ts),
            equals(v1BuildBinaryAudioFrame(p, ts)),
            reason: 'mismatch for payload ${p.length}B ts=$ts',
          );
        }
      }
    });
  });

  group('LegacyFrameCodec round-trip', () {
    test('decode recovers payload and timestamp', () {
      final payload = bytes(List<int>.generate(512, (i) => (i * 3) & 0xFF));
      const ts = 1717500000123;
      final frame = LegacyFrameCodec.encode(payload, ts);
      final decoded = LegacyFrameCodec.decode(frame);
      expect(decoded, isNotNull);
      expect(decoded!.timestampMs, ts);
      expect(decoded.payload, payload);
    });

    test('decode rejects short buffers and wrong type', () {
      expect(LegacyFrameCodec.decode(Uint8List(8)), isNull);
      final wrongType = Uint8List(20)..[0] = 2;
      expect(LegacyFrameCodec.decode(wrongType), isNull);
    });

    test('decode rejects empty payload', () {
      final headerOnly = LegacyFrameCodec.encode(bytes([]), 5);
      expect(LegacyFrameCodec.decode(headerOnly), isNull);
    });
  });
}
