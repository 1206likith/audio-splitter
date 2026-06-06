import 'dart:math' as math;

import '../../core/contracts/audio_format.dart';
import '../../core/pipeline/audio_chunk.dart';
import '../dsp/pcm_float.dart';

/// One voice-activity decision for a chunk of audio.
class VadResult {
  /// True when speech is judged present (including the hangover tail).
  final bool isSpeech;

  /// RMS level of the chunk in `[0,1]` (linear), for meters/telemetry.
  final double rms;

  /// Adaptive noise-floor estimate at this point, linear.
  final double noiseFloor;

  /// Timestamp of the chunk, host-clock microseconds.
  final int tsUs;

  const VadResult({
    required this.isSpeech,
    required this.rms,
    required this.noiseFloor,
    required this.tsUs,
  });

  @override
  String toString() =>
      'VadResult(${isSpeech ? "SPEECH" : "silence"}, rms=${rms.toStringAsFixed(4)})';
}

/// **Energy-based voice-activity detector** — the gate that feeds STT
/// segmentation and the sidechain auto-ducker. It tracks an adaptive noise
/// floor (rises fast toward louder ambience, falls slowly so a pause doesn't
/// reset it) and declares speech when the chunk's RMS sits a configurable ratio
/// above that floor. A **hangover** keeps the decision latched through short
/// gaps between words so captions/ducking don't chatter.
///
/// Fully deterministic: every decision is a function of the samples and
/// timestamps passed in (no wall clock), so a replay reproduces the same gating.
class EnergyVad {
  /// How many times above the noise floor the signal must sit to be speech.
  final double triggerRatio;

  /// Absolute floor (linear RMS) below which nothing is ever speech — guards
  /// against the ratio firing on digital silence.
  final double absoluteFloor;

  /// Keep "speech" latched this long after the last over-threshold chunk.
  final int hangoverUs;

  /// Noise-floor adaptation rate when the level is *below* the current floor
  /// (slow decay, 0..1 per chunk).
  final double floorDecay;

  /// Noise-floor adaptation rate when the level is *above* the floor but not
  /// speech (faster rise).
  final double floorRise;

  double _noiseFloor;
  int _lastSpeechTsUs = -1 << 50;

  EnergyVad({
    this.triggerRatio = 3.0,
    this.absoluteFloor = 0.005,
    this.hangoverUs = 300000, // 300 ms
    this.floorDecay = 0.05,
    this.floorRise = 0.2,
    double initialNoiseFloor = 0.01,
  }) : _noiseFloor = initialNoiseFloor;

  double get noiseFloor => _noiseFloor;

  /// RMS of [chunk] in the normalized float domain.
  static double rmsOf(PcmChunk chunk) {
    final channels = PcmFloat.deinterleave(chunk.pcm, chunk.format);
    if (channels.isEmpty) return 0.0;
    final frames = channels[0].length;
    if (frames == 0) return 0.0;
    var sumSq = 0.0;
    var count = 0;
    for (final ch in channels) {
      for (var f = 0; f < ch.length; f++) {
        sumSq += ch[f] * ch[f];
        count++;
      }
    }
    return count == 0 ? 0.0 : math.sqrt(sumSq / count);
  }

  /// Decide voice activity for [chunk] and advance the detector state.
  VadResult process(PcmChunk chunk) {
    final rms = rmsOf(chunk);
    final tsUs = chunk.presentationTsUs;

    final over = rms > _noiseFloor * triggerRatio && rms > absoluteFloor;
    if (over) {
      _lastSpeechTsUs = tsUs;
    } else {
      // Adapt the floor only while not actively speaking.
      final rate = rms > _noiseFloor ? floorRise : floorDecay;
      _noiseFloor += rate * (rms - _noiseFloor);
      if (_noiseFloor < 1e-6) _noiseFloor = 1e-6;
    }

    final inHangover = tsUs - _lastSpeechTsUs <= hangoverUs;
    return VadResult(
      isSpeech: over || inHangover,
      rms: rms,
      noiseFloor: _noiseFloor,
      tsUs: tsUs,
    );
  }

  /// Reset to an initial state (e.g. on a new source).
  void reset({double initialNoiseFloor = 0.01}) {
    _noiseFloor = initialNoiseFloor;
    _lastSpeechTsUs = -1 << 50;
  }

  /// The format this VAD expects; informational (it adapts to any chunk format).
  static const AudioFormat expectedFormat = AudioFormat.voiceMono;
}
