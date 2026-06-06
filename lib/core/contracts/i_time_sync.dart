import 'dart:typed_data';

/// What a client should do with a freshly received audio frame, based on how
/// its presentation time compares to the synchronized clock.
///
/// Mirrors the v1 `SyncAction` semantics so the Phase 0 adapter is a 1:1 wrap.
enum SyncDecision {
  /// Hold the frame and play it after [SyncSchedule.delayMs].
  buffer,

  /// Play now (frame is on time or slightly early; small [SyncSchedule.delayMs]).
  play,

  /// Play immediately with no delay (frame is slightly late).
  playImmediate,

  /// Discard the frame (too far in the past to be useful).
  drop,
}

/// The result of scheduling one frame against the synchronized clock.
class SyncSchedule {
  final SyncDecision decision;

  /// The audio to play, or null when [decision] is [SyncDecision.drop].
  final Uint8List? audioData;

  /// Milliseconds to wait before rendering (0 for immediate decisions).
  final int delayMs;

  const SyncSchedule({
    required this.decision,
    required this.audioData,
    required this.delayMs,
  });
}

/// The time-sync layer contract: clock alignment between host and clients and
/// per-frame playout scheduling.
///
/// Phase 0 wraps the existing one-way [SyncService]. Phase 2 swaps in a
/// closed-loop PTP-lite + PID pacing implementation behind this same interface.
abstract class ITimeSync {
  /// Feed a clock sample measured against the host (server time + RTT in ms).
  void onClockSample({required int serverTimeMs, required int rttMs});

  /// Current synchronized time in milliseconds (host clock estimate).
  int nowSyncedMs();

  /// Rolling average one-way latency, in milliseconds.
  double get averageLatencyMs;

  /// Latency jitter (stddev of recent measurements), in milliseconds.
  double get jitterMs;

  /// Decide what to do with [audioData] presented at [timestampMs] for [peerId].
  SyncSchedule schedule(String peerId, Uint8List audioData, int timestampMs);
}
