import 'dart:typed_data';

import 'package:audio_splitter_app/asp2/fec/fec_group.dart';
import 'package:audio_splitter_app/asp2/fec/reed_solomon.dart';
import 'package:flutter_test/flutter_test.dart';

/// Deterministic pseudo-random bytes (no Math.random — keeps tests reproducible).
Uint8List ramp(int len, int seed) {
  final out = Uint8List(len);
  int x = seed & 0xFF;
  for (int i = 0; i < len; i++) {
    x = (x * 31 + 7) & 0xFF;
    out[i] = x;
  }
  return out;
}

void main() {
  group('Gf256 arithmetic', () {
    test('multiply by zero and one', () {
      expect(Gf256.mul(0, 123), 0);
      expect(Gf256.mul(123, 0), 0);
      expect(Gf256.mul(1, 123), 123);
      expect(Gf256.mul(123, 1), 123);
    });

    test('multiply is commutative and matches div inverse', () {
      for (int a = 1; a < 256; a += 7) {
        for (int b = 1; b < 256; b += 11) {
          final p = Gf256.mul(a, b);
          expect(Gf256.mul(b, a), p);
          // p / b == a
          expect(Gf256.div(p, b), a);
        }
      }
    });

    test('inverse(a) * a == 1 for every non-zero element', () {
      for (int a = 1; a < 256; a++) {
        expect(Gf256.mul(a, Gf256.inverse(a)), 1, reason: 'a=$a');
      }
    });
  });

  group('Gf256Matrix', () {
    test('identity multiply is a no-op', () {
      final v = Gf256Matrix.vandermonde(4, 4);
      final id = Gf256Matrix.identity(4);
      final r = v.multiply(id);
      for (int i = 0; i < 4; i++) {
        expect(r.data[i], v.data[i]);
      }
    });

    test('invert then multiply yields identity', () {
      // Vandermonde square matrices are invertible.
      final v = Gf256Matrix.vandermonde(5, 5);
      final inv = v.invert();
      final prod = v.multiply(inv);
      for (int r = 0; r < 5; r++) {
        for (int c = 0; c < 5; c++) {
          expect(prod.data[r][c], r == c ? 1 : 0, reason: '($r,$c)');
        }
      }
    });

    test('singular matrix throws on invert', () {
      final m = Gf256Matrix(3, 3); // all zeros
      expect(m.invert, throwsA(isA<StateError>()));
    });
  });

  group('ReedSolomon', () {
    test('encodeParity produces the requested parity count', () {
      final rs = ReedSolomon(4, 2);
      final data = [for (int i = 0; i < 4; i++) ramp(16, i + 1)];
      final parity = rs.encodeParity(data);
      expect(parity.length, 2);
      expect(parity.every((p) => p.length == 16), isTrue);
    });

    test('recovers when all data shards present (fast path)', () {
      final rs = ReedSolomon(4, 2);
      final data = [for (int i = 0; i < 4; i++) ramp(16, i + 1)];
      final parity = rs.encodeParity(data);
      final shards = <Uint8List?>[...data, ...parity];
      final recovered = rs.reconstructData(shards);
      for (int i = 0; i < 4; i++) {
        expect(recovered[i], data[i]);
      }
    });

    test('recovers any 2 erased shards from k+m', () {
      final rs = ReedSolomon(4, 2);
      final data = [for (int i = 0; i < 4; i++) ramp(32, i + 3)];
      final parity = rs.encodeParity(data);

      // Erase every distinct pair of shard positions; all must recover.
      for (int a = 0; a < 6; a++) {
        for (int b = a + 1; b < 6; b++) {
          final shards = <Uint8List?>[...data, ...parity];
          shards[a] = null;
          shards[b] = null;
          final recovered = rs.reconstructData(shards);
          for (int i = 0; i < 4; i++) {
            expect(recovered[i], data[i], reason: 'erased $a,$b -> data[$i]');
          }
        }
      }
    });

    test('throws when more than m shards are lost', () {
      final rs = ReedSolomon(4, 2);
      final data = [for (int i = 0; i < 4; i++) ramp(16, i + 1)];
      final parity = rs.encodeParity(data);
      final shards = <Uint8List?>[...data, ...parity];
      shards[0] = null;
      shards[1] = null;
      shards[2] = null; // 3 losses, only 2 parity
      expect(() => rs.reconstructData(shards), throwsA(isA<StateError>()));
    });
  });

  group('FecGroup (variable-length payloads)', () {
    test('recovers lost data packets at default k=8/m=2', () {
      final fec = FecGroup();
      // Variable-length payloads, like real Opus packets.
      final payloads = [for (int i = 0; i < 8; i++) ramp(40 + i * 5, i + 1)];
      final result = fec.encode(payloads, groupId: 1);
      expect(result.groupId, 1);
      expect(result.parityPayloads.length, 2);
      // shardLen = max(len)+2 = (40+35)+2 = 77.
      expect(result.shardLen, 77);

      // Lose data shards 2 and 6; keep both parity shards.
      final dataByIndex = <int, Uint8List>{};
      for (int i = 0; i < 8; i++) {
        if (i != 2 && i != 6) dataByIndex[i] = payloads[i];
      }
      final parityByIndex = <int, Uint8List>{
        0: result.parityPayloads[0],
        1: result.parityPayloads[1],
      };

      final recovered = fec.recover(
        dataByIndex: dataByIndex,
        parityByIndex: parityByIndex,
        shardLen: result.shardLen,
      );
      expect(recovered, isNotNull);
      for (int i = 0; i < 8; i++) {
        expect(recovered![i], payloads[i], reason: 'payload[$i]');
      }
    });

    test('recovers one lost data shard using a single parity shard', () {
      final fec = FecGroup();
      final payloads = [for (int i = 0; i < 8; i++) ramp(20, i + 2)];
      final result = fec.encode(payloads, groupId: 5);

      final dataByIndex = <int, Uint8List>{};
      for (int i = 0; i < 8; i++) {
        if (i != 3) dataByIndex[i] = payloads[i];
      }
      final recovered = fec.recover(
        dataByIndex: dataByIndex,
        parityByIndex: {0: result.parityPayloads[0]},
        shardLen: result.shardLen,
      );
      expect(recovered, isNotNull);
      expect(recovered![3], payloads[3]);
    });

    test('fast path when no data shard was lost', () {
      final fec = FecGroup();
      final payloads = [for (int i = 0; i < 8; i++) ramp(12, i + 1)];
      final result = fec.encode(payloads, groupId: 7);
      final recovered = fec.recover(
        dataByIndex: {for (int i = 0; i < 8; i++) i: payloads[i]},
        parityByIndex: const {},
        shardLen: result.shardLen,
      );
      expect(recovered, isNotNull);
      expect(recovered, payloads);
    });

    test('returns null when too many shards are lost', () {
      final fec = FecGroup();
      final payloads = [for (int i = 0; i < 8; i++) ramp(16, i + 1)];
      final result = fec.encode(payloads, groupId: 9);
      // Lose 3 data shards, only 2 parity available.
      final dataByIndex = <int, Uint8List>{};
      for (int i = 0; i < 8; i++) {
        if (i != 0 && i != 1 && i != 2) dataByIndex[i] = payloads[i];
      }
      final recovered = fec.recover(
        dataByIndex: dataByIndex,
        parityByIndex: {
          0: result.parityPayloads[0],
          1: result.parityPayloads[1],
        },
        shardLen: result.shardLen,
      );
      expect(recovered, isNull);
    });

    test('rejects the reserved group id 0', () {
      final fec = FecGroup();
      final payloads = [for (int i = 0; i < 8; i++) ramp(8, i + 1)];
      expect(
        () => fec.encode(payloads, groupId: FecGroup.noFecGroupId),
        throwsArgumentError,
      );
    });
  });
}
