import 'dart:typed_data';

/// Low-level summing primitives for the zone mixer.
///
/// Everything here operates in the normalized float domain (per-channel
/// `Float64List`s, same convention as the DSP effects) and is deliberately
/// stateless — a pure function of its inputs, so it is trivial to test and the
/// stateful, filter-carrying parts live in [ZoneMixer]/the effect chain.
///
/// Two real-world hazards it handles up front:
///  * **Ragged lengths** — if one source's chunk is a few frames short (a late
///    capture, a source that just started), the mix is zero-extended to the
///    longest contributor rather than truncated, so a hiccup in one source can
///    never shorten or glitch the whole zone.
///  * **Channel mismatch** — a mono mic feeding a stereo zone, or a stereo file
///    feeding a mono monitor. [adaptChannels] up/down-mixes so every contributor
///    lands in the zone's channel count before summing.
class Mixer {
  Mixer._();

  /// Adapt [channels] (one `Float64List` per channel) to [targetChannels]:
  ///  * equal count → returned unchanged;
  ///  * 1 → N → the mono buffer is fanned out to every output channel;
  ///  * N → 1 → channels are averaged down to mono;
  ///  * otherwise → take the first [targetChannels], zero-filling any shortfall.
  static List<Float64List> adaptChannels(
      List<Float64List> channels, int targetChannels) {
    final srcCount = channels.length;
    if (srcCount == targetChannels) return channels;
    if (srcCount == 0) {
      return [for (var c = 0; c < targetChannels; c++) Float64List(0)];
    }

    final frames = channels[0].length;
    if (srcCount == 1) {
      // Mono → N: share the same data reference per output channel. Callers
      // here only ever read these, so aliasing is safe and avoids a copy.
      return [for (var c = 0; c < targetChannels; c++) channels[0]];
    }
    if (targetChannels == 1) {
      // N → mono: average.
      final mono = Float64List(frames);
      for (var f = 0; f < frames; f++) {
        var sum = 0.0;
        for (final ch in channels) {
          sum += f < ch.length ? ch[f] : 0.0;
        }
        mono[f] = sum / srcCount;
      }
      return [mono];
    }
    // Mismatched multi-channel: map by index, pad missing channels with silence.
    return [
      for (var c = 0; c < targetChannels; c++)
        c < srcCount ? channels[c] : Float64List(frames),
    ];
  }

  /// Weighted sum of [contributions] into a fresh [channels]-wide buffer.
  ///
  /// Each entry of [contributions] is a per-channel buffer already adapted to
  /// [channels] wide (see [adaptChannels]); [gains] is the matching linear gain
  /// per contribution. The output length is the longest contribution; shorter
  /// ones contribute silence past their end.
  ///
  /// No normalization or limiting happens here — summed peaks can exceed ±1.0
  /// by design; the zone's post-mix limiter is what guarantees the ceiling.
  static List<Float64List> sum(
      List<List<Float64List>> contributions, List<double> gains, int channels) {
    assert(contributions.length == gains.length,
        'each contribution needs exactly one gain');

    var frames = 0;
    for (final contrib in contributions) {
      for (final ch in contrib) {
        if (ch.length > frames) frames = ch.length;
      }
    }

    final out = [for (var c = 0; c < channels; c++) Float64List(frames)];
    for (var i = 0; i < contributions.length; i++) {
      final contrib = contributions[i];
      final g = gains[i];
      if (g == 0.0) continue;
      for (var c = 0; c < channels && c < contrib.length; c++) {
        final src = contrib[c];
        final dst = out[c];
        final n = src.length;
        for (var f = 0; f < n; f++) {
          dst[f] += src[f] * g;
        }
      }
    }
    return out;
  }
}
