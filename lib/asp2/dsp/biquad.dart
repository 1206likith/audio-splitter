import 'dart:math' as math;

/// A second-order IIR (biquad) filter section in Direct Form I, with the
/// Robert Bristow-Johnson "Audio EQ Cookbook" coefficient designers.
///
/// One [Biquad] holds the coefficients (shared across channels) but **not** the
/// delay state — state is per channel and lives in [BiquadState], so a stereo
/// EQ band is one [Biquad] plus N [BiquadState]s.
class Biquad {
  // Normalized coefficients (a0 divided out).
  final double b0, b1, b2, a1, a2;

  const Biquad._(this.b0, this.b1, this.b2, this.a1, this.a2);

  /// Identity (pass-through) section.
  static const Biquad identity = Biquad._(1, 0, 0, 0, 0);

  static Biquad _normalize(
      double b0, double b1, double b2, double a0, double a1, double a2) {
    return Biquad._(b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0);
  }

  /// Peaking EQ: boost/cut [gainDb] dB around [freqHz] with bandwidth set by [q].
  factory Biquad.peaking({
    required double freqHz,
    required double sampleRate,
    required double q,
    required double gainDb,
  }) {
    final a = math.pow(10, gainDb / 40).toDouble();
    final w0 = 2 * math.pi * freqHz / sampleRate;
    final cosW0 = math.cos(w0);
    final alpha = math.sin(w0) / (2 * q);
    return _normalize(
      1 + alpha * a,
      -2 * cosW0,
      1 - alpha * a,
      1 + alpha / a,
      -2 * cosW0,
      1 - alpha / a,
    );
  }

  /// Low-shelf: [gainDb] dB applied below [freqHz].
  factory Biquad.lowShelf({
    required double freqHz,
    required double sampleRate,
    required double q,
    required double gainDb,
  }) {
    final a = math.pow(10, gainDb / 40).toDouble();
    final w0 = 2 * math.pi * freqHz / sampleRate;
    final cosW0 = math.cos(w0);
    final alpha = math.sin(w0) / (2 * q);
    final twoSqrtAAlpha = 2 * math.sqrt(a) * alpha;
    return _normalize(
      a * ((a + 1) - (a - 1) * cosW0 + twoSqrtAAlpha),
      2 * a * ((a - 1) - (a + 1) * cosW0),
      a * ((a + 1) - (a - 1) * cosW0 - twoSqrtAAlpha),
      (a + 1) + (a - 1) * cosW0 + twoSqrtAAlpha,
      -2 * ((a - 1) + (a + 1) * cosW0),
      (a + 1) + (a - 1) * cosW0 - twoSqrtAAlpha,
    );
  }

  /// High-shelf: [gainDb] dB applied above [freqHz].
  factory Biquad.highShelf({
    required double freqHz,
    required double sampleRate,
    required double q,
    required double gainDb,
  }) {
    final a = math.pow(10, gainDb / 40).toDouble();
    final w0 = 2 * math.pi * freqHz / sampleRate;
    final cosW0 = math.cos(w0);
    final alpha = math.sin(w0) / (2 * q);
    final twoSqrtAAlpha = 2 * math.sqrt(a) * alpha;
    return _normalize(
      a * ((a + 1) + (a - 1) * cosW0 + twoSqrtAAlpha),
      -2 * a * ((a - 1) + (a + 1) * cosW0),
      a * ((a + 1) + (a - 1) * cosW0 - twoSqrtAAlpha),
      (a + 1) - (a - 1) * cosW0 + twoSqrtAAlpha,
      2 * ((a - 1) - (a + 1) * cosW0),
      (a + 1) - (a - 1) * cosW0 - twoSqrtAAlpha,
    );
  }

  /// Process one sample given a channel's running [state] (mutated in place).
  double process(double x, BiquadState state) {
    final y =
        b0 * x + b1 * state.x1 + b2 * state.x2 - a1 * state.y1 - a2 * state.y2;
    state.x2 = state.x1;
    state.x1 = x;
    state.y2 = state.y1;
    state.y1 = y;
    return y;
  }
}

/// Per-channel delay-line state for a [Biquad] (Direct Form I: two input and
/// two output history taps).
class BiquadState {
  double x1 = 0, x2 = 0, y1 = 0, y2 = 0;

  void reset() {
    x1 = x2 = y1 = y2 = 0;
  }
}
