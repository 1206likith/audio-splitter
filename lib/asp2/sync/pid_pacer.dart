import 'dart:math' as math;

/// Closed-loop playout pacing for Phase 2.
///
/// Each client drifts against the host clock for reasons the host cannot predict
/// (crystal skew, scheduler jitter, thermal throttling). PTP-lite measures the
/// drift; the [PidPacer] *corrects* it by nudging the client's playout rate a
/// fraction up or down so the buffer converges to its target depth without an
/// audible pitch jump. The [AdaptiveJitterBuffer] sizes that target from the
/// observed jitter so a noisy link gets more slack and a clean one gets less
/// latency.

/// PID gain set. Transports differ wildly in their drift dynamics, so the plan
/// tunes gains per transport: LAN is stiff and low-latency, WAN is sloppier,
/// Bluetooth is slow and lossy and needs gentle correction to avoid pumping.
class PidGains {
  final double kp;
  final double ki;
  final double kd;

  /// Hard cap on the rate correction magnitude (e.g. 0.04 ⇒ ±4%). Beyond a few
  /// percent the pitch shift becomes audible, so the controller saturates here
  /// and the >500 ms case is handled by a catch-up stream instead.
  final double maxAdjust;

  const PidGains({
    required this.kp,
    required this.ki,
    required this.kd,
    this.maxAdjust = 0.04,
  });

  /// Stiff and responsive — LAN drift is small and feedback is fast.
  static const lan = PidGains(kp: 0.6, ki: 0.05, kd: 0.10, maxAdjust: 0.04);

  /// Softer — WAN RTT is higher and jitterier, so damp harder to stay stable.
  static const wan = PidGains(kp: 0.35, ki: 0.02, kd: 0.20, maxAdjust: 0.03);

  /// Gentle — Bluetooth has large, bursty buffers; aggressive correction pumps.
  static const bluetooth =
      PidGains(kp: 0.20, ki: 0.01, kd: 0.05, maxAdjust: 0.02);
}

/// A per-client PID controller whose process variable is **clock drift** (the
/// client running ahead of or behind the host) and whose output is a **playout
/// rate multiplier** centered on 1.0.
///
/// Sign convention matches [ClientSyncReport.driftUs]: positive drift ⇒ client
/// ahead ⇒ must slow down ⇒ multiplier < 1.0.
class PidPacer {
  PidPacer({this.gains = PidGains.lan});

  PidGains gains;

  double _integral = 0;
  double _lastErrorUs = 0;
  bool _hasLast = false;

  /// Maps the PID sum (in µs-of-error units) to a fractional rate trim.
  static const double _outputScale = 1e-6;

  /// When a client falls more than this far behind, a rate nudge can't catch up
  /// in reasonable time — the host should open a 1.5× catch-up unicast instead.
  static const int catchUpThresholdUs = 500 * 1000;

  /// The catch-up playback rate used while a laggard drains its backlog.
  static const double catchUpRate = 1.5;

  /// Feed the latest [driftUs] (positive ⇒ ahead) observed [dtSeconds] after the
  /// previous update. Returns the playout rate multiplier to apply (≈1.0).
  double update(int driftUs, double dtSeconds) {
    // We want drift → 0. Error is the negative of drift so positive error means
    // "speed up", negative means "slow down".
    final error = -driftUs.toDouble();
    final dt = dtSeconds <= 0 ? 1e-3 : dtSeconds;

    final derivative = _hasLast ? (error - _lastErrorUs) / dt : 0.0;
    _lastErrorUs = error;
    _hasLast = true;

    // PID output lives in microseconds-of-error space; this scale maps it to a
    // small fractional rate trim (so a few percent of correction comes from a
    // realistic tens-of-ms error under the LAN gains).
    double rawWith(double integral) =>
        (gains.kp * error + gains.ki * integral + gains.kd * derivative) *
        _outputScale;

    // Conditional anti-windup: tentatively integrate, but only *keep* the new
    // integral if the output isn't saturated. Freezing the integral while
    // saturated is what stops classic windup overshoot when a client starts far
    // out of sync and the rate trim is pinned at maxAdjust for many steps.
    final tentativeIntegral = _integral + error * dt;
    var raw = rawWith(tentativeIntegral);
    if (raw.abs() <= gains.maxAdjust) {
      _integral = tentativeIntegral;
    } else {
      raw = rawWith(_integral);
    }

    final trim = raw.clamp(-gains.maxAdjust, gains.maxAdjust);
    return 1.0 + trim;
  }

  /// True when [driftUs] is so far behind that pacing alone won't recover it.
  bool needsCatchUp(int driftUs) => driftUs < -catchUpThresholdUs;

  /// Reset controller state (transport change, reseat, large step correction).
  void reset() {
    _integral = 0;
    _lastErrorUs = 0;
    _hasLast = false;
  }
}

/// Sizes the playout buffer from observed jitter: `target = max(2·σ, floor)`,
/// recomputed on a fixed cadence (plan: every 500 ms) so it tracks changing
/// network conditions without thrashing on every packet.
class AdaptiveJitterBuffer {
  AdaptiveJitterBuffer({
    this.floorMs = 20,
    this.ceilingMs = 500,
    this.sigmaMultiplier = 2.0,
    this.resizeInterval = const Duration(milliseconds: 500),
  })  : assert(floorMs > 0),
        assert(ceilingMs >= floorMs),
        _targetMs = floorMs;

  /// Minimum depth — never go below this even on a pristine link (plan: 20 ms).
  final int floorMs;

  /// Safety cap so a pathological link can't balloon latency unboundedly.
  final int ceilingMs;

  /// How many standard deviations of headroom to hold (plan: 2).
  final double sigmaMultiplier;

  /// How often [maybeResize] actually recomputes the target.
  final Duration resizeInterval;

  final List<double> _jitterSamplesMs = [];
  int _targetMs;
  int _lastResizeMs = 0;

  /// Current target buffer depth (ms).
  int get targetDepthMs => _targetMs;

  /// Record one inter-arrival jitter observation (ms).
  void observeJitter(double jitterMs) {
    _jitterSamplesMs.add(jitterMs.abs());
    // Bound memory; a couple seconds of history at typical frame rates is ample.
    if (_jitterSamplesMs.length > 256) _jitterSamplesMs.removeAt(0);
  }

  /// Recompute the target if [nowMs] is at least [resizeInterval] past the last
  /// resize. Returns true when the target actually changed. Pass a monotonic
  /// clock in milliseconds (injected so this is deterministic in tests).
  bool maybeResize(int nowMs) {
    if (_jitterSamplesMs.isEmpty) return false;
    if (_lastResizeMs != 0 &&
        nowMs - _lastResizeMs < resizeInterval.inMilliseconds) {
      return false;
    }
    _lastResizeMs = nowMs;

    final stdDev = _stdDev(_jitterSamplesMs);
    final desired = (sigmaMultiplier * stdDev)
        .clamp(floorMs.toDouble(), ceilingMs.toDouble())
        .round();
    // Each resize window starts fresh so the buffer tracks *recent* conditions.
    _jitterSamplesMs.clear();

    final changed = desired != _targetMs;
    _targetMs = desired;
    return changed;
  }

  static double _stdDev(List<double> xs) {
    if (xs.length < 2) return 0;
    final mean = xs.reduce((a, b) => a + b) / xs.length;
    final variance =
        xs.map((x) => (x - mean) * (x - mean)).reduce((a, b) => a + b) /
            xs.length;
    return math.sqrt(variance);
  }
}
