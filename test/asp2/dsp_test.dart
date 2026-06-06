import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audio_splitter_app/asp2/dsp/compressor.dart';
import 'package:audio_splitter_app/asp2/dsp/effect_chain.dart';
import 'package:audio_splitter_app/asp2/dsp/limiter.dart';
import 'package:audio_splitter_app/asp2/dsp/parametric_eq.dart';
import 'package:audio_splitter_app/asp2/dsp/pcm_float.dart';
import 'package:audio_splitter_app/asp2/dsp/rnnoise_denoiser.dart';
import 'package:audio_splitter_app/core/contracts/audio_format.dart';
import 'package:audio_splitter_app/core/pipeline/audio_chunk.dart';
import 'package:flutter_test/flutter_test.dart';

/// Build [ms] of a mono sine at [freq] Hz, PCM16, as a PcmChunk.
PcmChunk sineChunk({
  double freq = 440,
  int ms = 100,
  double amplitude = 0.5,
  AudioFormat format = AudioFormat.voiceMono,
}) {
  final frames = format.samplesPerChannel(ms);
  final ch = format.channels;
  final pcm = Uint8List(frames * ch * 2);
  final bd = ByteData.view(pcm.buffer);
  for (var f = 0; f < frames; f++) {
    final v = amplitude * math.sin(2 * math.pi * freq * f / format.sampleRate);
    for (var c = 0; c < ch; c++) {
      bd.setInt16((f * ch + c) * 2, PcmFloat.toPcm16(v), Endian.little);
    }
  }
  return PcmChunk(pcm: pcm, presentationTsUs: 0, format: format);
}

/// RMS of a chunk in float domain.
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

