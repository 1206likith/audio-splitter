import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audio_splitter_app/asp2/control/control_plane.dart';
import 'package:audio_splitter_app/asp2/dsp/parametric_eq.dart';
import 'package:audio_splitter_app/asp2/dsp/pcm_float.dart';
import 'package:audio_splitter_app/asp2/mix/mixer.dart';
import 'package:audio_splitter_app/asp2/mix/zone_mixer.dart';
import 'package:audio_splitter_app/asp2/mix/zone_route.dart';
import 'package:audio_splitter_app/asp2/sync/client_sync_report.dart';
import 'package:audio_splitter_app/asp2/sync/ptp_lite.dart';
import 'package:audio_splitter_app/core/contracts/audio_format.dart';
import 'package:audio_splitter_app/core/pipeline/audio_chunk.dart';
import 'package:audio_splitter_app/core/pipeline/source_router.dart';
import 'package:flutter_test/flutter_test.dart';

/// A stereo sine chunk starting at absolute frame [startFrame] (so successive
/// ticks continue the same phase — no boundary discontinuity).
PcmChunk stereoSine({
  required double freq,
  int startFrame = 0,
  int frames = 960, // 20 ms @ 48 kHz
  double amplitude = 0.4,
  int tsUs = 0,
  AudioFormat format = AudioFormat.cdStereo,
}) {
  final ch = format.channels;
  final pcm = Uint8List(frames * ch * 2);
  final bd = ByteData.view(pcm.buffer);
  for (var f = 0; f < frames; f++) {
    final v = amplitude *
        math.sin(2 * math.pi * freq * (startFrame + f) / format.sampleRate);
    for (var c = 0; c < ch; c++) {
      bd.setInt16((f * ch + c) * 2, PcmFloat.toPcm16(v), Endian.little);
    }
  }
  return PcmChunk(pcm: pcm, presentationTsUs: tsUs, format: format);
}

double rms(PcmChunk chunk) {
  final ch = PcmFloat.deinterleave(chunk.pcm, chunk.format);
  double sum = 0;
  int n = 0;
  for (final c in ch) {
    for (final s in c) {
      sum += s * s;
      n++;
    }
  }
  return n == 0 ? 0 : math.sqrt(sum / n);
}

double peak(PcmChunk chunk) {
  final ch = PcmFloat.deinterleave(chunk.pcm, chunk.format);
  double p = 0;
  for (final c in ch) {
    for (final s in c) {
      if (s.abs() > p) p = s.abs();
    }
  }
  return p;
}

double dbToLin(double db) => math.pow(10, db / 20).toDouble();

