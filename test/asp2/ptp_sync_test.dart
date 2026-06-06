import 'package:audio_splitter_app/asp2/sync/client_sync_report.dart';
import 'package:audio_splitter_app/asp2/sync/ptp_lite.dart';
import 'package:flutter_test/flutter_test.dart';

/// Deterministic LCG — reproducible "random" network conditions without
/// Math.random (keeps the sim test stable across runs/CI).
class _Lcg {
  int _s;
  _Lcg(this._s);
  int _next() {
    _s = (_s * 1103515245 + 12345) & 0x7fffffff;
    return _s;
  }

  /// Uniform integer in [lo, hi].
  int range(int lo, int hi) => lo + _next() % (hi - lo + 1);
}

double _median(List<double> xs) {
  final s = [...xs]..sort();
  final mid = s.length ~/ 2;
  return s.length.isOdd ? s[mid] : (s[mid - 1] + s[mid]) / 2;
}

double _percentile(List<double> xs, double p) {
  final s = [...xs]..sort();
  if (s.length == 1) return s.first;
  final rank = p * (s.length - 1);
  final lo = rank.floor();
  final hi = rank.ceil();
  if (lo == hi) return s[lo];
  return s[lo] * (1 - (rank - lo)) + s[hi] * (rank - lo);
}

