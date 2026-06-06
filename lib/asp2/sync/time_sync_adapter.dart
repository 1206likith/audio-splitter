import 'dart:typed_data';

import '../../core/contracts/i_time_sync.dart';
import '../../services/sync_service.dart';

/// TimeSyncAdapter — Phase 0 [ITimeSync] facade over v1's [SyncService].
///
/// A 1:1 wrapper that does **not** touch SyncService internals (its thresholds
/// 50 / -20 / -100 ms, singleton identity, and `resetForTesting` are pinned by
/// `test/sync_service_test.dart`). It only re-expresses the existing one-way
/// sync surface in the layered contract so the rest of the stack depends on
/// [ITimeSync], not the concrete service. Phase 2 swaps in PTP-lite + PID pacing
/// behind this same interface with no caller changes.
class TimeSyncAdapter implements ITimeSync {
  TimeSyncAdapter([SyncService? service]) : _sync = service ?? SyncService();

  final SyncService _sync;

  /// The wrapped service, for callers that still need v1 APIs during migration.
  SyncService get service => _sync;

  @override
  void onClockSample({required int serverTimeMs, required int rttMs}) {
    _sync.updateClockSync(serverTimeMs, rttMs);
  }

  @override
  int nowSyncedMs() => _sync.getSynchronizedTime();

  @override
  double get averageLatencyMs => _sync.getAverageLatency();

  @override
  double get jitterMs => _sync.getLatencyJitter();

  @override
  SyncSchedule schedule(String peerId, Uint8List audioData, int timestampMs) {
    final result = _sync.synchronizeAudio(peerId, audioData, timestampMs);
    return SyncSchedule(
      decision: _mapAction(result.action),
      audioData: result.audioData,
      delayMs: result.delayMs,
    );
  }

  SyncDecision _mapAction(SyncAction action) {
    switch (action) {
      case SyncAction.buffer:
        return SyncDecision.buffer;
      case SyncAction.play:
        return SyncDecision.play;
      case SyncAction.playImmediate:
        return SyncDecision.playImmediate;
      case SyncAction.drop:
        return SyncDecision.drop;
    }
  }
}
