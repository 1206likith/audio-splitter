import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audio_splitter_app/asp2/spatial/ambisonic.dart';
import 'package:audio_splitter_app/asp2/spatial/hrtf.dart';
import 'package:audio_splitter_app/asp2/spatial/positioning.dart';
import 'package:audio_splitter_app/core/contracts/audio_format.dart';
import 'package:audio_splitter_app/core/pipeline/audio_chunk.dart';
import 'package:flutter_test/flutter_test.dart';

/// A constant-amplitude mono signal as a Float64List.
Float64List constMono(double value, int frames) =>
    Float64List.fromList(List<double>.filled(frames, value));

/// A mono sine PcmChunk (voiceMono) for the chunk-level render path.
PcmChunk sineMonoChunk({
  required double freqHz,
  required double amp,
  required int frames,
  int tsUs = 0,
}) {
  const format = AudioFormat.voiceMono;
  final pcm = Uint8List(frames * format.frameBytes);
  final bd = ByteData.view(pcm.buffer);
  for (var f = 0; f < frames; f++) {
    final s =
        (amp * math.sin(2 * math.pi * freqHz * f / format.sampleRate) * 32000)
            .round();
    bd.setInt16(f * 2, s, Endian.little);
  }
  return PcmChunk(pcm: pcm, presentationTsUs: tsUs, format: format);
}

