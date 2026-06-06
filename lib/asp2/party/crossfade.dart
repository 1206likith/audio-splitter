import 'dart:math' as math;
import 'dart:typed_data';

import '../../core/contracts/audio_format.dart';
import '../../core/pipeline/audio_chunk.dart';
import '../dsp/pcm_float.dart';
import '../mix/mixer.dart';
import 'beat_grid.dart';

/// The crossfader transfer curve. **Equal-power** is the DJ default: at the
/// centre both decks play at ~0.707 so the *summed power* (and perceived
/// loudness) stays constant across the blend, instead of dipping in the middle
/// the way a straight linear fade does.
enum FadeCurve { equalPower, linear }

/// Stateless crossfader gain math. [position] runs 0.0 (full deck A) → 1.0 (full
/// deck B).
class Crossfade {
  Crossfade._();

  /// Gain applied to deck A at [position].
  static double gainA(double position,
      {FadeCurve curve = FadeCurve.equalPower}) {
    final t = position.clamp(0.0, 1.0);
    switch (curve) {
      case FadeCurve.equalPower:
        return math.cos(t * math.pi / 2);
      case FadeCurve.linear:
        return 1.0 - t;
    }
  }

  /// Gain applied to deck B at [position].
  static double gainB(double position,
      {FadeCurve curve = FadeCurve.equalPower}) {
    final t = position.clamp(0.0, 1.0);
    switch (curve) {
      case FadeCurve.equalPower:
        return math.sin(t * math.pi / 2);
      case FadeCurve.linear:
        return t;
    }
  }
}

/// Computes the tempo + phase adjustments needed to **beat-match** deck B to
/// deck A so a crossfade lands seamlessly. Pure — operates on tempos and beat
/// grids, no audio.
class BeatMatcher {
  BeatMatcher._();

  /// Tempo ratio to apply to a track of [sourceBpm] so it plays at [targetBpm].
  /// Clamped to the same 0.5–2.0 DJ window the decks use.
  static double tempoRatio(double sourceBpm, double targetBpm) {
    if (sourceBpm <= 0) return 1.0;
    return (targetBpm / sourceBpm).clamp(0.5, 2.0);
  }

  /// Microsecond nudge to apply to deck B so its nearest beat lands on deck A's
  /// beat at [atTsUs]. Positive ⇒ B is early and should be delayed; the result
  /// is within ±half a beat of A's grid (whichever direction is shorter).
  static int phaseOffsetUs(BeatGrid a, BeatGrid b, int atTsUs) {
    final period = a.beatPeriodUs;
    final aBeat = a.nextBeatUs(atTsUs).toDouble();
    final bBeat = b.nextBeatUs(atTsUs).toDouble();
    var diff = bBeat - aBeat;
    // Fold into (−period/2, period/2].
    diff = diff % period;
    if (diff > period / 2) diff -= period;
    if (diff <= -period / 2) diff += period;
    return diff.round();
  }

  /// True when [b] is within [toleranceUs] of phase-locked to [a] at [atTsUs].
  static bool isPhaseLocked(BeatGrid a, BeatGrid b, int atTsUs,
          {int toleranceUs = 5000}) =>
      phaseOffsetUs(a, b, atTsUs).abs() <= toleranceUs;
}

/// The host's two-deck crossfader: blends deck A and deck B PCM into one mixed
/// chunk at the current fader [position]. This is the audio half of "two hosts
/// crossfade live" — it reuses the tested float round-trip ([PcmFloat]) and the
/// weighted summer ([Mixer.sum]), so the output is byte-deterministic for the
/// gate.
class HostCrossfader {
  final AudioFormat format;
  final FadeCurve curve;

  double _position;

  HostCrossfader({
    this.format = AudioFormat.cdStereo,
    this.curve = FadeCurve.equalPower,
    double position = 0.0,
  }) : _position = position.clamp(0.0, 1.0);

  double get position => _position;
  set position(double p) => _position = p.clamp(0.0, 1.0);

  double get gainA => Crossfade.gainA(_position, curve: curve);
  double get gainB => Crossfade.gainB(_position, curve: curve);

  /// Mix [a] and [b] (either may be null = silence) into one chunk at the
  /// current position, multiplying in each deck's own [deckGainA]/[deckGainB]
  /// channel fader. The output length is the longer input; the timestamp is
  /// taken from deck A when present, else deck B.
  PcmChunk mix(
    PcmChunk? a,
    PcmChunk? b, {
    double deckGainA = 1.0,
    double deckGainB = 1.0,
  }) {
    final ca = a == null
        ? <Float64List>[
            for (var c = 0; c < format.channels; c++) Float64List(0)
          ]
        : Mixer.adaptChannels(
            PcmFloat.deinterleave(a.pcm, a.format), format.channels);
    final cb = b == null
        ? <Float64List>[
            for (var c = 0; c < format.channels; c++) Float64List(0)
          ]
        : Mixer.adaptChannels(
            PcmFloat.deinterleave(b.pcm, b.format), format.channels);

    final mixed = Mixer.sum(
      [ca, cb],
      [gainA * deckGainA, gainB * deckGainB],
      format.channels,
    );
    final pcm = PcmFloat.interleave(mixed, format);
    final tsUs = a?.presentationTsUs ?? b?.presentationTsUs ?? 0;
    return PcmChunk(pcm: pcm, presentationTsUs: tsUs, format: format);
  }
}
