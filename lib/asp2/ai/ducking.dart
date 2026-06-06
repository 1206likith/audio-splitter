import 'dart:math' as math;
import 'dart:typed_data';

import '../../core/contracts/audio_format.dart';
import '../../core/contracts/i_effect.dart';
import '../../core/pipeline/audio_chunk.dart';
import '../dsp/pcm_float.dart';
import 'vad.dart';

/// **Auto-ducker** ([IEffect]) — pulls the music down whenever speech is on the
/// sidechain (an announcement, a host on the mic, a live caption being spoken),
/// then lifts it back smoothly. The ducking *decision* comes from outside via
/// [setDucked] (driven by a VAD on the voice bus — see [SidechainDucker]); this
/// node just renders the gain envelope onto the music chunk.
///
/// The envelope smooths in the linear domain with separate attack (duck fast so
/// the voice is never buried) and release (recover slowly so it doesn't pump),
/// the same one-pole time-constant approach as the Phase 2 [Compressor].
class AutoDucker implements IEffect {
  @override
  final String id;

  final AudioFormat format;

  /// How far the music drops while ducked, dB (negative).
  final double duckDepthDb;

  final double _attackCoeff;
  final double _releaseCoeff;
  final double _duckGainLin;

  bool _ducked = false;
  double _gain = 1.0;

  AutoDucker({
    this.format = AudioFormat.cdStereo,
    this.duckDepthDb = -14.0,
    double attackMs = 40.0,
    double releaseMs = 400.0,
    this.id = 'auto-ducker',
  })  : _attackCoeff = _timeToCoeff(attackMs, format.sampleRate),
        _releaseCoeff = _timeToCoeff(releaseMs, format.sampleRate),
        _duckGainLin = math.pow(10, duckDepthDb / 20).toDouble();

  static double _timeToCoeff(double ms, int sampleRate) {
    if (ms <= 0) return 0;
    return math.exp(-1.0 / (ms * 0.001 * sampleRate));
  }

  /// Current smoothed music gain in `[duckGain, 1]` — for meters/tests.
  double get currentGain => _gain;

  /// Whether the music is currently being ducked toward the floor.
  bool get isDucked => _ducked;

  /// Set the sidechain decision: true ⇒ duck the music, false ⇒ recover.
  void setDucked(bool ducked) => _ducked = ducked;

  @override
  PcmChunk process(PcmChunk chunk) {
    final channels = PcmFloat.deinterleave(chunk.pcm, chunk.format);
    final frames = channels.isEmpty ? 0 : channels[0].length;
    final target = _ducked ? _duckGainLin : 1.0;
    final coeff = _ducked ? _attackCoeff : _releaseCoeff;

    for (var f = 0; f < frames; f++) {
      _gain = target + coeff * (_gain - target);
      for (final ch in channels) {
        ch[f] *= _gain;
      }
    }

    final Uint8List out = PcmFloat.interleave(channels, chunk.format);
    return chunk.copyWith(pcm: out);
  }

  @override
  void dispose() {
    _gain = 1.0;
    _ducked = false;
  }
}

/// Couples a voice-bus [EnergyVad] to a music-bus [AutoDucker]: feed the music
/// chunk and the concurrent voice chunk, and the music comes back ducked exactly
/// when the voice is active. This is the whole "VAD auto-ducking (sidechain on
/// the music bus)" feature in one deterministic, testable unit.
class SidechainDucker {
  final EnergyVad vad;
  final AutoDucker ducker;

  SidechainDucker({EnergyVad? vad, AutoDucker? ducker})
      : vad = vad ?? EnergyVad(),
        ducker = ducker ?? AutoDucker();

  /// Most recent voice-activity decision (after [process]).
  VadResult? lastVoice;

  /// Duck [music] according to whether [voice] currently carries speech.
  PcmChunk process(PcmChunk music, PcmChunk voice) {
    final v = vad.process(voice);
    lastVoice = v;
    ducker.setDucked(v.isSpeech);
    return ducker.process(music);
  }
}