void main() {
  group('ZoneRoute', () {
    test('JSON round-trips including EQ, mix-minus, and hrtf flag', () {
      const route = ZoneRoute(
        zoneId: 'patio',
        name: 'Patio Speakers',
        sourceGains: {'mic': 0.8, 'music': 1.0},
        eq: [
          EqBand(type: EqBandType.lowShelf, freqHz: 120, gainDb: 2.0),
          EqBand(type: EqBandType.peaking, freqHz: 3000, q: 1.0, gainDb: -2.0),
        ],
        compress: true,
        limit: true,
        mixMinusSourceId: 'mic',
        hrtfMode: true,
      );
      final back = ZoneRoute.fromJson(route.toJson());
      expect(back.zoneId, 'patio');
      expect(back.name, 'Patio Speakers');
      expect(back.sourceGains, {'mic': 0.8, 'music': 1.0});
      expect(back.eq.length, 2);
      expect(back.eq.first.type, EqBandType.lowShelf);
      expect(back.compress, isTrue);
      expect(back.mixMinusSourceId, 'mic');
      expect(back.hrtfMode, isTrue);
    });

    test('contributingSourceIds drops the mix-minus source; gainFor zeroes it',
        () {
      const route = ZoneRoute(
        zoneId: 'monitor',
        sourceGains: {'vocal': 1.0, 'band': 0.9},
        mixMinusSourceId: 'vocal',
      );
      expect(route.contributingSourceIds, ['band']);
      expect(route.gainFor('vocal'), 0.0);
      expect(route.gainFor('band'), 0.9);
      expect(route.gainFor('unknown'), 0.0);
    });

    test('dspDiffersFrom: gains are hot-swappable, EQ/dynamics are not', () {
      const base = ZoneRoute(
        zoneId: 'z',
        sourceGains: {'a': 1.0},
        eq: [EqBand(type: EqBandType.peaking, freqHz: 1000, gainDb: 3)],
      );
      // Pure gain change ⇒ no DSP rebuild needed.
      expect(
          base.dspDiffersFrom(base.copyWith(sourceGains: {'a': 0.5})), isFalse);
      // EQ change ⇒ rebuild needed.
      expect(base.dspDiffersFrom(base.copyWith(eq: const [])), isTrue);
      // Dynamics toggle ⇒ rebuild needed.
      expect(base.dspDiffersFrom(base.copyWith(compress: true)), isTrue);
    });
  });

  group('Mixer', () {
    test('adaptChannels mono → stereo fans out; stereo → mono averages', () {
      final mono = [
        Float64List.fromList([0.2, -0.4, 0.6])
      ];
      final stereoised = Mixer.adaptChannels(mono, 2);
      expect(stereoised.length, 2);
      expect(stereoised[0], stereoised[1]);
      expect(stereoised[0][1], -0.4);

      final stereo = [
        Float64List.fromList([1.0, 0.0]),
        Float64List.fromList([0.0, 0.5]),
      ];
      final mixedDown = Mixer.adaptChannels(stereo, 1);
      expect(mixedDown.length, 1);
      expect(mixedDown[0][0], closeTo(0.5, 1e-12)); // (1.0+0.0)/2
      expect(mixedDown[0][1], closeTo(0.25, 1e-12)); // (0.0+0.5)/2
    });

    test('sum is a weighted add and zero-extends ragged lengths', () {
      final a = [
        Float64List.fromList([0.5, 0.5, 0.5, 0.5])
      ];
      final b = [
        Float64List.fromList([0.5, 0.5]) // shorter
      ];
      final out = Mixer.sum([a, b], [1.0, 0.5], 1);
      expect(out[0].length, 4); // longest wins
      expect(out[0][0], closeTo(0.75, 1e-12)); // 0.5*1 + 0.5*0.5
      expect(out[0][2], closeTo(0.5, 1e-12)); // b ran out ⇒ silence
    });
  });

  group('ZoneMixer', () {
    test('mixes routed sources at their gains', () {
      final mixer = ZoneMixer(
        const ZoneRoute(
          zoneId: 'z',
          sourceGains: {'a': 1.0, 'b': 1.0},
          limit: false, // isolate the sum from limiter gain reduction
        ),
      );
      final frame = {
        'a': stereoSine(freq: 300, amplitude: 0.2),
        'b': stereoSine(freq: 300, amplitude: 0.2),
      };
      final out = mixer.render(frame, tsUs: 0);
      // Two identical in-phase sines at 0.2 sum to ~0.4.
      expect(rms(out), greaterThan(rms(frame['a']!) * 1.8));
    });

    test('mix-minus excludes the performer\'s own source exactly', () {
      // Monitor for "vocal": routes everyone but must drop vocal itself.
      final monitor = ZoneMixer(
        const ZoneRoute(
          zoneId: 'mon',
          sourceGains: {'vocal': 1.0, 'band': 1.0},
          mixMinusSourceId: 'vocal',
        ),
      );
      // Reference: a zone that only routes "band".
      final reference = ZoneMixer(
        const ZoneRoute(zoneId: 'ref', sourceGains: {'band': 1.0}),
      );
      final frame = {
        'vocal': stereoSine(freq: 800, amplitude: 0.5),
        'band': stereoSine(freq: 200, amplitude: 0.3),
      };
      final monOut = monitor.render(frame, tsUs: 0);
      final refOut = reference.render(frame, tsUs: 0);
      // Identical routing once vocal is removed ⇒ byte-for-byte identical.
      expect(monOut.pcm, refOut.pcm);
    });

    test('mix-minus of the only source yields aligned silence', () {
      final mixer = ZoneMixer(
        const ZoneRoute(
          zoneId: 'solo',
          sourceGains: {'me': 1.0},
          mixMinusSourceId: 'me',
        ),
      );
      final frame = {'me': stereoSine(freq: 440, amplitude: 0.7)};
      final out = mixer.render(frame, tsUs: 0);
      expect(out.pcm.length, frame['me']!.pcm.length); // length-aligned
      expect(peak(out), 0.0); // pure silence
    });

    test('post-mix limiter caps the zone even when sources sum hot', () {
      final mixer = ZoneMixer(
        const ZoneRoute(
          zoneId: 'z',
          sourceGains: {'a': 1.0, 'b': 1.0, 'c': 1.0},
          // limit defaults to true
        ),
      );
      final frame = {
        'a': stereoSine(freq: 500, amplitude: 0.9),
        'b': stereoSine(freq: 500, amplitude: 0.9),
        'c': stereoSine(freq: 500, amplitude: 0.9), // sums to ~2.7 pre-limit
      };
      final out = mixer.render(frame, tsUs: 0);
      expect(peak(out), lessThanOrEqualTo(dbToLin(-1.0) + 0.02));
    });

    test('idle zone (no routed source present) emits length-aligned silence',
        () {
      final mixer = ZoneMixer(
        const ZoneRoute(zoneId: 'z', sourceGains: {'absent': 1.0}),
      );
      final frame = {'other': stereoSine(freq: 440)};
      final out = mixer.render(frame, tsUs: 123);
      expect(out.pcm.length, frame['other']!.pcm.length);
      expect(out.presentationTsUs, 123);
      expect(peak(out), 0.0);
    });
  });

  group('SourceRouter DAG', () {
    test('routes one frame to each zone with the right source subset', () {
      final router = SourceRouter()
        ..upsertZone(const ZoneRoute(
            zoneId: 'patio',
            sourceGains: {'mic': 0.8, 'music': 1.0},
            limit: false))
        ..upsertZone(const ZoneRoute(
            zoneId: 'stage', sourceGains: {'music': 1.0}, limit: false));
      final frame = {
        'mic': stereoSine(freq: 900, amplitude: 0.3),
        'music': stereoSine(freq: 200, amplitude: 0.3),
      };
      final out = router.route(frame, tsUs: 5000);
      expect(out.keys.toSet(), {'patio', 'stage'});
      expect(out['patio']!.presentationTsUs, 5000);
      // Patio mixes two sources, stage only one ⇒ patio is louder.
      expect(rms(out['patio']!), greaterThan(rms(out['stage']!)));
      router.dispose();
    });

    test('upsert updates a zone in place; remove drops it', () {
      final router = SourceRouter()
        ..upsertZone(const ZoneRoute(zoneId: 'z', sourceGains: {'a': 1.0}));
      expect(router.zoneCount, 1);
      router.upsertZone(
          const ZoneRoute(zoneId: 'z', sourceGains: {'a': 0.5, 'b': 1.0}));
      expect(router.zoneCount, 1); // same id ⇒ updated, not added
      expect(router.routeFor('z')!.sourceGains.length, 2);
      router.removeZone('z');
      expect(router.zoneCount, 0);
      router.dispose();
    });
  });

  group('ControlMessage envelope', () {
    test('wraps and unwraps a ZoneRoute over the wire', () {
      const route = ZoneRoute(
        zoneId: 'patio',
        sourceGains: {'mic': 1.0},
        hrtfMode: true,
      );
      final wire = ControlMessage.zoneRoute(route).encode();
      final msg = ControlMessage.decode(wire);
      expect(msg.type, ControlMessageType.zoneRoute);
      final back = msg.asZoneRoute();
      expect(back.zoneId, 'patio');
      expect(back.hrtfMode, isTrue);
    });

    test('multiplexes ptp + telemetry payloads with type dispatch', () {
      final probe = ControlMessage.ptpProbe(const PtpProbe(seq: 3, t1: 111));
      expect(probe.type, ControlMessageType.ptpProbe);
      expect(probe.asPtpProbe().seq, 3);

      const report = ClientSyncReport(
        clientId: 'phone-1',
        bufferDepthMs: 40,
        driftUs: -2000,
        dropped: 0,
        jitterVarMs: 1.0,
        rttUs: 7000,
      );
      final wire = ControlMessage.syncReport(report).encode();
      final decoded = ControlMessage.decode(wire);
      expect(decoded.type, ControlMessageType.syncReport);
      expect(decoded.asSyncReport().clientId, 'phone-1');

      final remove =
          ControlMessage.decode(ControlMessage.zoneRemove('stage').encode());
      expect(remove.type, ControlMessageType.zoneRemove);
      expect(remove.asZoneRemoveId(), 'stage');
    });
  });

  group('Phase 3 GATE — 4 zones × 3 sources simultaneously, no glitches', () {
    test(
        'every zone emits length-aligned, bounded audio across many ticks; '
        'mix-minus verified', () {
      final router = SourceRouter();
      // 4 zones, 3 shared sources, varied routing — including a mix-minus
      // monitor and a no-limiter recording stem.
      router.upsertZone(const ZoneRoute(
        zoneId: 'patio',
        sourceGains: {'mic': 0.8, 'music': 1.0},
        eq: [EqBand(type: EqBandType.highShelf, freqHz: 10000, gainDb: 2.0)],
      ));
      router.upsertZone(const ZoneRoute(
        zoneId: 'stage',
        sourceGains: {'music': 1.0, 'guest': 0.9},
        compress: true,
      ));
      router.upsertZone(const ZoneRoute(
        zoneId: 'record',
        sourceGains: {'mic': 1.0, 'music': 1.0, 'guest': 1.0},
        limit: false, // stem capture: no safety limiter
      ));
      // Guest's monitor: hears everyone but themselves (mix-minus).
      router.upsertZone(const ZoneRoute(
        zoneId: 'mon-guest',
        sourceGains: {'mic': 1.0, 'music': 1.0, 'guest': 1.0},
        mixMinusSourceId: 'guest',
      ));
      // Reference mixer proving the monitor really excludes 'guest'.
      final monRef = ZoneMixer(const ZoneRoute(
        zoneId: 'mon-ref',
        sourceGains: {'mic': 1.0, 'music': 1.0},
      ));

      const ticks = 50;
      const frames = 960; // 20 ms
      const fmt = AudioFormat.cdStereo;
      final expectedBytes = frames * fmt.channels * 2;
      final ceiling = dbToLin(-1.0) + 0.02;

      var startFrame = 0;
      for (var t = 0; t < ticks; t++) {
        final tsUs = t * 20000;
        final frame = {
          'mic': stereoSine(
              freq: 900, startFrame: startFrame, amplitude: 0.3, tsUs: tsUs),
          'music': stereoSine(
              freq: 200, startFrame: startFrame, amplitude: 0.5, tsUs: tsUs),
          'guest': stereoSine(
              freq: 1500, startFrame: startFrame, amplitude: 0.4, tsUs: tsUs),
        };
        startFrame += frames;

        final out = router.route(frame, tsUs: tsUs);
        expect(out.length, 4);

        for (final entry in out.entries) {
          final chunk = entry.value;
          // No zero-length gaps: every zone emits a full, length-aligned frame.
          expect(chunk.pcm.length, expectedBytes,
              reason: 'zone ${entry.key} tick $t produced a short/empty frame');
          expect(chunk.presentationTsUs, tsUs);
          // Finite, sane samples everywhere.
          final p = peak(chunk);
          expect(p.isFinite, isTrue);
          // Limited zones must respect the ceiling.
          if (router.routeFor(entry.key)!.limit) {
            expect(p, lessThanOrEqualTo(ceiling),
                reason: 'zone ${entry.key} tick $t exceeded the ceiling');
          }
        }

        // Mix-minus: guest's monitor == a mix of only {mic, music}.
        final refOut = monRef.render(frame, tsUs: tsUs);
        expect(out['mon-guest']!.pcm, refOut.pcm,
            reason: 'mix-minus must exclude the guest from their own monitor');
      }

      // ignore: avoid_print
      print('Phase 3 gate: 4 zones x 3 sources x $ticks ticks — all '
          'length-aligned, ceiling held on limited zones, mix-minus exact.');
      router.dispose();
    });
  });
}
