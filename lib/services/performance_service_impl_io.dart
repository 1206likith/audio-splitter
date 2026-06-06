import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class PerformanceService {
  static final PerformanceService _instance = PerformanceService._internal();
  factory PerformanceService() => _instance;
  PerformanceService._internal();

  // Performance monitoring
  final List<double> _cpuUsageHistory = [];
  final List<double> _memoryUsageHistory = [];
  final List<int> _networkThroughputHistory = [];
  final List<double> _audioLatencyHistory = [];

  Timer? _monitoringTimer;
  int _totalBytesTransmitted = 0;
  int _totalBytesReceived = 0;
  DateTime? _lastNetworkMeasurement;

  // Performance optimization flags
  bool _isLowPowerMode = false;
  bool _isAdaptiveQualityEnabled = true;
  final bool _isBufferOptimizationEnabled = true;

  // Stream controllers
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

    // Start performance monitoring
    _monitoringTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      _collectMetrics();
    });

    // Initialize platform-specific optimizations
    await _initializePlatformOptimizations();

    _isInitialized = true;
  }

  void dispose() {
    _monitoringTimer?.cancel();
    _metricsController.close();
    _suggestionController.close();
    _isInitialized = false;
  }

  // Platform-specific optimizations
  Future<void> _initializePlatformOptimizations() async {
    if (Platform.isAndroid) {
      await _initializeAndroidOptimizations();
    } else if (Platform.isIOS) {
      await _initializeIOSOptimizations();
    } else if (Platform.isWindows) {
      await _initializeWindowsOptimizations();
    }
  }

  Future<void> _initializeAndroidOptimizations() async {
    try {
      // Request high performance mode
      const platform = MethodChannel('audio_splitter/performance');
      await platform.invokeMethod('enableHighPerformanceMode');

      // Optimize audio routing
      await platform.invokeMethod('optimizeAudioRouting');

      // Request wake lock for consistent performance
      await platform.invokeMethod('acquireWakeLock');
    } catch (e) {
      debugPrint('Android optimization error: $e');
    }
  }

  Future<void> _initializeIOSOptimizations() async {
    try {
      const platform = MethodChannel('audio_splitter/performance');

      // Configure audio session for low latency
      await platform.invokeMethod('configureAudioSession', {
        'category': 'playAndRecord',
        'mode': 'measurement',
        'options': ['allowBluetooth', 'defaultToSpeaker']
      });

      // Enable hardware acceleration
      await platform.invokeMethod('enableHardwareAcceleration');
    } catch (e) {
      debugPrint('iOS optimization error: $e');
    }
  }

  Future<void> _initializeWindowsOptimizations() async {
    try {
      const platform = MethodChannel('audio_splitter/performance');

      // Set process priority
      await platform.invokeMethod('setProcessPriority', {'priority': 'high'});

      // Configure WASAPI for low latency
      await platform.invokeMethod(
          'configureWASAPI', {'bufferSize': 128, 'sampleRate': 44100});
    } catch (e) {
      debugPrint('Windows optimization error: $e');
    }
  }

  // Performance monitoring
  Future<void> _collectMetrics() async {
    try {
      final cpuUsage = await _getCPUUsage();
      final memoryUsage = await _getMemoryUsage();
      final networkThroughput = _calculateNetworkThroughput();

      _cpuUsageHistory.add(cpuUsage);
      _memoryUsageHistory.add(memoryUsage);
      _networkThroughputHistory.add(networkThroughput);

      // Keep only recent history
      const maxHistoryLength = 30; // 1 minute of data
      if (_cpuUsageHistory.length > maxHistoryLength) {
        _cpuUsageHistory.removeAt(0);
        _memoryUsageHistory.removeAt(0);
        _networkThroughputHistory.removeAt(0);
      }

      final metrics = PerformanceMetrics(
        cpuUsage: cpuUsage,
        memoryUsage: memoryUsage,
        networkThroughput: networkThroughput,
        averageLatency: _getAverageLatency(),
        batteryLevel: await _getBatteryLevel(),
        thermalState: await _getThermalState(),
      );

      _metricsController.add(metrics);

      // Generate optimization suggestions
      _analyzePerformanceAndSuggest(metrics);
    } catch (e) {
      debugPrint('Error collecting metrics: $e');
    }
  }

  Future<double> _getCPUUsage() async {
    try {
      const platform = MethodChannel('audio_splitter/performance');
      final usage = await platform.invokeMethod('getCPUUsage');
      return usage?.toDouble() ?? 0.0;
    } catch (e) {
      return 0.0;
    }
  }

  Future<double> _getMemoryUsage() async {
    try {
      const platform = MethodChannel('audio_splitter/performance');
      final usage = await platform.invokeMethod('getMemoryUsage');
      return usage?.toDouble() ?? 0.0;
    } catch (e) {
      return 0.0;
    }
  }

  int _calculateNetworkThroughput() {
    final now = DateTime.now();
    if (_lastNetworkMeasurement == null) {
      _lastNetworkMeasurement = now;
      return 0;
    }

    final timeDiff = now.difference(_lastNetworkMeasurement!).inSeconds;
    if (timeDiff == 0) return 0;

    final throughput =
        (_totalBytesTransmitted + _totalBytesReceived) ~/ timeDiff;
    _lastNetworkMeasurement = now;

    return throughput;
  }

  double _getAverageLatency() {
    if (_audioLatencyHistory.isEmpty) return 0.0;
    return _audioLatencyHistory.reduce((a, b) => a + b) /
        _audioLatencyHistory.length;
  }

  Future<double> _getBatteryLevel() async {
    try {
      const platform = MethodChannel('audio_splitter/performance');
      final level = await platform.invokeMethod('getBatteryLevel');
      return level?.toDouble() ?? 100.0;
    } catch (e) {
      return 100.0;
    }
  }

  Future<ThermalState> _getThermalState() async {
    try {
      const platform = MethodChannel('audio_splitter/performance');
      final state = await platform.invokeMethod('getThermalState');
      return ThermalState.values.firstWhere(
        (e) => e.toString().split('.').last == state,
        orElse: () => ThermalState.normal,
      );
    } catch (e) {
      return ThermalState.normal;
    }
  }

  // Performance optimization
  void _analyzePerformanceAndSuggest(PerformanceMetrics metrics) {
    final suggestions = <OptimizationSuggestion>[];

    // CPU usage analysis
    if (metrics.cpuUsage > 80) {
      suggestions.add(OptimizationSuggestion(
        type: SuggestionType.reduceQuality,
        message: 'High CPU usage detected. Consider reducing audio quality.',
        impact: ImpactLevel.high,
        action: () => _enableLowPowerMode(),
      ));
    }

    // Memory usage analysis
    if (metrics.memoryUsage > 85) {
      suggestions.add(OptimizationSuggestion(
        type: SuggestionType.optimizeBuffers,
        message: 'High memory usage. Optimizing audio buffers.',
        impact: ImpactLevel.medium,
        action: () => _optimizeMemoryUsage(),
      ));
    }

    // Network throughput analysis
    if (metrics.networkThroughput < 50000 && metrics.averageLatency > 100) {
      suggestions.add(OptimizationSuggestion(
        type: SuggestionType.adaptiveQuality,
        message: 'Poor network conditions. Enabling adaptive quality.',
        impact: ImpactLevel.medium,
        action: () => _enableAdaptiveQuality(),
      ));
    }

    // Battery level analysis
    if (metrics.batteryLevel < 20) {
      suggestions.add(OptimizationSuggestion(
        type: SuggestionType.powerSaving,
        message: 'Low battery. Enabling power saving mode.',
        impact: ImpactLevel.high,
        action: () => _enablePowerSavingMode(),
      ));
    }

    // Thermal state analysis
    if (metrics.thermalState == ThermalState.critical) {
      suggestions.add(OptimizationSuggestion(
        type: SuggestionType.thermalThrottling,
        message: 'Device overheating. Reducing performance to cool down.',
        impact: ImpactLevel.critical,
        action: () => _enableThermalThrottling(),
      ));
    }

    // Send suggestions
    for (final suggestion in suggestions) {
      _suggestionController.add(suggestion);

      // Auto-apply critical suggestions
      if (suggestion.impact == ImpactLevel.critical) {
        suggestion.action?.call();
      }
    }
  }

  // Optimization actions
  void _enableLowPowerMode() {
    _isLowPowerMode = true;
    // Reduce sample rate, lower quality, fewer connections
  }

  void _optimizeMemoryUsage() {
    // Clear old buffers, reduce buffer sizes
  }

  void _enableAdaptiveQuality() {
    _isAdaptiveQualityEnabled = true;
    // Automatically adjust quality based on network conditions
  }

  void _enablePowerSavingMode() {
    _isLowPowerMode = true;
    // Reduce CPU usage, lower refresh rates
  }

  void _enableThermalThrottling() {
    // Reduce performance to prevent overheating
  }

  // Audio processing optimizations
  Uint8List optimizeAudioData(Uint8List audioData, PerformanceMetrics metrics) {
    if (_isLowPowerMode) {
      return _compressAudioData(audioData);
    }

    if (metrics.cpuUsage > 70) {
      return _reduceAudioComplexity(audioData);
    }

    return audioData;
  }

  Uint8List _compressAudioData(Uint8List audioData) {
    // Implement audio compression for low power mode
    // This is a placeholder - actual implementation would use audio codecs
    return audioData;
  }

  Uint8List _reduceAudioComplexity(Uint8List audioData) {
    // Reduce sample rate or bit depth to lower CPU usage
    // This is a placeholder - actual implementation would process audio
    return audioData;
  }

  // Network optimization
  void updateNetworkStats(int bytesTransmitted, int bytesReceived) {
    _totalBytesTransmitted += bytesTransmitted;
    _totalBytesReceived += bytesReceived;
  }

  void recordAudioLatency(double latency) {
    _audioLatencyHistory.add(latency);
    if (_audioLatencyHistory.length > 50) {
      _audioLatencyHistory.removeAt(0);
    }
  }

  // Performance getters
  bool get isLowPowerMode => _isLowPowerMode;
  bool get isAdaptiveQualityEnabled => _isAdaptiveQualityEnabled;
  bool get isBufferOptimizationEnabled => _isBufferOptimizationEnabled;

  double get averageCPUUsage => _cpuUsageHistory.isEmpty
      ? 0.0
      : _cpuUsageHistory.reduce((a, b) => a + b) / _cpuUsageHistory.length;

  double get averageMemoryUsage => _memoryUsageHistory.isEmpty
      ? 0.0
      : _memoryUsageHistory.reduce((a, b) => a + b) /
          _memoryUsageHistory.length;

  int get totalNetworkThroughput =>
      _totalBytesTransmitted + _totalBytesReceived;

  Map<String, dynamic> getPerformanceReport() {
    return {
      'averageCPUUsage': averageCPUUsage,
      'averageMemoryUsage': averageMemoryUsage,
      'totalNetworkThroughput': totalNetworkThroughput,
      'averageLatency': _getAverageLatency(),
      'isLowPowerMode': _isLowPowerMode,
      'isAdaptiveQualityEnabled': _isAdaptiveQualityEnabled,
      'optimizationsApplied': _getAppliedOptimizations(),
    };
  }

  List<String> _getAppliedOptimizations() {
    final optimizations = <String>[];
    if (_isLowPowerMode) optimizations.add('Low Power Mode');
    if (_isAdaptiveQualityEnabled) optimizations.add('Adaptive Quality');
    if (_isBufferOptimizationEnabled) optimizations.add('Buffer Optimization');
    return optimizations;
  }
}

class PerformanceMetrics {
  final double cpuUsage;
  final double memoryUsage;
  final int networkThroughput;
  final double averageLatency;
  final double batteryLevel;
  final ThermalState thermalState;

  PerformanceMetrics({
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

  OptimizationSuggestion({
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
  thermalThrottling,
}

enum ImpactLevel {
  low,
  medium,
  high,
  critical,
}

enum ThermalState {
  normal,
  fair,
  serious,
  critical,
}
