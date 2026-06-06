import 'light_controller.dart';

/// Screen-ambient colour — turns each client's whole screen into a soft area
/// light that breathes with the music. Pure mapping from crowd/audio energy (and
/// an optional hue drift) to an [RgbColor]; the "backend" is just painting the
/// screen, so there's nothing hardware-bound here.
class AmbientColor {
  AmbientColor._();

  /// Map [energy] `[0,1]` to a colour: cool blue when calm, sweeping through
  /// magenta to hot orange/white as energy climbs, brightening with energy.
  /// [hueDrift] (degrees) lets a caller slowly rotate the palette over time
  /// (e.g. per bar from a beat grid).
  static RgbColor forEnergy(double energy, {double hueDrift = 0.0}) {
    final e = energy.clamp(0.0, 1.0);
    // 220° (blue) at calm → 20° (orange) at peak.
    final hue = (220.0 - 200.0 * e + hueDrift) % 360;
    final sat = (1.0 - 0.3 * e).clamp(0.0, 1.0); // wash toward white when hot
    final value = (0.35 + 0.65 * e).clamp(0.0, 1.0);
    return RgbColor.fromHsv(hue < 0 ? hue + 360 : hue, sat, value);
  }

  /// A full-screen [LightFrame] (single fixture) for [energy].
  static LightFrame frameForEnergy(double energy, {double hueDrift = 0.0}) =>
      LightFrame.solid(forEnergy(energy, hueDrift: hueDrift));
}
