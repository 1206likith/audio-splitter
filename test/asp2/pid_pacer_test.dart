import 'package:audio_splitter_app/asp2/sync/pid_pacer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PidPacer', () {
    test('rate multiplier opposes drift sign', () {
      final pacer = PidPacer(gains: PidGains.lan);
      // Client ahead (positive drift) ⇒ slow down ⇒ multiplier < 1.
      final slow = pacer.update(40000, 1.0); // 40ms ahead
      expect(slow, lessThan(1.0));

      pacer.reset();
      // Client behind (negative drift) ⇒ speed up ⇒ multiplier > 1.
      final fast = pacer.update(-40000, 1.0);
      expect(fast, greaterThan(1.0));
    });

    test('output saturates at maxAdjust', () {
      final pacer = PidPacer(gains: PidGains.lan);
      // Huge drift would blow past the cap; it must clamp.
      final m = pacer.update(100000000, 1.0); // 100s ahead (absurd)
      expect(m, closeTo(1.0 - PidGains.lan.maxAdjust, 1e-9));
    });

    test('closed loop drives drift toward zero', () {
      final pacer = PidPacer(gains: PidGains.lan);
      // Simulate: drift shrinks proportionally to the applied rate correction.
      // A positive rate trim (>1) consumes negative drift (client catching up).
      var drift = -120000.0; // 120ms behind
      const dt = 0.5;
      for (var i = 0; i < 200; i++) {
        final rate = pacer.update(drift.round(), dt);
        // Model: each step, drift moves toward 0 in proportion to (rate-1).
        // (rate-1)>0 ⇒ playing faster ⇒ negative drift increases toward 0.
        drift += (rate - 1.0) * 1.0e6 * dt; // coarse plant model
        // Natural decay/noise-free; clamp to avoid runaway in the toy model.
      }
      expect(drift.abs(), lessThan(30000),
          reason: 'PID should converge drift under 30ms in the toy plant');
    });

    test('catch-up threshold at 500ms behind', () {
      final pacer = PidPacer();
      expect(pacer.needsCatchUp(-499000), isFalse);
      expect(pacer.needsCatchUp(-501000), isTrue);
      expect(PidPacer.catchUpRate, 1.5);
    });

    test('transport presets differ in stiffness', () {
      expect(PidGains.lan.kp, greaterThan(PidGains.wan.kp));
      expect(PidGains.wan.kp, greaterThan(PidGains.bluetooth.kp));
      expect(PidGains.bluetooth.maxAdjust, lessThan(PidGains.lan.maxAdjust));
    });
  });

  group('AdaptiveJitterBuffer', () {
    test('starts at the floor', () {
      final buf = AdaptiveJitterBuffer(floorMs: 20);
      expect(buf.targetDepthMs, 20);
    });

    test('grows to ~2·stddev on a jittery link, never below floor', () {
      final buf = AdaptiveJitterBuffer(floorMs: 20);
      // Jitter samples with stddev ≈ 30ms ⇒ target ≈ 60ms.
      final samples = [0.0, 60.0, 0.0, 60.0, 0.0, 60.0, 0.0, 60.0];
      for (final s in samples) {
        buf.observeJitter(s);
      }
      final changed = buf.maybeResize(1000); // first resize fires immediately
      expect(changed, isTrue);
      expect(buf.targetDepthMs, greaterThan(20));
      expect(buf.targetDepthMs, closeTo(60, 5));
    });

    test('clean link stays at the floor', () {
      final buf = AdaptiveJitterBuffer(floorMs: 20);
      for (var i = 0; i < 16; i++) {
        buf.observeJitter(0.5); // tiny, consistent jitter
      }
      buf.maybeResize(1000);
      expect(buf.targetDepthMs, 20);
    });

    test('respects the resize cadence', () {
      final buf = AdaptiveJitterBuffer(
        floorMs: 20,
        resizeInterval: const Duration(milliseconds: 500),
      );
      for (var i = 0; i < 8; i++) {
        buf.observeJitter(i.isEven ? 0.0 : 80.0);
      }
      expect(buf.maybeResize(1000), isTrue); // first resize
      // Too soon — within 500ms of the last resize.
      for (var i = 0; i < 8; i++) {
        buf.observeJitter(i.isEven ? 0.0 : 80.0);
      }
      expect(buf.maybeResize(1300), isFalse);
      // Far enough out — resizes again.
      for (var i = 0; i < 8; i++) {
        buf.observeJitter(0.5);
      }
      expect(buf.maybeResize(1600), isTrue);
    });

    test('caps at the ceiling on a pathological link', () {
      final buf = AdaptiveJitterBuffer(floorMs: 20, ceilingMs: 100);
      for (var i = 0; i < 16; i++) {
        buf.observeJitter(i.isEven ? 0.0 : 2000.0); // wild jitter
      }
      buf.maybeResize(1000);
      expect(buf.targetDepthMs, 100);
    });
  });
}
