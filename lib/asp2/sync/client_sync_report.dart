import 'dart:math' as math;

/// Telemetry a client publishes to the host on the control plane (plan: every
/// 2 s). Phase 2 makes sync **closed-loop** — the host can only pace a client it
/// has feedback from, and these are the feedback signals.
///
/// All fields are plain scalars so the report serializes to a tiny JSON map that
/// rides the existing control channel.
class ClientSyncReport {
  /// Stable id of the reporting client (peer id used elsewhere in the stack).
  final String clientId;

  /// Current playout buffer occupancy, milliseconds. The host's primary lever:
  /// too deep ⇒ latency, too shallow ⇒ underrun risk.
  final int bufferDepthMs;

  /// Signed clock drift versus the host (microseconds). Positive ⇒ the client is
  /// running ahead and should slow down; negative ⇒ behind, speed up.
  final int driftUs;

  /// Frames dropped since the last report (late arrivals / overruns).
  final int dropped;

  /// Inter-arrival jitter variance (ms²), as seen by the client.
  final double jitterVarMs;

  /// Most recent round-trip time to the host (microseconds).
  final int rttUs;

  const ClientSyncReport({
    required this.clientId,
    required this.bufferDepthMs,
    required this.driftUs,
    required this.dropped,
    required this.jitterVarMs,
    required this.rttUs,
  });

  /// Jitter standard deviation (ms) — the form the adaptive jitter buffer wants.
  double get jitterStdDevMs => math.sqrt(jitterVarMs);

  Map<String, dynamic> toJson() => {
        'clientId': clientId,
        'bufferDepthMs': bufferDepthMs,
        'driftUs': driftUs,
        'dropped': dropped,
        'jitterVarMs': jitterVarMs,
        'rttUs': rttUs,
      };

  factory ClientSyncReport.fromJson(Map<String, dynamic> json) =>
      ClientSyncReport(
        clientId: json['clientId'] as String,
        bufferDepthMs: (json['bufferDepthMs'] as num).toInt(),
        driftUs: (json['driftUs'] as num).toInt(),
        dropped: (json['dropped'] as num).toInt(),
        jitterVarMs: (json['jitterVarMs'] as num).toDouble(),
        rttUs: (json['rttUs'] as num).toInt(),
      );

  @override
  String toString() =>
      'ClientSyncReport($clientId: buf=${bufferDepthMs}ms, drift=${driftUs}us, '
      'dropped=$dropped, jitterVar=${jitterVarMs}ms2, rtt=${rttUs}us)';
}

/// Host-side fleet view: keeps the latest report per client and summarizes the
/// group so the host can make pacing decisions (and surface a health readout in
/// the UI later).
class SyncReportAggregator {
  final Map<String, ClientSyncReport> _latest = {};

  /// Record (or replace) the latest report for its client.
  void ingest(ClientSyncReport report) => _latest[report.clientId] = report;

  /// Forget a client (disconnect).
  void remove(String clientId) => _latest.remove(clientId);

  /// Snapshot of every client's most recent report.
  List<ClientSyncReport> get reports => List.unmodifiable(_latest.values);

  int get clientCount => _latest.length;

  /// Median absolute drift across the fleet (microseconds) — the headline sync
  /// quality number that the Phase 2 gate (<30 ms median LAN) is measured on.
  double get medianAbsDriftUs {
    if (_latest.isEmpty) return 0;
    final drifts = _latest.values.map((r) => r.driftUs.abs()).toList()..sort();
    return _median(drifts.map((d) => d.toDouble()).toList());
  }

  /// 95th-percentile absolute drift (microseconds) — the gate's p95 <50 ms bound.
  double get p95AbsDriftUs {
    if (_latest.isEmpty) return 0;
    final drifts = _latest.values.map((r) => r.driftUs.abs()).toList()..sort();
    return _percentile(drifts.map((d) => d.toDouble()).toList(), 0.95);
  }

  /// Total frames dropped across the fleet since each client's last report.
  int get totalDropped => _latest.values.fold(0, (sum, r) => sum + r.dropped);

  /// The client furthest behind, if any is more than [thresholdMs] ms behind —
  /// the candidate for a 1.5× catch-up unicast stream.
  ClientSyncReport? worstLaggard({int thresholdMs = 500}) {
    ClientSyncReport? worst;
    for (final r in _latest.values) {
      // driftUs negative ⇒ behind. Convert the threshold to µs.
      if (r.driftUs < -thresholdMs * 1000) {
        if (worst == null || r.driftUs < worst.driftUs) worst = r;
      }
    }
    return worst;
  }

  static double _median(List<double> sorted) => _percentile(sorted, 0.5);

  /// Linear-interpolated percentile of an already-sorted list.
  static double _percentile(List<double> sorted, double p) {
    if (sorted.isEmpty) return 0;
    if (sorted.length == 1) return sorted.first;
    final rank = p * (sorted.length - 1);
    final lo = rank.floor();
    final hi = rank.ceil();
    if (lo == hi) return sorted[lo];
    final frac = rank - lo;
    return sorted[lo] * (1 - frac) + sorted[hi] * frac;
  }
}
