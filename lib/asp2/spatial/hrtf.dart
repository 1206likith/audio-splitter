import 'dart:math' as math;
import 'dart:typed_data';

import '../../core/contracts/audio_format.dart';
import '../../core/pipeline/audio_chunk.dart';
import '../dsp/pcm_float.dart';
import 'ambisonic.dart';

/// Renders a mono point source to binaural (headphone) stereo for a given
/// direction. The always-available implementation is the lightweight
/// [BinauralPanner] (ITD + ILD, no measured HRTF database); a true
/// convolution-HRTF renderer (Steam Audio / Resonance Audio via FFI) is
/// [needs-FFI] and deferred ([SteamAudioHrtf]).
abstract class SpatialRenderer {
  /// Render [mono] from direction [dir] into `[left, right]` float channels.
  List<Float64List> renderBinaural(Float64List mono, SphericalDir dir);

  bool get isAvailable;
}

/// **Pure-Dart binaural panner** — the live, no-binary spatializer. It models
/// the two robust localization cues without an HRTF dataset:
///
///  * **ITD** (interaural *time* difference) — a source off to one side reaches
///    the near ear first. Woodworth's spherical-head formula sets the delay
///    (≈0.66 ms at the side), applied to the far ear.
///  * **ILD** (interaural *level* difference) — the head shadows the far ear, so
///    it's quieter; modelled as a broadband attenuation that grows with how far
///    off-centre the source is.
///
/// It is deterministic and exact at the cardinal directions (a hard-left source
/// is louder and earlier in the left channel), which is what the spatial gate
/// checks. The frequency-dependent pinna colouration a real HRTF adds is the
/// [SteamAudioHrtf] upgrade.
class BinauralPanner implements SpatialRenderer {
  /// Radius of the modelled head, metres (average ≈ 8.75 cm).
  final double headRadius;

  /// Speed of sound, m/s.
  final double speedOfSound;

  /// How strongly the head shadows the far ear at full side incidence (0..1).
  final double shadowStrength;

  final int sampleRate;

  const BinauralPanner({
    this.headRadius = 0.0875,
    this.speedOfSound = 343.0,
    this.shadowStrength = 0.6,
    this.sampleRate = 48000,
  });

  /// Interaural time difference for [dir], seconds. Positive ⇒ the right (far)
  /// ear is delayed (source is to the left). Woodworth: ITD = (r/c)(θ + sinθ),
  /// scaled by cos(elevation) since overhead sources have no left/right offset.
  double itdSeconds(SphericalDir dir) {
    // Fold azimuth to the front hemisphere magnitude for the formula, keep sign.
    var az = dir.azimuthRad;
    final sign = az >= 0 ? 1.0 : -1.0;
    var mag = az.abs();
    if (mag > math.pi / 2) mag = math.pi - mag; // mirror rear to front
    final itd = (headRadius / speedOfSound) * (mag + math.sin(mag));
    return sign * itd * math.cos(dir.elevationRad);
  }

  @override
  List<Float64List> renderBinaural(Float64List mono, SphericalDir dir) {
    final n = mono.length;
    final left = Float64List(n);
    final right = Float64List(n);

    final itd = itdSeconds(dir);
    final delaySamples = (itd.abs() * sampleRate).round();
    final leftLeads = itd >= 0; // source to the left ⇒ left is the near ear

    // ILD: the far ear is attenuated; near ear is unity.
    final shadow = shadowStrength *
        math.sin(dir.azimuthRad).abs() *
        math.cos(dir.elevationRad);
    final farGain = (1.0 - shadow).clamp(0.0, 1.0);

    for (var i = 0; i < n; i++) {
      final s = mono[i];
      if (leftLeads) {
        left[i] = s; // near ear, no delay
        if (i >= delaySamples) right[i] = mono[i - delaySamples] * farGain;
      } else {
        right[i] = s;
        if (i >= delaySamples) left[i] = mono[i - delaySamples] * farGain;
      }
    }
    return [left, right];
  }

  /// Render a [PcmChunk] (collapsed to mono) as a binaural stereo chunk.
  PcmChunk renderChunk(PcmChunk chunk, SphericalDir dir) {
    final channels = PcmFloat.deinterleave(chunk.pcm, chunk.format);
    if (channels.isEmpty) {
      return chunk.copyWith(format: AudioFormat.cdStereo);
    }
    final frames = channels[0].length;
    final mono = Float64List(frames);
    for (var f = 0; f < frames; f++) {
      var sum = 0.0;
      for (final ch in channels) {
        sum += f < ch.length ? ch[f] : 0.0;
      }
      mono[f] = sum / channels.length;
    }
    final stereo = renderBinaural(mono, dir);
    return PcmChunk(
      pcm: PcmFloat.interleave(stereo, AudioFormat.cdStereo),
      presentationTsUs: chunk.presentationTsUs,
      format: AudioFormat.cdStereo,
    );
  }

  @override
  bool get isAvailable => true;
}

/// **[needs-FFI]** measured-HRTF renderer scaffold (Steam Audio's free SDK, or
/// Google Resonance Audio). A real HRTF convolves the source with direction-
/// specific left/right impulse responses for true elevation + front/back cues —
/// that needs the native SDK + an HRIR dataset vendored per platform, so it is
/// deferred behind the same load-probe contract as Opus/RNNoise. The pure
/// [BinauralPanner] is the live spatializer until the binary lands.
class SteamAudioHrtf implements SpatialRenderer {
  @override
  List<Float64List> renderBinaural(Float64List mono, SphericalDir dir) =>
      throw UnsupportedError('Steam Audio HRTF is not available on this build; '
          'fall back to BinauralPanner.');

  @override
  bool get isAvailable => false;
}
