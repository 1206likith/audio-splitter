import 'dart:typed_data';

import 'package:audio_splitter_app/asp2/fec/fec_group.dart';
import 'package:flutter_test/flutter_test.dart';

/// Deterministic LCG — reproducible "random" loss without Math.random (which is
/// unavailable in workflow scripts and makes tests flaky anyway).
class _Lcg {
  int _s;
  _Lcg(this._s);
  int next() {
    _s = (_s * 1103515245 + 12345) & 0x7fffffff;
    return _s;
  }

  /// True with probability [pct]/100.
  bool roll(int pct) => next() % 100 < pct;
}

/// Stand-in for Opus PLC: a lost-and-unrecoverable frame still produces a full
/// 20 ms concealment buffer, never a zero-length gap. (Real path: OpusCodec
/// .decode(empty) → opus_decode(null). Here we assert the gate property without
/// needing the native binary.)
Uint8List plcConceal() =>
    Uint8List(960 * 2 * 2); // 20ms stereo PCM16, non-empty

/// Variable-length payload, like a real Opus packet (40..120 bytes).
Uint8List packet(int seed) {
  final len = 40 + (seed * 7) % 80;
  final out = Uint8List(len);
  int x = seed & 0xFF;
  for (int i = 0; i < len; i++) {
    x = (x * 31 + 13) & 0xFF;
    out[i] = x;
  }
  return out;
}

void main() {
  group('FEC + PLC pipeline loss-resilience (Phase 1 gate)', () {
    test('10% random packet loss produces no zero-length gaps', () {
      const groups = 200; // 200 groups x 8 = 1600 media frames
      final fec = FecGroup();
      final k = fec.dataShards;
      final m = fec.parityShards;
      final lcg = _Lcg(0xC0FFEE);

      int totalFrames = 0;
      int recovered = 0;
      int concealed = 0;
      int delivered = 0;
      int byteExact = 0;

      for (int g = 0; g < groups; g++) {
        final groupId = (g % 255) + 1;
        final payloads = [for (int i = 0; i < k; i++) packet(g * 100 + i)];
        final enc = fec.encode(payloads, groupId: groupId);

        // Simulate the network: drop each of the k+m frames at ~10%.
        final dataByIndex = <int, Uint8List>{};
        final parityByIndex = <int, Uint8List>{};
        for (int i = 0; i < k; i++) {
          if (!lcg.roll(10)) dataByIndex[i] = payloads[i];
        }
        for (int p = 0; p < m; p++) {
          if (!lcg.roll(10)) parityByIndex[p] = enc.parityPayloads[p];
        }

        // Receiver: try FEC recovery, else PLC-fill the still-missing data.
        final rec = fec.recover(
          dataByIndex: dataByIndex,
          parityByIndex: parityByIndex,
          shardLen: enc.shardLen,
        );

        for (int i = 0; i < k; i++) {
          totalFrames++;
          Uint8List out;
          if (rec != null) {
            out = rec[i];
            if (!dataByIndex.containsKey(i)) recovered++;
            if (_eq(out, payloads[i])) byteExact++;
          } else if (dataByIndex.containsKey(i)) {
            out = dataByIndex[i]!;
            if (_eq(out, payloads[i])) byteExact++;
          } else {
            out = plcConceal();
            concealed++;
          }
          // THE GATE: every delivered frame is non-empty.
          expect(out, isNotEmpty,
              reason: 'group $g frame $i produced a zero-length gap');
          if (out.isNotEmpty) delivered++;
        }
      }

      // Sanity: the simulation actually exercised both recovery and PLC.
      expect(delivered, totalFrames);
      expect(recovered, greaterThan(0),
          reason: 'FEC should have recovered frames');
      expect(concealed, greaterThan(0),
          reason: 'some groups should exceed m losses and hit PLC');
      // Every non-concealed frame must be byte-exact (FEC is lossless).
      expect(byteExact, totalFrames - concealed);

      // ignore: avoid_print
      print('FEC pipeline: $totalFrames frames, $recovered FEC-recovered, '
          '$concealed PLC-concealed, 0 zero-length gaps');
    });
  });
}

bool _eq(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