void main() {
  group('PtpSample math', () {
    test('symmetric path → exact offset, correct rtt/owd', () {
      // host = client + 1_000_000us. up=down=5000us, no processing gap.
      const o = 1000000;
      const d = 5000;
      const c0 = 42;
      const s = PtpSample(
        t1: c0,
        t2: c0 + d + o, // host recv
        t3: c0 + d + o, // host send (p=0)
        t4: c0 + d + 0 + d, // client recv
      );
      expect(s.offsetUs, o);
      expect(s.rttUs, 2 * d);
      expect(s.oneWayDelayUs, d);
    });

    test('host processing gap cancels out of rtt and offset', () {
      const o = -250000; // client ahead of host
      const dUp = 4000, dDown = 4000, p = 1500, c0 = 1000;
      const s = PtpSample(
        t1: c0,
        t2: c0 + dUp + o,
        t3: c0 + dUp + o + p,
        t4: c0 + dUp + p + dDown,
      );
      expect(s.offsetUs, o); // symmetric ⇒ exact
      expect(s.rttUs, dUp + dDown); // p removed
    });
  });

  group('PtpProbe / PtpResponse round-trip', () {
    test('stamp → complete reconstructs the sample; JSON survives', () {
      const probe = PtpProbe(seq: 7, t1: 1234);
      final encoded = PtpProbe.fromJson(probe.toJson());
      expect(encoded.seq, 7);
      expect(encoded.t1, 1234);

      final resp = PtpResponse.stamp(encoded, recvUs: 5000, sendUs: 5200);
      final wire = PtpResponse.fromJson(resp.toJson());
      final sample = wire.complete(9000);
      expect(sample.t1, 1234);
      expect(sample.t2, 5000);
      expect(sample.t3, 5200);
      expect(sample.t4, 9000);
    });
  });

  group('PtpClockEstimator minimum-delay filter', () {
    test('picks the lowest-RTT sample as authoritative', () {
      final est = PtpClockEstimator(windowSize: 4);
      // Three samples, same true offset 100000, different (asymmetric) delays.
      // Low-RTT sample is the cleanest (smallest asymmetry).
      est.addSample(const PtpSample(
          t1: 0,
          t2: 100000 + 8000,
          t3: 100000 + 8000,
          t4: 20000)); // rtt huge, skewed
      est.addSample(const PtpSample(
          t1: 0,
          t2: 100000 + 1000,
          t3: 100000 + 1000,
          t4: 2000)); // rtt 2000, clean
      est.addSample(const PtpSample(
          t1: 0, t2: 100000 + 5000, t3: 100000 + 5000, t4: 12000));
      expect(est.hasEstimate, isTrue);
      // The clean (lowest-rtt) sample has offset exactly 100000.
      expect(est.offsetUs, 100000);
      expect(est.rttUs, 2000);
    });

    test('window evicts oldest; jitter is the spread of offsets', () {
      final est = PtpClockEstimator(windowSize: 2);
      est.addSample(const PtpSample(t1: 0, t2: 1000, t3: 1000, t4: 1000));
      est.addSample(const PtpSample(t1: 0, t2: 2000, t3: 2000, t4: 2000));
      est.addSample(const PtpSample(t1: 0, t2: 3000, t3: 3000, t4: 3000));
      expect(est.jitterUs, greaterThan(0));
      // toHostTime applies the current best offset.
      final off = est.offsetUs;
      expect(est.toHostTimeUs(10000), 10000 + off);
    });
  });

  group('ClientSyncReport', () {
    test('JSON round-trips and derives jitter stddev', () {
      const r = ClientSyncReport(
        clientId: 'phone-3',
        bufferDepthMs: 45,
        driftUs: -12000,
        dropped: 2,
        jitterVarMs: 9.0,
        rttUs: 8000,
      );
      final back = ClientSyncReport.fromJson(r.toJson());
      expect(back.clientId, 'phone-3');
      expect(back.bufferDepthMs, 45);
      expect(back.driftUs, -12000);
      expect(back.dropped, 2);
      expect(back.rttUs, 8000);
      expect(back.jitterStdDevMs, closeTo(3.0, 1e-9));
    });
  });

  group('SyncReportAggregator', () {
    test('median/p95 absolute drift + worst laggard detection', () {
      final agg = SyncReportAggregator();
      // Five clients, drifts in µs: +5ms, -10ms, +2ms, -600ms (laggard), +8ms.
      final drifts = {
        'a': 5000,
        'b': -10000,
        'c': 2000,
        'd': -600000,
        'e': 8000,
      };
      drifts.forEach((id, d) => agg.ingest(ClientSyncReport(
            clientId: id,
            bufferDepthMs: 40,
            driftUs: d,
            dropped: 0,
            jitterVarMs: 1.0,
            rttUs: 8000,
          )));
      expect(agg.clientCount, 5);
      // abs drifts sorted: 2000,5000,8000,10000,600000 → median = 8000us.
      expect(agg.medianAbsDriftUs, 8000);
      final laggard = agg.worstLaggard(thresholdMs: 500);
      expect(laggard, isNotNull);
      expect(laggard!.clientId, 'd');

      agg.remove('d');
      expect(agg.worstLaggard(thresholdMs: 500), isNull);
    });
  });

  group('Phase 2 GATE — PTP-lite LAN sync accuracy across 5 clients', () {
    test('median converged offset error <30ms, p95 <50ms', () {
      final lcg = _Lcg(0x5EED);
      const clients = 5;
      const probesPerClient = 12;

      final errorsMs = <double>[];

      for (var c = 0; c < clients; c++) {
        // Each client has a different true offset (±100ms) and a base LAN delay.
        final trueOffset = lcg.range(-100000, 100000); // µs
        final baseOneWay = lcg.range(2000, 6000); // 2–6 ms typical LAN
        final est = PtpClockEstimator(windowSize: 8);

        var clientClock = lcg.range(0, 1000000);
        for (var p = 0; p < probesPerClient; p++) {
          // Independent per-direction jitter (0–4 ms) — the realistic source of
          // offset error; the minimum-delay filter is meant to reject it.
          final dUp = baseOneWay + lcg.range(0, 4000);
          final dDown = baseOneWay + lcg.range(0, 4000);
          final proc = lcg.range(50, 500); // host think time

          final t1 = clientClock;
          final t2 = t1 + dUp + trueOffset;
          final t3 = t2 + proc;
          final t4 = t1 + dUp + proc + dDown;
          est.addSample(PtpSample(t1: t1, t2: t2, t3: t3, t4: t4));

          clientClock += lcg.range(20000, 60000); // next probe later
        }

        final errUs = (est.offsetUs - trueOffset).abs();
        errorsMs.add(errUs / 1000.0);
      }

      final medianMs = _median(errorsMs);
      final p95Ms = _percentile(errorsMs, 0.95);

      // ignore: avoid_print
      print('PTP-lite sync: 5 clients, errors(ms)=$errorsMs '
          '→ median=${medianMs.toStringAsFixed(2)}ms, '
          'p95=${p95Ms.toStringAsFixed(2)}ms');

      expect(medianMs, lessThan(30.0),
          reason: 'gate: median LAN sync error must be <30ms');
      expect(p95Ms, lessThan(50.0),
          reason: 'gate: p95 LAN sync error must be <50ms');
    });
  });
}
