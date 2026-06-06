import 'dart:math' as math;

/// PTP-lite — a lightweight NTP/PTP-style clock-synchronization exchange.
///
/// Phase 2 of the v2 plan. The Phase 0 [ITimeSync] surface fed the wrapped v1
/// [SyncService] a single `(serverTimeMs, rttMs)` sample with no notion of which
/// direction the latency skewed. PTP-lite replaces that with a four-timestamp
/// exchange that separates **clock offset** from **path delay**, so a client can
/// align its clock to the host's even when the network is asymmetric or jittery.
///
/// The exchange (timestamps in **microseconds**, matching ASP-2 `pts_us`):
/// ```
///   client                         host
///     | --- PtpProbe(t1) ---------> |   t2 = host recv
///     |                             |   t3 = host send
///     | <--- PtpResponse(t2,t3) --- |
///   t4 = client recv
/// ```
/// From the four stamps:
///   offset = ((t2 - t1) + (t3 - t4)) / 2     // client→host clock correction
///   rtt    = (t4 - t1) - (t3 - t2)           // round-trip, minus host think time
///   delay  = rtt / 2                         // one-way path delay
///
/// `t1`/`t4` are read on the client clock; `t2`/`t3` on the host clock. The
/// algebra cancels the unknown clock offset out of `rtt` and cancels the path
/// delay out of `offset`, which is the whole point of the four-stamp form.

/// One completed PTP-lite probe: the four timestamps and the quantities derived
/// from them. All times are microseconds.
class PtpSample {
  /// Client send time (client clock).
  final int t1;

  /// Host receive time (host clock).
  final int t2;

  /// Host send time (host clock).
  final int t3;

  /// Client receive time (client clock).
  final int t4;

  const PtpSample({
    required this.t1,
    required this.t2,
    required this.t3,
    required this.t4,
  });

  /// Estimated offset to **add** to a client-clock reading to obtain host time.
  int get offsetUs => ((t2 - t1) + (t3 - t4)) ~/ 2;

  /// Round-trip time with the host's processing gap removed.
  int get rttUs => (t4 - t1) - (t3 - t2);

  /// One-way path delay (half the corrected round trip).
  int get oneWayDelayUs => rttUs ~/ 2;

  @override
  String toString() =>
      'PtpSample(offset=${offsetUs}us, rtt=${rttUs}us, owd=${oneWayDelayUs}us)';
}

/// The client→host half of a probe: a single send timestamp the host echoes
/// back. Serialized as a compact map for the control plane.
class PtpProbe {
  /// Monotonically increasing probe id, so late/duplicate responses are matched
  /// or discarded.
  final int seq;

  /// Client send time (client clock), microseconds.
  final int t1;

  const PtpProbe({required this.seq, required this.t1});

  Map<String, dynamic> toJson() => {'seq': seq, 't1': t1};

  factory PtpProbe.fromJson(Map<String, dynamic> json) =>
      PtpProbe(seq: json['seq'] as int, t1: (json['t1'] as num).toInt());
}

/// The host→client half: the original probe plus the host's receive/send stamps.
class PtpResponse {
  final int seq;
  final int t1;
  final int t2;
  final int t3;

  const PtpResponse({
    required this.seq,
    required this.t1,
    required this.t2,
    required this.t3,
  });

  /// Host-side stamping of an incoming [probe]. [recvUs]/[sendUs] are the host
  /// clock at receive and just-before-send; pass the same value for both when
  /// host think-time is negligible.
  factory PtpResponse.stamp(PtpProbe probe,
          {required int recvUs, required int sendUs}) =>
      PtpResponse(seq: probe.seq, t1: probe.t1, t2: recvUs, t3: sendUs);

  /// Complete the exchange on the client with the receive time [t4].
  PtpSample complete(int t4) => PtpSample(t1: t1, t2: t2, t3: t3, t4: t4);

  Map<String, dynamic> toJson() => {'seq': seq, 't1': t1, 't2': t2, 't3': t3};

  factory PtpResponse.fromJson(Map<String, dynamic> json) => PtpResponse(
        seq: json['seq'] as int,
        t1: (json['t1'] as num).toInt(),
        t2: (json['t2'] as num).toInt(),
        t3: (json['t3'] as num).toInt(),
      );
}

/// Maintains a running clock-offset estimate from a window of [PtpSample]s using
/// the classic NTP **minimum-delay filter**: the sample with the smallest RTT in
/// the window carries the least queuing noise, so its offset is the most
/// trustworthy. Jitter is reported as the spread of recent offset estimates.
class PtpClockEstimator {
  PtpClockEstimator({this.windowSize = 8})
      : assert(windowSize > 0, 'windowSize must be positive');

  /// How many recent samples to keep for the minimum-delay filter.
  final int windowSize;

  final List<PtpSample> _window = [];

  /// Default per-probe cadence (plan: a 4-message exchange every 5 s).
  static const Duration probeInterval = Duration(seconds: 5);

  /// Add a freshly completed [sample], evicting the oldest when full.
  void addSample(PtpSample sample) {
    _window.add(sample);
    if (_window.length > windowSize) _window.removeAt(0);
  }

  /// True once at least one sample has been recorded.
  bool get hasEstimate => _window.isNotEmpty;

  /// The window sample with the smallest RTT — the authoritative one.
  PtpSample get _best => _window.reduce((a, b) => b.rttUs < a.rttUs ? b : a);

  /// Best current offset (microseconds) to add to a client reading for host
  /// time. Zero before the first sample.
  int get offsetUs => hasEstimate ? _best.offsetUs : 0;

  /// One-way path delay of the best sample (microseconds).
  int get oneWayDelayUs => hasEstimate ? _best.oneWayDelayUs : 0;

  /// RTT of the best sample (microseconds).
  int get rttUs => hasEstimate ? _best.rttUs : 0;

  /// Offset jitter: standard deviation of the recent per-sample offsets
  /// (microseconds). A proxy for network/clock instability. Zero with <2
  /// samples.
  double get jitterUs {
    if (_window.length < 2) return 0;
    final offsets = _window.map((s) => s.offsetUs.toDouble()).toList();
    final mean = offsets.reduce((a, b) => a + b) / offsets.length;
    final variance =
        offsets.map((o) => (o - mean) * (o - mean)).reduce((a, b) => a + b) /
            offsets.length;
    return math.sqrt(variance);
  }

  /// Convert a client-clock microsecond reading to estimated host time.
  int toHostTimeUs(int clientUs) => clientUs + offsetUs;

  /// Drop all samples (e.g. after a key/session rotation or transport change).
  void reset() => _window.clear();
}
