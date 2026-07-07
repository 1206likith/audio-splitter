// Runtime sync convergence proof — a headless multi-client fleet simulation.
//
// The audit found the sync stack (PtpLite offset estimation, PidPacer rate
// correction, SyncReportAggregator) had unit tests for each piece but no proof
// that a FLEET of clients with differing clock offsets, drift rates and network
// jitter actually converges to a bounded sync envelope at runtime — the metric
// you'd actually claim ("all clients within X ms of the host").
//
// This simulates that closed loop deterministically (no real network, no real
// devices): each virtual client starts with a random offset + a constant drift
// (its crystal runs slightly fast/slow) + per-tick jitter, runs its own PidPacer
// to trim playout rate, and reports drift to a shared aggregator. We then assert
// the whole fleet's p95 absolute drift collapses from "tens of ms" at start to a
// tight envelope after convergence, and stays there.

import 'dart:math' as math;

import 'package:audio_splitter_app/asp2/sync/client_sync_report.dart';
import 'package:audio_splitter_app/asp2/sync/pid_pacer.dart';
import 'package:flutter_test/flutter_test.dart';

/// A virtual client clock that the host is trying to keep in sync.
///
/// `driftPpm` models a crystal that runs fast/slow by that many parts per
/// million (real consumer clocks drift ~10-100 ppm). `jitterUs` is the random
/// measurement noise on each drift observation (network RTT variation).
class _VirtualClient {
  _VirtualClient({
    required this.id,
    required this.initialOffsetUs,
    required this.driftPpm,
    required this.jitterUs,
    required this.gains,
    required math.Random rng,
  })  : _offsetUs = initialOffsetUs.toDouble(),
        _pacer = PidPacer(gains: gains),
        _rng = rng;

  final String id;
  final int initialOffsetUs;
  final double driftPpm;
  final int jitterUs;
  final PidGains gains;
  final math.Random _rng;
  final PidPacer _pacer;

  double _offsetUs; // true offset from host clock, microseconds
  double _rate = 1.0; // current playout rate multiplier

  /// Advance the client by [dtSeconds] of host time and run one sync step.
  /// Returns the drift the client *observes* (true offset + jitter).
  ///
  /// Plant model matches the pacer's own closed-loop test: a positive rate trim
  /// (rate>1 ⇒ playing faster) consumes negative drift at (rate-1)·1e6 µs/s. On
  /// top of that, a free-running crystal adds driftPpm of steady error — a small
  /// perturbation (±80 ppm ⇒ ±80 µs/s) the pacer's ±4% trim (±40 000 µs/s)
  /// easily dominates once it has locked.
  int tick(double dtSeconds) {
    // 1) Pacer correction from the PREVIOUS step's rate consumes drift.
    _offsetUs += (_rate - 1.0) * 1.0e6 * dtSeconds;
    // 2) Crystal free-run adds a little steady drift each interval.
    _offsetUs += driftPpm * dtSeconds; // ppm ⇒ µs per second

    // Observed drift = true offset + symmetric measurement jitter.
    final noise = (_rng.nextDouble() * 2 - 1) * jitterUs;
    final observedUs = (_offsetUs + noise).round();

    // Run the pacer on the observed drift to get the NEXT rate multiplier.
    _rate = _pacer.update(observedUs, dtSeconds);
    return observedUs;
  }

  double get trueOffsetUs => _offsetUs;
}

/// Run a fleet for [ticks] steps and return (startP95Us, endP95Us) absolute
/// drift across all clients, measured by the real SyncReportAggregator.
(double, double) runFleet({
  required int clients,
  required int ticks,
  double dtSeconds = 0.2,
  PidGains gains = PidGains.lan,
  int seed = 42,
}) {
  final rng = math.Random(seed);
  final fleet = <_VirtualClient>[
    for (int i = 0; i < clients; i++)
      _VirtualClient(
        id: 'client-$i',
        // Start badly out of sync: ±40 ms offset.
        initialOffsetUs: (rng.nextInt(80000)) - 40000,
        // Mixed fast/slow crystals: ±80 ppm.
        driftPpm: (rng.nextDouble() * 160) - 80,
        jitterUs: 800, // ~0.8 ms observation jitter
        gains: gains,
        rng: rng,
      ),
  ];
  final agg = SyncReportAggregator();

  double p95At(int _) {
    for (final c in fleet) {
      agg.ingest(ClientSyncReport(
        clientId: c.id,
        bufferDepthMs: 60,
        driftUs: c.trueOffsetUs.round(),
        dropped: 0,
        jitterVarMs: 0,
        rttUs: 0,
      ));
    }
    return agg.p95AbsDriftUs;
  }

  // Seed the aggregator, capture the starting envelope, run to convergence.
  final start = p95At(0);
  double end = start;
  for (int t = 0; t < ticks; t++) {
    for (final c in fleet) {
      c.tick(dtSeconds);
    }
    end = p95At(t);
  }
  return (start, end);
}

void main() {
  group('Fleet sync convergence (runtime proof)', () {
    test('a 5-client fleet on LAN converges from ±tens-of-ms to a tight '
        'envelope', () {
      // 200 ticks * 200 ms = 40 s of simulated session.
      final (start, end) = runFleet(clients: 5, ticks: 200, gains: PidGains.lan);
      // Starts badly out of sync (well over 10 ms p95).
      expect(start, greaterThan(10000));
      // Converges to a tight envelope: p95 absolute drift under 5 ms.
      expect(end, lessThan(5000),
          reason: 'fleet p95 drift should converge under 5 ms, got '
              '${(end / 1000).toStringAsFixed(2)} ms');
      // And it genuinely improved by a large margin.
      expect(end, lessThan(start / 3));
    });

    test('a larger 12-client fleet still converges', () {
      final (start, end) =
          runFleet(clients: 12, ticks: 250, gains: PidGains.lan);
      expect(end, lessThan(5000),
          reason: '12-client p95 drift = ${(end / 1000).toStringAsFixed(2)} ms');
      expect(end, lessThan(start));
    });

    test('Bluetooth gains (gentler) still converge, just more slowly', () {
      // Bluetooth uses gentle gains to avoid buffer pumping; give it more time.
      final (start, end) =
          runFleet(clients: 4, ticks: 400, gains: PidGains.bluetooth);
      expect(end, lessThan(start),
          reason: 'bluetooth fleet must still trend toward sync');
      expect(end, lessThan(10000),
          reason: 'bluetooth p95 within 10 ms after 80 s, got '
              '${(end / 1000).toStringAsFixed(2)} ms');
    });

    test('convergence is deterministic for a fixed seed', () {
      final a = runFleet(clients: 5, ticks: 100, seed: 7);
      final b = runFleet(clients: 5, ticks: 100, seed: 7);
      expect(a.$2, b.$2);
    });
  });
}
