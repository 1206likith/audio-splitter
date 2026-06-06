import 'dart:math' as math;

import '../party/beat_grid.dart';

/// An 8-bit-per-channel RGB colour — the common currency for every light backend
/// (DMX fixtures, Hue, LIFX, phone flashlight, screen-ambient). Pure value type.
class RgbColor {
  final int r;
  final int g;
  final int b;

  const RgbColor(this.r, this.g, this.b);

  static const RgbColor black = RgbColor(0, 0, 0);
  static const RgbColor white = RgbColor(255, 255, 255);

  /// Build from HSV (`h` in degrees `[0,360)`, `s`/`v` in `[0,1]`). Used by the
  /// beat program to sweep hue per bar.
  factory RgbColor.fromHsv(double h, double s, double v) {
    h = h % 360;
    if (h < 0) h += 360;
    final c = v * s;
    final x = c * (1 - (((h / 60) % 2) - 1).abs());
    final m = v - c;
    double rr = 0, gg = 0, bb = 0;
    if (h < 60) {
      rr = c;
      gg = x;
    } else if (h < 120) {
      rr = x;
      gg = c;
    } else if (h < 180) {
      gg = c;
      bb = x;
    } else if (h < 240) {
      gg = x;
      bb = c;
    } else if (h < 300) {
      rr = x;
      bb = c;
    } else {
      rr = c;
      bb = x;
    }
    return RgbColor(
      ((rr + m) * 255).round().clamp(0, 255),
      ((gg + m) * 255).round().clamp(0, 255),
      ((bb + m) * 255).round().clamp(0, 255),
    );
  }

  /// Scale brightness by [factor] (`[0,1]`), e.g. to dim on a beat envelope.
  RgbColor dim(double factor) {
    final f = factor.clamp(0.0, 1.0);
    return RgbColor(
      (r * f).round().clamp(0, 255),
      (g * f).round().clamp(0, 255),
      (b * f).round().clamp(0, 255),
    );
  }

  /// Linear interpolate toward [other] by [t] (`[0,1]`).
  RgbColor lerp(RgbColor other, double t) {
    final u = t.clamp(0.0, 1.0);
    return RgbColor(
      (r + (other.r - r) * u).round().clamp(0, 255),
      (g + (other.g - g) * u).round().clamp(0, 255),
      (b + (other.b - b) * u).round().clamp(0, 255),
    );
  }

  Map<String, dynamic> toJson() => {'r': r, 'g': g, 'b': b};

  factory RgbColor.fromJson(Map<String, dynamic> json) => RgbColor(
        (json['r'] as num).toInt(),
        (json['g'] as num).toInt(),
        (json['b'] as num).toInt(),
      );

  @override
  bool operator ==(Object other) =>
      other is RgbColor && other.r == r && other.g == g && other.b == b;

  @override
  int get hashCode => Object.hash(r, g, b);

  @override
  String toString() => 'RgbColor($r,$g,$b)';
}

/// The colour of one addressable fixture in a [LightFrame].
class FixtureColor {
  final int fixtureId;
  final RgbColor color;

  const FixtureColor(this.fixtureId, this.color);

  @override
  bool operator ==(Object other) =>
      other is FixtureColor &&
      other.fixtureId == fixtureId &&
      other.color == color;

  @override
  int get hashCode => Object.hash(fixtureId, color);

  @override
  String toString() => 'FixtureColor(#$fixtureId, $color)';
}

/// One frame of lighting state: per-fixture colours, a master dimmer, and an
/// optional strobe rate. Every backend renders the same [LightFrame] its own
/// way, so the beat program is backend-agnostic.
class LightFrame {
  final List<FixtureColor> fixtures;

  /// Master intensity `[0,1]` applied on top of fixture colours.
  final double masterDimmer;

  /// Strobe rate in Hz; 0 = no strobe.
  final double strobeHz;

  const LightFrame({
    this.fixtures = const [],
    this.masterDimmer = 1.0,
    this.strobeHz = 0.0,
  });

