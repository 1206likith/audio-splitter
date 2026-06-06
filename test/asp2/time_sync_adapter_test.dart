import 'dart:typed_data';

import 'package:audio_splitter_app/asp2/sync/time_sync_adapter.dart';
import 'package:audio_splitter_app/core/contracts/i_time_sync.dart';
import 'package:audio_splitter_app/services/sync_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Verifies TimeSyncAdapter is a faithful 1:1 wrap of SyncService. SyncService
/// is a singleton, so we reset it before each test (matching sync_service_test)
/// and dispose timers afterwards.
void main() {
  late TimeSyncAdapter sync;

  setUp(() {
    // ignore: invalid_use_of_visible_for_testing_member
    SyncService().resetForTesting();
    sync = TimeSyncAdapter();
  });

  tearDown(() {
    SyncService().dispose();
  });

  final data = Uint8List.fromList([1, 2, 3, 4]);

  test('onClockSample feeds latency through to averageLatencyMs', () {
    sync.onClockSample(serverTimeMs: 1000, rttMs: 50);
    expect(sync.averageLatencyMs, 50.0);
  });

  test('jitterMs reflects measurement spread', () {
    sync.onClockSample(serverTimeMs: 1000, rttMs: 40);
    sync.onClockSample(serverTimeMs: 1010, rttMs: 60);
    expect(sync.jitterMs, closeTo(10.0, 0.001));
  });

  test('nowSyncedMs is near wall-clock when offset is zero', () {
    final now = DateTime.now().millisecondsSinceEpoch;
    expect(sync.nowSyncedMs(), closeTo(now, 100));
  });

  test('schedule buffers a far-future frame', () {
    final future = DateTime.now().millisecondsSinceEpoch + 200;
    final s = sync.schedule('device1', data, future);
    expect(s.decision, SyncDecision.buffer);
    expect(s.audioData, isNotNull);
    expect(s.delayMs, greaterThan(0));
  });

  test('schedule drops a far-past frame', () {
    final past = DateTime.now().millisecondsSinceEpoch - 500;
    final s = sync.schedule('device1', data, past);
    expect(s.decision, SyncDecision.drop);
    expect(s.audioData, isNull);
  });

  test('schedule plays an on-time frame', () {
    final now = DateTime.now().millisecondsSinceEpoch;
    final s = sync.schedule('device1', data, now);
    expect(
      s.decision,
      anyOf(SyncDecision.play, SyncDecision.playImmediate),
    );
    expect(s.audioData, isNotNull);
  });

  test('defaults to the SyncService singleton', () {
    expect(sync.service, same(SyncService()));
  });
}
