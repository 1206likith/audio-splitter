import 'dart:math' as math;
import 'dart:typed_data';

import '../../core/contracts/audio_format.dart';
import '../../core/contracts/i_effect.dart';
import '../../core/pipeline/audio_chunk.dart';
import 'pcm_float.dart';

/// A look-ahead brick-wall peak limiter ([IEffect]) — the last node in the
/// Phase 2 DSP chain, guaranteeing the signal never exceeds the ceiling (plan:
/// -1 dBTP) regardless of what the EQ/compressor upstream did.
///
/// "Look-ahead" means the gain reduction needed for a peak is applied slightly
/// *before* the peak arrives, so the attack never clips the very transient it is
/// trying to tame. The delay line that makes this possible carries state across
/// chunks, so streaming 20 ms frames is identical to one-shot processing.
class Limiter implements IEffect {
  @override
  final String id;

  final AudioFormat format;

  /// True-peak ceiling in dBFS (plan: -1 dBTP).
  final double ceilingDb;

  final double _ceilingLin;
  final int _lookaheadSamples;
  final double _releaseCoeff;

  // Per-channel look-ahead delay lines (ring buffers).
  final List<Float64List> _delay;
  int _writePos = 0;
  double _gain = 1.0;

  Limiter({
    this.format = AudioFormat.cdStereo,
    this.ceilingDb = -1.0,
    double lookaheadMs = 1.5,
    double releaseMs = 50.0,
    this.id = 'limiter',
  })  : _ceilingLin = math.pow(10, ceilingDb / 20).toDouble(),
        _lookaheadSamples =
            math.max(1, (lookaheadMs * 0.001 * format.sampleRate).round()),
        _releaseCoeff =
            math.exp(-1.0 / (releaseMs * 0.001 * format.sampleRate)),
        _delay = [
          for (var c = 0; c < format.channels; c++)
            Float64List(
                math.max(1, (lookaheadMs * 0.001 * format.sampleRate).round()))
        ];

  @override
  PcmChunk process(PcmChunk chunk) {
    final channels = PcmFloat.deinterleave(chunk.pcm, format);
    final frames = channels.isEmpty ? 0 : channels[0].length;
    final len = _lookaheadSamples;

    for (var f = 0; f < frames; f++) {
      // Peak across channels of the *incoming* sample (the future, from the
      // delay line's perspective).
      double peak = 0;
      for (final ch in channels) {
        final a = ch[f].abs();
        if (a > peak) peak = a;
      }

      // Target gain to keep this peak under the ceiling.
      final targetGain = peak > _ceilingLin ? _ceilingLin / peak : 1.0;
      // Instant attack (clamp down immediately), smoothed release back up.
      if (targetGain < _gain) {
        _gain = targetGain;
      } else {
        _gain = targetGain + _releaseCoeff * (_gain - targetGain);
      }

      // Emit the delayed sample (now aligned with the gain computed from the
      // look-ahead window) and store the current sample into the delay line.
      for (var c = 0; c < channels.length; c++) {
        final delayed = _delay[c];
        final outSample = delayed[_writePos];
        delayed[_writePos] = channels[c][f];
        channels[c][f] = outSample * _gain;
      }
      _writePos = (_writePos + 1) % len;
    }

    final Uint8List out = PcmFloat.interleave(channels, format);
    return chunk.copyWith(pcm: out);
  }

  @override
  void dispose() {
    for (final d in _delay) {
      d.fillRange(0, d.length, 0);
    }
    _gain = 1.0;
    _writePos = 0;
  }
}
