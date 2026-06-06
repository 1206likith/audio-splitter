import '../party/beat_grid.dart';
import 'light_controller.dart';

/// Phone-flashlight strobe — the **no-extra-hardware** light backend: every
/// client's camera torch flashes on the beat, turning a crowd of phones into a
/// strobe wall. The torch toggle is a platform plugin call (deferred), but the
/// *when-to-flash* logic is pure and beat-grid-driven, so it's fully testable.
class FlashlightStrobe implements LightController {
  @override
  final String id;

  /// Whether the real torch is driven. Off here (no plugin in sandbox); the
  /// strobe decisions are still recorded so the behaviour is testable.
  final bool simulate;

  /// On/off torch states actually emitted (for the simulate path / tests).
  final List<bool> states = [];

  bool _torchOn = false;
  bool _open = false;

  FlashlightStrobe({this.id = 'flashlight', this.simulate = true});

  /// Real torch control requires a camera plugin + permission; unavailable here.
  static bool get isAvailable => false;

  bool get torchOn => _torchOn;

  @override
  Future<bool> open() async {
    _open = true;
    return simulate; // real torch path returns false (deferred)
  }

  /// Decide torch on/off for a beat grid at host time [tsUs]: torch is ON for
  /// the first [dutyCycle] fraction of each beat (a flash on the beat, dark
  /// before the next). Pure given the grid.
  bool shouldFlash(BeatGrid grid, int tsUs, {double dutyCycle = 0.5}) =>
      grid.phaseAt(tsUs) < dutyCycle.clamp(0.0, 1.0);

  /// Drive the torch from a beat grid at [tsUs]; records the resulting state.
  void strobeTo(BeatGrid grid, int tsUs, {double dutyCycle = 0.5}) {
    final on = shouldFlash(grid, tsUs, dutyCycle: dutyCycle);
    _torchOn = on;
    states.add(on);
    // Real: CameraTorch.setTorch(on) — deferred [needs-hardware].
  }

  /// A [LightFrame]'s strobe field also maps here: any non-zero strobe ⇒ flashes.
  @override
  void send(LightFrame frame) {
    final on = frame.strobeHz > 0 || frame.masterDimmer > 0.5;
    _torchOn = on;
    states.add(on);
  }

  bool get isOpen => _open;

  @override
  Future<void> close() async {
    _torchOn = false;
    _open = false;
  }
}
