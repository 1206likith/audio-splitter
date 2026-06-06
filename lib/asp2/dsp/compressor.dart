import 'dart:math' as math;
import 'dart:typed_data';

import '../../core/contracts/audio_format.dart';
import '../../core/contracts/i_effect.dart';
import '../../core/pipeline/audio_chunk.dart';
import 'pcm_float.dart';

/// A feed-forward dynamic-range compressor ([IEffect]) with a smoothed,
/// peak-detecting envelope follower. Evens out level so quiet talkers stay
/// audible and loud transients don't dominate — the dynamics half of the
/// Phase 2 voice/music DSP chain.
///
/// Gain computation runs in the dB domain (the natural space for a ratio); the
/// envelope is shared across channels so stereo imaging is preserved (both
/// channels are attenuated by the same amount, no wandering pan).
class Compressor implements IEffect {
  @override
  final String id;

  final AudioFormat format;

  /// Level above which compression engages, in dBFS.
  final double thresholdDb;

  /// Compression ratio (e.g. 4.0 ⇒ 4:1). 1.0 is a no-op.
  final double ratio;

  /// Soft-knee width in dB centered on the threshold (0 ⇒ hard knee).
  final double kneeDb;

  /// Make-up gain applied after compression, in dB.
  final double makeupDb;

  final double _attackCoeff;
  final double _releaseCoeff;

  double _envDb = -120.0; // running envelope in dB

  Compressor({
    this.format = AudioFormat.cdStereo,
    this.thresholdDb = -18.0,
    this.ratio = 3.0,
    this.kneeDb = 6.0,
    this.makeupDb = 0.0,
    double attackMs = 5.0,
    double releaseMs = 80.0,
    this.id = 'compressor',
  })  : _attackCoeff = _timeToCoeff(attackMs, format.sampleRate),
        _releaseCoeff = _timeToCoeff(releaseMs, format.sampleRate);

  static double _timeToCoeff(double ms, int sampleRate) {
    if (ms <= 0) return 0;
    // One-pole smoothing coefficient for the given time constant.
    return math.exp(-1.0 / (ms * 0.001 * sampleRate));
  }

  static double _linToDb(double x) =>
      x <= 1e-9 ? -180.0 : 20 * (math.log(x) / math.ln10);

  static double _dbToLin(double db) => math.pow(10, db / 20).toDouble();

  /// Static gain-computer: input level (dB) → output level (dB) with soft knee.
  double _computeGainDb(double inputDb) {
    final over = inputDb - thresholdDb;
    double outOver;
    if (kneeDb > 0 && over > -kneeDb / 2 && over < kneeDb / 2) {
      // Quadratic soft-knee interpolation across the knee region.
      final x = over + kneeDb / 2;
      outOver = over + (1 / ratio - 1) * x * x / (2 * kneeDb);
    } else if (over <= -kneeDb / 2) {
      outOver = over; // below knee: unity
    } else {
      outOver = over / ratio; // above knee: full ratio
    }
    return outOver - over; // gain reduction (≤ 0 dB)
  }

  @override
  PcmChunk process(PcmChunk chunk) {
    if (ratio <= 1.0 && makeupDb == 0.0) return chunk;
    final channels = PcmFloat.deinterleave(chunk.pcm, format);
    final frames = channels.isEmpty ? 0 : channels[0].length;
    final makeupLin = _dbToLin(makeupDb);

    for (var f = 0; f < frames; f++) {
      // Detector: peak across channels for this frame.
      double peak = 0;
      for (final ch in channels) {
        final a = ch[f].abs();
        if (a > peak) peak = a;
      }
      final levelDb = _linToDb(peak);

      // Envelope follower: attack when rising, release when falling.
      final coeff = levelDb > _envDb ? _attackCoeff : _releaseCoeff;
      _envDb = levelDb + coeff * (_envDb - levelDb);

      final gainDb = _computeGainDb(_envDb);
      final gainLin = _dbToLin(gainDb) * makeupLin;

      for (final ch in channels) {
        ch[f] *= gainLin;
      }
    }

    final Uint8List out = PcmFloat.interleave(channels, format);
    return chunk.copyWith(pcm: out);
  }

  @override
  void dispose() {
    _envDb = -120.0;
  }
}
