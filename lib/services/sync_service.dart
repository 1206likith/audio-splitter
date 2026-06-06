import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show visibleForTesting;
import '../models/audio_stream.dart';

class SyncService {
  static final SyncService _instance = SyncService._internal();
  factory SyncService() => _instance;
  SyncService._internal();

  // Synchronization state
  int _masterTimestamp = 0;
  int _localClockOffset = 0;
  final List<int> _latencyMeasurements = [];
  final Map<String, DeviceSync> _deviceSyncs = {};

  // Audio buffer management
  final Map<String, AudioBuffer> _audioBuffers = {};
  Timer? _syncTimer;
  Timer? _bufferCleanupTimer;

  // Configuration
  static const int maxLatencyMeasurements = 10;
  static const int targetBufferSize = 4096; // samples
  static const int maxBufferSize = 8192; // samples
  static const int syncIntervalMs = 100;
  static const int maxAllowedLatency = 200; // ms

  // Stream controllers
  final StreamController<SyncStats> _syncStatsController =
      StreamController<SyncStats>.broadcast();
  Stream<SyncStats> get syncStatsStream => _syncStatsController.stream;

  bool _isInitialized = false;
  bool get isInitialized => _isInitialized;

  Future<void> initialize() async {
    if (_isInitialized) return;

    // Start periodic sync measurements
    _syncTimer =
        Timer.periodic(const Duration(milliseconds: syncIntervalMs), (_) {
      _performSyncMeasurement();
    });

    // Start buffer cleanup
    _bufferCleanupTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _cleanupOldBuffers();
    });

    _isInitialized = true;
  }

  void dispose() {
    _syncTimer?.cancel();
    _bufferCleanupTimer?.cancel();
    _syncStatsController.close();
    _audioBuffers.clear();
    _deviceSyncs.clear();
    _latencyMeasurements.clear();
    _localClockOffset = 0;
    _masterTimestamp = 0;
    _isInitialized = false;
  }

  /// Resets all mutable state to a clean baseline.
  /// Intended for use in unit tests only — not for production code.
  // ignore: invalid_use_of_visible_for_testing_member
  @visibleForTesting
  void resetForTesting() {
    _syncTimer?.cancel();
    _bufferCleanupTimer?.cancel();
    _syncTimer = null;
    _bufferCleanupTimer = null;
    _audioBuffers.clear();
    _deviceSyncs.clear();
    _latencyMeasurements.clear();
    _localClockOffset = 0;
    _masterTimestamp = 0;
    _isInitialized = false;
  }

  // Master clock synchronization (for host)
  void startMasterClock() {
    _masterTimestamp = DateTime.now().millisecondsSinceEpoch;
  }

  int getMasterTime() {
    return DateTime.now().millisecondsSinceEpoch - _masterTimestamp;
  }

  // Client synchronization
  void updateClockSync(int serverTime, int roundTripTime) {
    final localTime = DateTime.now().millisecondsSinceEpoch;
    final networkDelay = roundTripTime ~/ 2;
    _localClockOffset = serverTime - localTime + networkDelay;

    // Add latency measurement
    _latencyMeasurements.add(roundTripTime);
    if (_latencyMeasurements.length > maxLatencyMeasurements) {
      _latencyMeasurements.removeAt(0);
    }
  }

  int getSynchronizedTime() {
    return DateTime.now().millisecondsSinceEpoch + _localClockOffset;
  }

  double getAverageLatency() {
    if (_latencyMeasurements.isEmpty) return 0.0;
    return _latencyMeasurements.reduce((a, b) => a + b) /
        _latencyMeasurements.length;
  }

  double getLatencyJitter() {
    if (_latencyMeasurements.length < 2) return 0.0;

    final average = getAverageLatency();
    final variance = _latencyMeasurements
            .map((latency) => pow(latency - average, 2))
            .reduce((a, b) => a + b) /
        _latencyMeasurements.length;

    return sqrt(variance);
  }

  // Audio buffer management with adaptive buffering
  void addAudioData(String deviceId, Uint8List audioData, int timestamp) {
    final buffer =
        _audioBuffers.putIfAbsent(deviceId, () => AudioBuffer(deviceId));
    buffer.addData(audioData, timestamp);

    // Update device sync info
    final deviceSync =
        _deviceSyncs.putIfAbsent(deviceId, () => DeviceSync(deviceId));
    deviceSync.lastDataTimestamp = timestamp;
    deviceSync.bufferSize = buffer.size;
  }

  Uint8List? getAudioData(String deviceId, int playbackTimestamp) {
    final buffer = _audioBuffers[deviceId];
    if (buffer == null) return null;

    return buffer.getData(playbackTimestamp);
  }

  // Adaptive buffer sizing based on network conditions
  int calculateOptimalBufferSize(String deviceId) {
    final deviceSync = _deviceSyncs[deviceId];
    if (deviceSync == null) return targetBufferSize;

    final averageLatency = getAverageLatency();
    final jitter = getLatencyJitter();

    // Increase buffer size for high latency/jitter networks
    int optimalSize = targetBufferSize;

    if (averageLatency > 100) {
      optimalSize = (optimalSize * 1.5).round();
    }

    if (jitter > 20) {
      optimalSize = (optimalSize * 1.3).round();
    }

    return min(optimalSize, maxBufferSize);
  }

  // Audio synchronization with drift correction
  AudioSyncResult synchronizeAudio(
      String deviceId, Uint8List audioData, int timestamp) {
    final deviceSync =
        _deviceSyncs.putIfAbsent(deviceId, () => DeviceSync(deviceId));
    deviceSync.lastDataTimestamp = timestamp;
    deviceSync.bufferSize = _audioBuffers[deviceId]?.size ?? 0;

    final currentTime = getSynchronizedTime();
    final timeDiff = timestamp - currentTime;

    // Determine sync action based on timing
    if (timeDiff > 50) {
      // Audio is too far in the future - buffer it
      return AudioSyncResult(
        audioData: audioData,
        action: SyncAction.buffer,
        delayMs: timeDiff,
      );
    } else if (timeDiff < -100) {
      // Audio is too far in the past - drop it
      deviceSync.droppedFrames++;
      return AudioSyncResult(
        audioData: null,
        action: SyncAction.drop,
        delayMs: 0,
      );
    } else if (timeDiff < -20) {
      // Audio is slightly late - play immediately
      return AudioSyncResult(
        audioData: audioData,
        action: SyncAction.playImmediate,
        delayMs: 0,
      );
    } else {
      // Audio is on time or slightly early
      return AudioSyncResult(
        audioData: audioData,
        action: SyncAction.play,
        delayMs: max(0, timeDiff),
      );
    }
  }

  // Dynamic quality adjustment based on network conditions
  AudioQuality getOptimalQuality(String deviceId) {
    final averageLatency = getAverageLatency();
    final jitter = getLatencyJitter();

    if (averageLatency > 150 || jitter > 30) {
      return AudioQuality.low; // Prioritize stability
    } else if (averageLatency > 100 || jitter > 20) {
      return AudioQuality.medium;
    } else if (averageLatency > 50 || jitter > 10) {
      return AudioQuality.high;
    } else {
      return AudioQuality.ultra; // Best quality for stable connections
    }
  }

  // Performance monitoring
  void _performSyncMeasurement() {
    final stats = SyncStats(
      averageLatency: getAverageLatency(),
      jitter: getLatencyJitter(),
      connectedDevices: _deviceSyncs.length,
      totalBufferSize:
          _audioBuffers.values.fold(0, (sum, buffer) => sum + buffer.size),
      droppedFrames:
          _deviceSyncs.values.fold(0, (sum, sync) => sum + sync.droppedFrames),
      clockOffset: _localClockOffset,
    );

    _syncStatsController.add(stats);
  }

  void _cleanupOldBuffers() {
    final currentTime = DateTime.now().millisecondsSinceEpoch;

    for (final buffer in _audioBuffers.values) {
      buffer.removeOldData(
          currentTime - 5000); // Remove data older than 5 seconds
    }
  }

  // Get sync statistics for monitoring
  Map<String, dynamic> getSyncStatistics() {
    return {
      'averageLatency': getAverageLatency(),
      'jitter': getLatencyJitter(),
      'clockOffset': _localClockOffset,
      'connectedDevices': _deviceSyncs.length,
      'totalBufferSize':
          _audioBuffers.values.fold(0, (sum, buffer) => sum + buffer.size),
      'droppedFrames':
          _deviceSyncs.values.fold(0, (sum, sync) => sum + sync.droppedFrames),
    };
  }
}