void main() {
  group('Vec2 / ListenerPose', () {
    test('distance, lerp, heading normalization', () {
      expect(const Vec2(3, 4).distanceTo(Vec2.zero), 5.0);
      expect(const Vec2(0, 0).lerp(const Vec2(10, 0), 0.5), const Vec2(5, 0));
      expect(const ListenerPose(headingDeg: -90).normalizedHeadingDeg, 270.0);
    });

    test('pose json round-trip', () {
      const p = ListenerPose(position: Vec2(1.5, -2.5), headingDeg: 45);
      expect(ListenerPose.fromJson(p.toJson()), p);
    });
  });

  group('Floorplan zone-bleed', () {
    test('equal-power normalization (Σ gain² ≈ 1)', () {
      final plan = Floorplan([
        const RoomZone(zoneId: 'a', center: Vec2(0, 0)),
        const RoomZone(zoneId: 'b', center: Vec2(10, 0)),
        const RoomZone(zoneId: 'c', center: Vec2(5, 8)),
      ]);
      for (final pos in [
        const Vec2(0, 0),
        const Vec2(5, 0),
        const Vec2(3, 4),
        const Vec2(9, 1),
      ]) {
        final g = plan.zoneGainsAt(pos);
        final sumSq = g.values.fold(0.0, (s, v) => s + v * v);
        expect(sumSq, closeTo(1.0, 1e-9));
      }
    });

    test('nearest zone labels the room you stand in', () {
      final plan = Floorplan([
        const RoomZone(zoneId: 'patio', center: Vec2(0, 0)),
        const RoomZone(zoneId: 'mainroom', center: Vec2(10, 0)),
      ]);
      expect(plan.nearestZone(const Vec2(1, 0))!.zoneId, 'patio');
      expect(plan.nearestZone(const Vec2(9, 0))!.zoneId, 'mainroom');
    });
  });

  group('Ambisonic encode/decode', () {
    test('SN3D coefficients: front vs hard-left', () {
      final front = AmbisonicEncoder.coefficients(
          const SphericalDir(azimuthDeg: 0)); // [W,Y,Z,X]
      expect(front[0], 1.0); // W
      expect(front[1], closeTo(0.0, 1e-12)); // Y
      expect(front[3], closeTo(1.0, 1e-12)); // X (pointing front)

      final left =
          AmbisonicEncoder.coefficients(const SphericalDir(azimuthDeg: 90));
      expect(left[1], closeTo(1.0, 1e-12)); // Y (full left)
      expect(left[3], closeTo(0.0, 1e-12)); // X
    });

    test('decode: hard-left source is left-only, front is centred', () {
      final mono = constMono(0.5, 64);
      final leftField =
          AmbisonicEncoder.encodeMono(mono, const SphericalDir(azimuthDeg: 90));
      final lr = AmbisonicDecoder.decodeStereo(leftField);
      expect(lr[0][0], closeTo(0.5, 1e-12)); // L full
      expect(lr[1][0], closeTo(0.0, 1e-12)); // R silent

      final frontField =
          AmbisonicEncoder.encodeMono(mono, const SphericalDir(azimuthDeg: 0));
      final fc = AmbisonicDecoder.decodeStereo(frontField);
      expect(fc[0][0], closeTo(fc[1][0], 1e-12)); // centred: L == R
    });

    test('yaw rotation moves a front source off-centre', () {
      final mono = constMono(0.5, 16);
      final field =
          AmbisonicEncoder.encodeMono(mono, const SphericalDir(azimuthDeg: 0));
      final centred = AmbisonicDecoder.decodeStereo(field);
      expect((centred[0][0] - centred[1][0]).abs(), closeTo(0.0, 1e-12));
      final turned = AmbisonicDecoder.decodeStereo(field, headingDeg: 90);
      expect((turned[0][0] - turned[1][0]).abs(), greaterThan(0.1));
    });
  });

  group('Binaural panner (ITD + ILD)', () {
    test('hard-left source: left is louder and earlier', () {
      const panner = BinauralPanner();
      final mono = constMono(0.5, 200);
      final lr =
          panner.renderBinaural(mono, const SphericalDir(azimuthDeg: 90));
      final left = lr[0], right = lr[1];

      // ILD: left (near ear) carries more energy than the shadowed right.
      final lEnergy = left.fold(0.0, (s, v) => s + v * v);
      final rEnergy = right.fold(0.0, (s, v) => s + v * v);
      expect(lEnergy, greaterThan(rEnergy));

      // ITD: the far (right) ear is delayed, so it starts with silence while the
      // near (left) ear is immediately full-scale.
      expect(left[0], closeTo(0.5, 1e-12));
      expect(right[0], 0.0);
    });

    test('itd sign flips with side; SteamAudio HRTF deferred', () {
      const panner = BinauralPanner();
      expect(panner.itdSeconds(const SphericalDir(azimuthDeg: 90)),
          greaterThan(0)); // left ⇒ right delayed
      expect(panner.itdSeconds(const SphericalDir(azimuthDeg: -90)),
          lessThan(0)); // right ⇒ left delayed
      expect(SteamAudioHrtf().isAvailable, isFalse);
    });

    test('renderChunk produces a stereo chunk from mono', () {
      const panner = BinauralPanner();
      final chunk = sineMonoChunk(freqHz: 220, amp: 0.5, frames: 480);
      final out = panner.renderChunk(chunk, const SphericalDir(azimuthDeg: 45));
      expect(out.format, AudioFormat.cdStereo);
      expect(out.pcm.length, 480 * AudioFormat.cdStereo.frameBytes);
    });
  });

  group('Phase 6 gate — spatial (walk between rooms)', () {
    test('crossfade is smooth, monotonic, equal-power as you walk A→B', () {
      final plan = Floorplan([
        const RoomZone(zoneId: 'a', center: Vec2(0, 0)),
        const RoomZone(zoneId: 'b', center: Vec2(10, 0)),
      ], bleedRadius: 4);

      double? prevA, prevB;
      const steps = 20;
      for (var i = 0; i <= steps; i++) {
        final x = 10.0 * i / steps;
        final g = plan.zoneGainsAt(Vec2(x, 0));
        final gA = g['a']!, gB = g['b']!;

        // Equal power everywhere along the walk.
        expect(gA * gA + gB * gB, closeTo(1.0, 1e-9));
        // A fades down, B fades up — no hard cut.
        if (prevA != null) expect(gA, lessThanOrEqualTo(prevA + 1e-12));
        if (prevB != null) expect(gB, greaterThanOrEqualTo(prevB - 1e-12));
        prevA = gA;
        prevB = gB;
      }

      // Endpoints dominated by the room you're standing in; midpoint balanced.
      final start = plan.zoneGainsAt(const Vec2(0, 0));
      final mid = plan.zoneGainsAt(const Vec2(5, 0));
      final end = plan.zoneGainsAt(const Vec2(10, 0));
      expect(start['a']!, greaterThan(0.95));
      expect(end['b']!, greaterThan(0.95));
      expect(mid['a']!, closeTo(mid['b']!, 1e-9));
      expect(mid['a']!, closeTo(math.sqrt(0.5), 1e-9)); // ~0.707 equal-power

      // ignore: avoid_print
      print('Phase 6 gate (spatial): walk A→B smooth — '
          'start a=${start['a']!.toStringAsFixed(3)}, '
          'mid a=${mid['a']!.toStringAsFixed(3)}/b=${mid['b']!.toStringAsFixed(3)}, '
          'end b=${end['b']!.toStringAsFixed(3)}; equal-power held.');
    });
  });
}
