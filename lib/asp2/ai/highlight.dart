import '../party/reactions.dart';

/// A detected highlight: the time window of a peak crowd moment, ready to be
/// auto-clipped (export the recorded audio/video between these timestamps). The
/// window is padded with pre/post roll so the clip starts a beat before the
/// energy spikes and lingers after it settles.
class HighlightClip {
  final int startTsUs;
  final int endTsUs;

  /// Peak crowd energy `[0,1]` reached during the moment.
  final double peakEnergy;

  const HighlightClip({
    required this.startTsUs,
    required this.endTsUs,
    required this.peakEnergy,
  });

  int get durationUs => endTsUs - startTsUs;

  @override
  String toString() =>
      'HighlightClip($startTsUs–${endTsUs}us, peak=${(peakEnergy * 100).round()}%)';
}

/// Watches a crowd-energy signal (the Phase 5 [EnergyMeter], extended here) and
/// emits a [HighlightClip] each time energy spikes into "moment" territory and
/// then settles. Hysteresis (separate enter/exit thresholds) plus a minimum
/// duration keeps it from firing on every little cheer; pre/post roll pads the
/// clip so it captures the build-up and tail.
///
/// Deterministic: drive it by feeding `(tsUs, energy)` samples in order (e.g.
/// once per control tick); a replay of the same energy curve yields the same
/// clips.
class HighlightDetector {
  /// Energy at/above which a highlight window opens.
  final double enterThreshold;

  /// Energy at/below which an open window closes.
  final double exitThreshold;

  /// Discard windows shorter than this (microseconds).
  final int minDurationUs;

  /// Padding added before the spike and after it settles (microseconds).
  final int preRollUs;
  final int postRollUs;

  bool _open = false;
  int _openTsUs = 0;
  int _lastAboveTsUs = 0;
  double _peak = 0.0;

  HighlightDetector({
    this.enterThreshold = 0.8,
    this.exitThreshold = 0.5,
    this.minDurationUs = 2000000, // 2 s
    this.preRollUs = 3000000, // 3 s
    this.postRollUs = 2000000, // 2 s
  }) : assert(exitThreshold <= enterThreshold,
            'exitThreshold must not exceed enterThreshold');

  /// Whether a highlight window is currently open.
  bool get isOpen => _open;

  /// Feed one energy sample. Returns a [HighlightClip] when a window *closes*
  /// (and meets the minimum duration), otherwise null.
  HighlightClip? observe(int tsUs, double energy) {
    if (!_open) {
      if (energy >= enterThreshold) {
        _open = true;
        _openTsUs = tsUs;
        _lastAboveTsUs = tsUs;
        _peak = energy;
      }
      return null;
    }

    // Window is open.
    if (energy > _peak) _peak = energy;
    if (energy > exitThreshold) {
      _lastAboveTsUs = tsUs;
      return null;
    }

    // Energy fell below the exit threshold ⇒ close the window.
    _open = false;
    final durationUs = _lastAboveTsUs - _openTsUs;
    if (durationUs < minDurationUs) return null;
    return HighlightClip(
      startTsUs: _openTsUs - preRollUs,
      endTsUs: _lastAboveTsUs + postRollUs,
      peakEnergy: _peak,
    );
  }

  /// Convenience: sample an [EnergyMeter] at [nowUs] and feed it in.
  HighlightClip? observeMeter(EnergyMeter meter, int nowUs) =>
      observe(nowUs, meter.energyAt(nowUs));
}