// Audio buffer with timestamp-based ordering — O(log n) insert and lookup
class AudioBuffer {
  final String deviceId;
  final List<AudioChunk> _chunks = [];

  AudioBuffer(this.deviceId);

  int get size => _chunks.length;

  void addData(Uint8List data, int timestamp) {
    final chunk = AudioChunk(data, timestamp);
    final insertIndex = _lowerBound(timestamp);
    _chunks.insert(insertIndex, chunk);
    if (_chunks.length > SyncService.maxBufferSize) {
      _chunks.removeAt(0);
    }
  }

  Uint8List? getData(int timestamp) {
    if (_chunks.isEmpty) return null;
    final idx = _lowerBound(timestamp);
    AudioChunk? best;
    int bestDiff = 999999;
    for (final i in [idx - 1, idx, idx + 1]) {
      if (i < 0 || i >= _chunks.length) continue;
      final diff = (_chunks[i].timestamp - timestamp).abs();
      if (diff < bestDiff) {
        bestDiff = diff;
        best = _chunks[i];
      }
    }
    if (best != null && bestDiff < 100) {
      _chunks.remove(best);
      return best.data;
    }
    return null;
  }

  void removeOldData(int cutoffTimestamp) {
    final idx = _lowerBound(cutoffTimestamp);
    if (idx > 0) _chunks.removeRange(0, idx);
  }

  // Returns the index of the first element with timestamp >= [timestamp].
  int _lowerBound(int timestamp) {
    int lo = 0, hi = _chunks.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_chunks[mid].timestamp < timestamp) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }
}

class AudioChunk {
  final Uint8List data;
  final int timestamp;

  AudioChunk(this.data, this.timestamp);
}

class DeviceSync {
  final String deviceId;
  int lastDataTimestamp = 0;
  int bufferSize = 0;
  int droppedFrames = 0;

  DeviceSync(this.deviceId);
}

class AudioSyncResult {
  final Uint8List? audioData;
  final SyncAction action;
  final int delayMs;

  AudioSyncResult({
    required this.audioData,
    required this.action,
    required this.delayMs,
  });
}

enum SyncAction {
  play,
  playImmediate,
  buffer,
  drop,
}

class SyncStats {
  final double averageLatency;
  final double jitter;
  final int connectedDevices;
  final int totalBufferSize;
  final int droppedFrames;
  final int clockOffset;

  SyncStats({
    required this.averageLatency,
    required this.jitter,
    required this.connectedDevices,
    required this.totalBufferSize,
    required this.droppedFrames,
    required this.clockOffset,
  });
}
