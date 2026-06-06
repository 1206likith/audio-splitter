import '../../core/contracts/audio_format.dart';
import '../../core/contracts/i_effect.dart';
import '../../core/pipeline/audio_chunk.dart';
import 'compressor.dart';
import 'limiter.dart';
import 'parametric_eq.dart';
import 'rnnoise_denoiser.dart';

/// Runs a list of [IEffect]s in series — the composite DSP node a zone applies
/// post-mix (plan: "EQ → compressor → limiter chain per zone"). Order matters
/// and is the caller's responsibility; the limiter belongs last so it catches
/// any overshoot the upstream stages introduced.
class EffectChain implements IEffect {
  @override
  final String id;

  final List<IEffect> effects;

  EffectChain(this.effects, {this.id = 'effect-chain'});

  @override
  PcmChunk process(PcmChunk chunk) {
    var c = chunk;
    for (final e in effects) {
      c = e.process(c);
    }
    return c;
  }

  @override
  void dispose() {
    for (final e in effects) {
      e.dispose();
    }
  }
}

/// Factory presets for the two Phase 2 reference chains.
class DspPresets {
  DspPresets._();

  /// Voice clarity: optional neural denoise → clarity EQ → gentle leveling →
  /// brick-wall safety limiter. If librnnoise is unavailable the denoise stage
  /// is simply omitted (the rest still runs in pure Dart). This is the chain the
  /// voice A/B compares against raw v1 audio.
  static EffectChain voiceClarity(
      {AudioFormat format = AudioFormat.voiceMono}) {
    final denoiser = RnnoiseDenoiser.tryCreate();
    return EffectChain(
      [
        if (denoiser != null) denoiser,
        ParametricEq.voiceClarity(format: format),
        Compressor(
          format: format,
          thresholdDb: -20,
          ratio: 3.0,
          makeupDb: 4.0,
          attackMs: 4,
          releaseMs: 90,
          id: 'comp-voice',
        ),
        Limiter(format: format, ceilingDb: -1.0, id: 'limiter-voice'),
      ],
      id: 'chain-voice-clarity',
    );
  }

  /// Music mastering: per-zone tone EQ → glue compression → -1 dBTP limiter.
  static EffectChain musicMaster({AudioFormat format = AudioFormat.cdStereo}) {
    return EffectChain(
      [
        ParametricEq(
          format: format,
          id: 'eq-music',
          bands: const [
            EqBand(type: EqBandType.lowShelf, freqHz: 100, gainDb: 1.5),
            EqBand(type: EqBandType.peaking, freqHz: 2500, q: 0.8, gainDb: 1.0),
            EqBand(type: EqBandType.highShelf, freqHz: 10000, gainDb: 2.0),
          ],
        ),
        Compressor(
          format: format,
          thresholdDb: -12,
          ratio: 2.0,
          kneeDb: 8,
          makeupDb: 1.5,
          id: 'comp-music',
        ),
        Limiter(format: format, ceilingDb: -1.0, id: 'limiter-music'),
      ],
      id: 'chain-music-master',
    );
  }
}