/// Peak absolute sample in float domain.
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
  group('PcmFloat round-trip', () {
    test('deinterleave/interleave preserves samples', () {
      final chunk = sineChunk(format: AudioFormat.cdStereo, ms: 20);
      final ch = PcmFloat.deinterleave(chunk.pcm, chunk.format);
      final back = PcmFloat.interleave(ch, chunk.format);
      expect(back, chunk.pcm);
    });

    test('saturates beyond full scale', () {
      expect(PcmFloat.toPcm16(2.0), 32767);
      expect(PcmFloat.toPcm16(-2.0), -32768);
    });
  });

  group('ParametricEq', () {
    test('peaking boost raises energy at the target band', () {
      // Sine at 3kHz, EQ with +12dB peak at 3kHz ⇒ louder output.
      final input = sineChunk(freq: 3000, ms: 200, amplitude: 0.3);
      final eq = ParametricEq(
        format: AudioFormat.voiceMono,
        bands: const [
          EqBand(type: EqBandType.peaking, freqHz: 3000, q: 1.0, gainDb: 12.0)
        ],
      );
      final out = eq.process(input);
      // Skip the filter's settling transient by comparing steady-state RMS.
      expect(rms(out), greaterThan(rms(input) * 1.5));
    });

    test('peaking cut away from a tone leaves it ~unchanged', () {
      final input = sineChunk(freq: 3000, ms: 200, amplitude: 0.3);
      final eq = ParametricEq(
        format: AudioFormat.voiceMono,
        bands: const [
          // Cut at 100Hz — far from the 3kHz tone, minimal effect.
          EqBand(type: EqBandType.peaking, freqHz: 100, q: 1.0, gainDb: -12.0)
        ],
      );
      final out = eq.process(input);
      expect(rms(out), closeTo(rms(input), rms(input) * 0.1));
    });

    test('empty band list is a pass-through', () {
      final input = sineChunk(ms: 20);
      final eq = ParametricEq(format: AudioFormat.voiceMono, bands: const []);
      expect(eq.process(input).pcm, input.pcm);
    });

    test('state is continuous across chunk boundaries', () {
      // Processing one 200ms chunk == processing two 100ms halves back to back.
      final whole = sineChunk(freq: 1000, ms: 200, amplitude: 0.4);
      EqBand band() => const EqBand(
          type: EqBandType.peaking, freqHz: 1000, q: 1.0, gainDb: 6.0);

      final eqA = ParametricEq(format: AudioFormat.voiceMono, bands: [band()]);
      final outWhole = eqA.process(whole);

      final eqB = ParametricEq(format: AudioFormat.voiceMono, bands: [band()]);
      final h1 = sineChunk(freq: 1000, ms: 100, amplitude: 0.4);
      // Second half must continue the same phase; rebuild with offset.
      const format = AudioFormat.voiceMono;
      final frames = format.samplesPerChannel(100);
      final pcm2 = Uint8List(frames * 2);
      final bd = ByteData.view(pcm2.buffer);
      for (var f = 0; f < frames; f++) {
        final globalF = f + frames;
        final v =
            0.4 * math.sin(2 * math.pi * 1000 * globalF / format.sampleRate);
        bd.setInt16(f * 2, PcmFloat.toPcm16(v), Endian.little);
      }
      final h2 = PcmChunk(pcm: pcm2, presentationTsUs: 0, format: format);
      final o1 = eqB.process(h1);
      final o2 = eqB.process(h2);

      // Concatenate the two halves and compare with the whole.
      final joined = Uint8List.fromList([...o1.pcm, ...o2.pcm]);
      expect(joined.length, outWhole.pcm.length);
      // Allow ±1 LSB rounding differences.
      var maxDiff = 0;
      final a = ByteData.view(joined.buffer);
      final b = ByteData.view(outWhole.pcm.buffer);
      for (var i = 0; i < joined.length; i += 2) {
        final d =
            (a.getInt16(i, Endian.little) - b.getInt16(i, Endian.little)).abs();
        if (d > maxDiff) maxDiff = d;
      }
      expect(maxDiff, lessThanOrEqualTo(1));
    });
  });

  group('Compressor', () {
    test('reduces dynamic range (loud parts attenuated more)', () {
      // A loud sine well above threshold should come out quieter (pre-makeup).
      final loud = sineChunk(freq: 500, ms: 300, amplitude: 0.9);
      final comp = Compressor(
        format: AudioFormat.voiceMono,
        thresholdDb: -18,
        ratio: 4.0,
        makeupDb: 0,
        attackMs: 2,
        releaseMs: 50,
      );
      final out = comp.process(loud);
      expect(rms(out), lessThan(rms(loud)));
    });

    test('quiet signal below threshold passes ~unchanged', () {
      // -40dBFS sine, threshold -18dB ⇒ no compression.
      final quiet = sineChunk(freq: 500, ms: 200, amplitude: dbToLin(-40));
      final comp = Compressor(
        format: AudioFormat.voiceMono,
        thresholdDb: -18,
        ratio: 4.0,
        makeupDb: 0,
      );
      final out = comp.process(quiet);
      expect(rms(out), closeTo(rms(quiet), rms(quiet) * 0.1));
    });
  });

  group('Limiter', () {
    test('hard-caps peaks under the ceiling', () {
      final hot = sineChunk(freq: 200, ms: 200, amplitude: 0.98);
      final limiter = Limiter(
        format: AudioFormat.voiceMono,
        ceilingDb: -1.0,
        lookaheadMs: 1.5,
        releaseMs: 50,
      );
      final out = limiter.process(hot);
      final ceiling = dbToLin(-1.0);
      // Allow a tiny tolerance for the release ramp + rounding.
      expect(peak(out), lessThanOrEqualTo(ceiling + 0.01));
    });

    test('signal already under the ceiling is largely untouched', () {
      final soft = sineChunk(freq: 200, ms: 200, amplitude: 0.3);
      final limiter = Limiter(format: AudioFormat.voiceMono, ceilingDb: -1.0);
      final out = limiter.process(soft);
      // Delayed by look-ahead but RMS preserved.
      expect(rms(out), closeTo(rms(soft), rms(soft) * 0.05));
    });
  });

  group('EffectChain + presets', () {
    test('runs effects in series', () {
      final input = sineChunk(freq: 1000, ms: 100, amplitude: 0.95);
      final chain = DspPresets.musicMaster(format: AudioFormat.cdStereo);
      final out = chain.process(_stereoize(input));
      // Final limiter guarantees the ceiling regardless of EQ boost upstream.
      expect(peak(out), lessThanOrEqualTo(dbToLin(-1.0) + 0.02));
    });

    test('voiceClarity chain produces a full-length, bounded output', () {
      final input = sineChunk(
          freq: 900, ms: 100, amplitude: 0.8, format: AudioFormat.voiceMono);
      final chain = DspPresets.voiceClarity();
      final out = chain.process(input);
      expect(out.pcm, isNotEmpty);
      expect(peak(out), lessThanOrEqualTo(dbToLin(-1.0) + 0.05));
    });
  });

  group('RnnoiseDenoiser load-probe', () {
    test('tryCreate never throws; null when librnnoise absent', () {
      final d = RnnoiseDenoiser.tryCreate();
      if (d == null) return; // expected on this box (no vendored binary)
      addTearDown(d.dispose);
      expect(d.id, isNotEmpty);
    });

    test('denoise round-trip preserves length [needs librnnoise]', () {
      final d = RnnoiseDenoiser.tryCreate();
      if (d == null) {
        markTestSkipped(
            'librnnoise not present — drop a binary per third_party/README.md');
        return;
      }
      addTearDown(d.dispose);
      // Feed exactly one frame so it emits processed audio.
      const frames = RnnoiseDenoiser.expectedFrameSize;
      final pcm = Uint8List(frames * 2);
      final chunk = PcmChunk(
          pcm: pcm, presentationTsUs: 0, format: AudioFormat.voiceMono);
      final out = d.process(chunk);
      expect(out.pcm.length, pcm.length);
    });
  });
}

/// Duplicate a mono chunk into stereo for the music chain test.
PcmChunk _stereoize(PcmChunk mono) {
  final monoCh = PcmFloat.deinterleave(mono.pcm, mono.format);
  final stereo = [monoCh[0], Float64List.fromList(monoCh[0])];
  const fmt = AudioFormat.cdStereo;
  return PcmChunk(
    pcm: PcmFloat.interleave(stereo, fmt),
    presentationTsUs: mono.presentationTsUs,
    format: fmt,
  );
}
