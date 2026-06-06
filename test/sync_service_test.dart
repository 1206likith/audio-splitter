import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:audio_splitter_app/services/sync_service.dart';
import 'package:audio_splitter_app/models/audio_stream.dart';

// NOTE: SyncService is a Dart singleton — SyncService() always returns the
// same _instance. setUp calls resetForTesting() (a @visibleForTesting method
// added to SyncService) to fully reset all mutable state — including
// _latencyMeasurements and _localClockOffset — which dispose() intentionally
// does not reset because it is a lifecycle method, not a test helper.
// tearDown calls dispose() to cancel any Timers started by initialize().
void main() {
  group('SyncService', () {
    late SyncService syncService;

    setUp(() {
      syncService = SyncService();
      // Full state reset before every test, including measurements and clock
      // offset, which are not cleared by the production dispose() call.
      syncService
          .resetForTesting(); // ignore: invalid_use_of_visible_for_testing_member
    });

    tearDown(() {
      // Cancel timers started by initialize(); safe to call even when not
      // initialized because all cancel/close operations are guarded by '?'.
      syncService.dispose();
    });

    test('initialize sets isInitialized to true', () async {
      await syncService.initialize();
      expect(syncService.isInitialized, isTrue);
    });

    test('getAverageLatency returns 0 when no measurements', () {
      expect(syncService.getAverageLatency(), 0.0);
    });

    test('updateClockSync adds latency measurement', () {
      syncService.updateClockSync(1000, 50);
      expect(syncService.getAverageLatency(), 50.0);
    });

    test('updateClockSync averages multiple measurements', () {
      syncService.updateClockSync(1000, 40);
      syncService.updateClockSync(1010, 60);
      expect(syncService.getAverageLatency(), 50.0);
    });

    test('updateClockSync limits to maxLatencyMeasurements', () {
      for (int i = 0; i < SyncService.maxLatencyMeasurements + 5; i++) {
        syncService.updateClockSync(1000 + i, 100);
      }
      // Should still work without crashing, capped at maxLatencyMeasurements
      expect(syncService.getAverageLatency(), 100.0);
    });

    test('getLatencyJitter returns 0 for single measurement', () {
      syncService.updateClockSync(1000, 50);
      expect(syncService.getLatencyJitter(), 0.0);
    });

    test('getLatencyJitter calculates variance correctly', () {
      syncService.updateClockSync(1000, 40);
      syncService.updateClockSync(1010, 60);
      // mean=50, variance=((40-50)^2 + (60-50)^2)/2 = 100, stddev=10
      expect(syncService.getLatencyJitter(), closeTo(10.0, 0.001));
    });

    test('getOptimalQuality returns ultra for low latency', () {
      // averageLatency=20, jitter=0 → ultra (both thresholds: <=50 and <=10)
      syncService.updateClockSync(1000, 20);
      expect(syncService.getOptimalQuality('test'), AudioQuality.ultra);
    });

    test('getOptimalQuality returns low for high latency', () {
      // averageLatency > 150 → low quality
      for (int i = 0; i < 5; i++) {
        syncService.updateClockSync(1000 + i, 200);
      }
      expect(syncService.getOptimalQuality('test'), AudioQuality.low);
    });

    test('synchronizeAudio drops frames too far in the past', () {
      // resetForTesting() sets _localClockOffset = 0, so getSynchronizedTime()
      // ≈ now. timeDiff = (now - 500) - now = -500 < -100 → drop.
      final data = Uint8List.fromList([1, 2, 3, 4]);
      final pastTimestamp = DateTime.now().millisecondsSinceEpoch - 500;
      final result =
          syncService.synchronizeAudio('device1', data, pastTimestamp);
      expect(result.action, SyncAction.drop);
      expect(result.audioData, isNull);
    });

    test('synchronizeAudio buffers frames far in the future', () {
      // timeDiff = (now + 200) - now = 200 > 50 → buffer
      final data = Uint8List.fromList([1, 2, 3, 4]);
      final futureTimestamp = DateTime.now().millisecondsSinceEpoch + 200;
      final result =
          syncService.synchronizeAudio('device1', data, futureTimestamp);
      expect(result.action, SyncAction.buffer);
      expect(result.delayMs, greaterThan(0));
    });

    test('synchronizeAudio plays on-time frames', () {
      // timeDiff = nowTs - now ≈ 0, which is in range [-20, 50] → play
      final data = Uint8List.fromList([1, 2, 3, 4]);
      final nowTimestamp = DateTime.now().millisecondsSinceEpoch;
      final result =
          syncService.synchronizeAudio('device1', data, nowTimestamp);
      expect(result.action, anyOf(SyncAction.play, SyncAction.playImmediate));
      expect(result.audioData, isNotNull);
    });

    test('calculateOptimalBufferSize returns targetBufferSize by default', () {
      // No DeviceSync registered for 'unknown' → returns targetBufferSize
      expect(
        syncService.calculateOptimalBufferSize('unknown'),
        SyncService.targetBufferSize,
      );
    });
  });

  group('AudioBuffer', () {
    late AudioBuffer buffer;

    setUp(() {
      buffer = AudioBuffer('test-device');
    });

    test('starts empty', () {
      expect(buffer.size, 0);
    });

    test('addData increases size', () {
      buffer.addData(Uint8List.fromList([1, 2]), 1000);
      expect(buffer.size, 1);
    });

    test('addData inserts in timestamp order', () {
      buffer.addData(Uint8List.fromList([3]), 3000);
      buffer.addData(Uint8List.fromList([1]), 1000);
      buffer.addData(Uint8List.fromList([2]), 2000);
      expect(buffer.size, 3);
      // getData should find each by timestamp
      final d1 = buffer.getData(1000);
      expect(d1, isNotNull);
      expect(d1![0], 1);
    });

    test('getData returns null for empty buffer', () {
      expect(buffer.getData(1000), isNull);
    });

    test('getData returns null when no chunk within tolerance', () {
      buffer.addData(Uint8List.fromList([1]), 1000);
      // 1000ms away from 2000 — outside 100ms tolerance (strict less-than)
      expect(buffer.getData(2000), isNull);
    });

    test('getData returns chunk within 100ms tolerance', () {
      buffer.addData(Uint8List.fromList([42]), 1000);
      final result = buffer.getData(1050); // 50ms away — within tolerance
      expect(result, isNotNull);
      expect(result![0], 42);
    });

    test('getData removes returned chunk', () {
      buffer.addData(Uint8List.fromList([1]), 1000);
      buffer.getData(1000);
      expect(buffer.size, 0);
    });

    test('removeOldData removes stale chunks', () {
      buffer.addData(Uint8List.fromList([1]), 1000);
      buffer.addData(Uint8List.fromList([2]), 2000);
      buffer.addData(Uint8List.fromList([3]), 3000);
      // lowerBound(2500) = index 2 (first element >= 2500 is ts=3000)
      // removeRange(0, 2) → removes ts=1000 and ts=2000; ts=3000 remains
      buffer.removeOldData(2500);
      expect(buffer.size, 1); // only ts=3000 remains
    });

    test('buffer caps at maxBufferSize', () {
      for (int i = 0; i < SyncService.maxBufferSize + 10; i++) {
        buffer.addData(Uint8List.fromList([i % 256]), i * 10);
      }
      expect(buffer.size, lessThanOrEqualTo(SyncService.maxBufferSize));
    });
  });
}
