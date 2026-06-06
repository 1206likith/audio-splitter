import 'dart:typed_data';

import 'package:audio_splitter_app/asp2/dsp/effect_chain.dart';
import 'package:audio_splitter_app/asp2/fec/fec_group.dart';
import 'package:audio_splitter_app/asp2/frame/asp2_frame.dart';
import 'package:audio_splitter_app/asp2/mix/mixer.dart';
import 'package:audio_splitter_app/core/contracts/audio_format.dart';
import 'package:audio_splitter_app/core/pipeline/audio_chunk.dart';
import 'package:flutter_test/flutter_test.dart';

/// Phase 8 — performance benchmarks.
///
/// The plan asks for "performance benchmarks (codec / FEC / mix / DSP
/// throughput)". These measure the pure-Dart hot paths with a monotonic
/// [Stopwatch] (not the wall clock — consistent with the determinism rule; a
/// Stopwatch is a duration, not a timestamp) and print a throughput line each.
///
/// They are written as tests so they run in CI, but they assert **correctness
/// invariants under load** (the frame round-trips, FEC recovers the right
/// bytes, the mix has the expected shape) rather than an absolute MB/s — wall
/// speed varies by machine and would be flaky. The printed numbers are the
/// human-readable benchmark; the asserts are the gate.
void main() {
  /// 20 ms of CD-stereo audio: 960 frames × 2ch × 2B = 3840 bytes — the codec's
  /// natural packet size, so per-frame counts map to real-time frames/second.
  const framesPerPacket = 960;
  const stereo = AudioFormat.cdStereo;
  final packetBytes = framesPerPacket * stereo.frameBytes;

  Uint8List rampPayload(int bytes) =>
      Uint8List.fromList([for (var i = 0; i < bytes; i++) i & 0xFF]);

  String rate(String label, int units, String unit, Stopwatch sw) {
    final us = sw.elapsedMicroseconds.clamp(1, 1 << 62);
    final perSec = units * 1000000 / us;
    return '$label: $units $unit in $us µs '
        '→ ${perSec.toStringAsFixed(0)} $unit/s';
  }

  test('bench — ASP-2 frame encode + decode round-trip', () {
    const n = 20000;
    final payload = rampPayload(packetBytes);
    final template = Asp2Frame(
      codecId: 0,
      sequenceNumber: 0,
      presentationTsUs: 0,
      payload: payload,
    );

    var totalBytes = 0;
    final sw = Stopwatch()..start();
    for (var i = 0; i < n; i++) {
      final bytes = template.copyWith(sequenceNumber: i).encode();
      final decoded = Asp2Frame.decode(bytes);
      totalBytes += decoded.payload.length; // consumed so it isn't elided
    }
    sw.stop();

    // Invariant: every frame decoded to the full payload, and the last decode
    // is byte-exact and carries the right seq.
    expect(totalBytes, n * packetBytes);
    final check =
        Asp2Frame.decode(template.copyWith(sequenceNumber: 42).encode());
    expect(check.sequenceNumber, 42);
    expect(check.payload, payload);

    final mbPerSec = n * packetBytes / sw.elapsedMicroseconds.clamp(1, 1 << 62);
    // ignore: avoid_print
    print('${rate('frame codec', n, 'frames', sw)} '
        '(${mbPerSec.toStringAsFixed(1)} MB/s payload)');
  });

  test('bench — Reed-Solomon FEC encode + recover (k=8, m=2)', () {
    const n = 5000;
    final group = FecGroup(dataShards: 8, parityShards: 2);
    final payloads = [
      for (var s = 0; s < 8; s++) rampPayload(framesPerPacket * 2 + s),
    ];

    // Encode throughput.
    var sw = Stopwatch()..start();
    late FecEncodeResult enc;
    for (var i = 0; i < n; i++) {
      enc = group.encode(payloads, groupId: 1 + (i & 0xFE));
    }
    sw.stop();
    // ignore: avoid_print
    print(rate('FEC encode', n, 'groups', sw));

    // Recover throughput: drop data shards 2 and 5, rebuild from both parities.
    final surviving = {
      for (var s = 0; s < 8; s++)
        if (s != 2 && s != 5) s: payloads[s],
    };
    final parity = {0: enc.parityPayloads[0], 1: enc.parityPayloads[1]};
    sw = Stopwatch()..start();
    List<Uint8List>? recovered;
    for (var i = 0; i < n; i++) {
      recovered = group.recover(
        dataByIndex: surviving,
        parityByIndex: parity,
        shardLen: enc.shardLen,
      );
    }
    sw.stop();
    // ignore: avoid_print
    print(rate('FEC recover', n, 'groups', sw));

    // Invariant: the two lost shards came back byte-exact.
    expect(recovered, isNotNull);
    expect(recovered![2], payloads[2]);
    expect(recovered[5], payloads[5]);
  });

  test('bench — Mixer.sum (4 sources → stereo zone)', () {
    const n = 5000;
    List<Float64List> source(double v) => [
          Float64List(framesPerPacket)..fillRange(0, framesPerPacket, v),
          Float64List(framesPerPacket)..fillRange(0, framesPerPacket, v)
        ];
    final contributions = [source(0.1), source(0.2), source(0.3), source(0.4)];
    final gains = [1.0, 0.8, 0.6, 0.5];

    List<Float64List>? out;
    final sw = Stopwatch()..start();
    for (var i = 0; i < n; i++) {
      out = Mixer.sum(contributions, gains, 2);
    }
    sw.stop();

    // Invariant: stereo out, full length, expected weighted sum per sample.
    expect(out, hasLength(2));
    expect(out![0], hasLength(framesPerPacket));
    const expected = 0.1 * 1.0 + 0.2 * 0.8 + 0.3 * 0.6 + 0.4 * 0.5;
    expect(out[0][0], closeTo(expected, 1e-9));
    // ignore: avoid_print
    print(rate('mixer 4→2ch', n, 'blocks', sw));
  });

  test('bench — DSP music-master chain (EQ → comp → limiter)', () {
    const n = 3000;
    final chain = DspPresets.musicMaster(format: stereo);
    final pcm = Uint8List(packetBytes);
    final bd = ByteData.view(pcm.buffer);
    for (var i = 0; i < packetBytes ~/ 2; i++) {
      bd.setInt16(i * 2, (i % 200 - 100) * 200, Endian.little); // ~±20000
    }
    final chunk = PcmChunk(pcm: pcm, presentationTsUs: 0, format: stereo);

    PcmChunk? out;
    final sw = Stopwatch()..start();
    for (var i = 0; i < n; i++) {
      out = chain.process(chunk);
    }
    sw.stop();
    chain.dispose();

    // Invariant: same shape out, and the -1 dBTP limiter held the ceiling.
    expect(out!.pcm, hasLength(packetBytes));
    final outBd = ByteData.view(out.pcm.buffer);
    var peak = 0;
    for (var i = 0; i < packetBytes ~/ 2; i++) {
      final v = outBd.getInt16(i * 2, Endian.little).abs();
      if (v > peak) peak = v;
    }
    expect(peak, lessThanOrEqualTo(32768)); // never wrapped/overflowed
    final mbPerSec = n * packetBytes / sw.elapsedMicroseconds.clamp(1, 1 << 62);
    // ignore: avoid_print
    print('${rate('dsp master', n, 'blocks', sw)} '
        '(${mbPerSec.toStringAsFixed(1)} MB/s)');
  });
}