  /// A single-colour frame across [fixtureCount] fixtures.
  factory LightFrame.solid(RgbColor color,
          {int fixtureCount = 1,
          double masterDimmer = 1.0,
          double strobeHz = 0.0}) =>
      LightFrame(
        fixtures: [
          for (var i = 0; i < fixtureCount; i++) FixtureColor(i, color),
        ],
        masterDimmer: masterDimmer,
        strobeHz: strobeHz,
      );

  RgbColor colorOf(int fixtureId) {
    for (final f in fixtures) {
      if (f.fixtureId == fixtureId) return f.color;
    }
    return RgbColor.black;
  }

  @override
  String toString() =>
      'LightFrame(${fixtures.length} fixtures, dim=$masterDimmer, '
      'strobe=${strobeHz}Hz)';
}

/// A lighting backend: DMX/Art-Net, Hue, LIFX, phone flashlight, screen-ambient.
/// Mirrors [IAudioSink]'s shape — open/send/close — so the party host treats
/// lights like any other sink.
abstract class LightController {
  String get id;

  /// Bring the backend up. Returns false on failure (e.g. hardware absent).
  Future<bool> open();

  /// Render one frame. Must never throw; tolerate being called before [open].
  void send(LightFrame frame);

  Future<void> close();
}

/// The always-available simulated backend: records every frame so the beat
/// program / gate can assert on what *would* have been sent, with no hardware.
/// Same role as the simulated sinks/transports in earlier phases.
class SimulatedLightController implements LightController {
  @override
  final String id;

  final List<LightFrame> frames = [];
  bool _open = false;

  SimulatedLightController({this.id = 'sim-light'});

  bool get isOpen => _open;
  int get frameCount => frames.length;
  LightFrame? get lastFrame => frames.isEmpty ? null : frames.last;

  @override
  Future<bool> open() async {
    _open = true;
    return true;
  }

  @override
  void send(LightFrame frame) => frames.add(frame);

  @override
  Future<void> close() async => _open = false;
}

/// Turns a [BeatGrid] + crowd energy into a [LightFrame] — the engine behind
/// "lights synced to the beat". Pure: [frameAt] is a function of `(tsUs,
/// energy)`, so the same beat grid yields the same light show every run and a
/// client can render it predictively from the grid alone.
///
/// Behaviour: brightness pulses with each beat (a sharp attack on the beat that
/// decays before the next), hue sweeps once per bar, and high crowd energy adds
/// a strobe.
class BeatLightProgram {
  final BeatGrid grid;
  final int fixtureCount;

  /// Crowd energy above which the program strobes.
  final double strobeThreshold;

  /// Strobe rate at full energy (Hz).
  final double maxStrobeHz;

  /// Degrees of hue advanced per bar.
  final double huePerBar;

  const BeatLightProgram({
    required this.grid,
    this.fixtureCount = 4,
    this.strobeThreshold = 0.7,
    this.maxStrobeHz = 12.0,
    this.huePerBar = 90.0,
  });

  /// The light frame at host time [tsUs] given crowd [energy] `[0,1]`.
  LightFrame frameAt(int tsUs, {double energy = 0.5}) {
    final phase = grid.phaseAt(tsUs); // 0 on the beat → 1 before the next
    // Sharp attack on the beat, exponential-ish decay across the beat.
    final pulse = math.pow(1.0 - phase, 2.0).toDouble();
    final brightness = (0.25 + 0.75 * pulse).clamp(0.0, 1.0);

    final beatIndex = grid.beatIndexAt(tsUs);
    final bar = beatIndex / grid.beatsPerBar;
    final baseHue = (bar * huePerBar) % 360;

    final fixtures = <FixtureColor>[];
    for (var i = 0; i < fixtureCount; i++) {
      // Spread fixtures across the colour wheel so the rig looks alive.
      final hue = (baseHue + i * (360.0 / fixtureCount)) % 360;
      final color = RgbColor.fromHsv(hue, 1.0, 1.0).dim(brightness);
      fixtures.add(FixtureColor(i, color));
    }

    final strobeHz =
        energy >= strobeThreshold ? maxStrobeHz * energy.clamp(0.0, 1.0) : 0.0;

    return LightFrame(
      fixtures: fixtures,
      masterDimmer: (0.5 + 0.5 * energy).clamp(0.0, 1.0),
      strobeHz: strobeHz,
    );
  }
}
