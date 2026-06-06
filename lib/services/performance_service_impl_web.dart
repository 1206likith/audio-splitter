import 'dart:async';
import 'package:flutter/foundation.dart';

// Web-safe stub implementation to avoid dart:io and native MethodChannels
class PerformanceService {
  static final PerformanceService _instance = PerformanceService._internal();
  factory PerformanceService() => _instance;
  PerformanceService._internal();

  final StreamController<PerformanceMetrics> _metricsController =
      StreamController<PerformanceMetrics>.broadcast();
  Stream<PerformanceMetrics> get metricsStream => _metricsController.stream;

  final StreamController<OptimizationSuggestion> _suggestionController =
      StreamController<OptimizationSuggestion>.broadcast();
  Stream<OptimizationSuggestion> get suggestionStream =>
      _suggestionController.stream;

  bool _isInitialized = false;
  bool get isInitialized => _isInitialized;

  Future<void> initialize() async {
    if (_isInitialized) return;
    // On web, we publish minimal metrics periodically
    Timer.periodic(const Duration(seconds: 3), (_) {
      const metrics = PerformanceMetrics(
        cpuUsage: 0.0,
        memoryUsage: 0.0,
        networkThroughput: 0,
        averageLatency: 0.0,
        batteryLevel: 100.0,
        thermalState: ThermalState.normal,
      );
      _metricsController.add(metrics);
    });
    _isInitialized = true;
  }

  void dispose() {
    _metricsController.close();
    _suggestionController.close();
    _isInitialized = false;
  }

  // Stubs
  Uint8List optimizeAudioData(
          Uint8List audioData, PerformanceMetrics metrics) =>
      audioData;
  void updateNetworkStats(int bytesTransmitted, int bytesReceived) {}
  void recordAudioLatency(double latency) {}

  bool get isLowPowerMode => false;
  bool get isAdaptiveQualityEnabled => true;
  bool get isBufferOptimizationEnabled => true;

  double get averageCPUUsage => 0.0;
  double get averageMemoryUsage => 0.0;
  int get totalNetworkThroughput => 0;

  Map<String, dynamic> getPerformanceReport() => {
        'averageCPUUsage': 0.0,
        'averageMemoryUsage': 0.0,
        'totalNetworkThroughput': 0,
        'averageLatency': 0.0,
        'isLowPowerMode': false,
        'isAdaptiveQualityEnabled': true,
        'optimizationsApplied': <String>[],
      };
}

class PerformanceMetrics {
  final double cpuUsage;
  final double memoryUsage;
  final int networkThroughput;
  final double averageLatency;
  final double batteryLevel;
  final ThermalState thermalState;
  const PerformanceMetrics({
    required this.cpuUsage,
    required this.memoryUsage,
    required this.networkThroughput,
    required this.averageLatency,
    required this.batteryLevel,
    required this.thermalState,
  });
}

class OptimizationSuggestion {
  final SuggestionType type;
  final String message;
  final ImpactLevel impact;
  final VoidCallback? action;
  const OptimizationSuggestion({
    required this.type,
    required this.message,
    required this.impact,
    this.action,
  });
}

enum SuggestionType {
  reduceQuality,
  optimizeBuffers,
  adaptiveQuality,
  powerSaving,
  thermalThrottling
}

enum ImpactLevel { low, medium, high, critical }

enum ThermalState { normal, fair, serious, critical }
