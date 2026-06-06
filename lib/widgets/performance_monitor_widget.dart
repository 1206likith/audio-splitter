import 'package:flutter/material.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import '../services/performance_service.dart';
import '../services/sync_service.dart';

class PerformanceMonitorWidget extends StatefulWidget {
  const PerformanceMonitorWidget({super.key});

  @override
  State<PerformanceMonitorWidget> createState() =>
      _PerformanceMonitorWidgetState();
}

class _PerformanceMonitorWidgetState extends State<PerformanceMonitorWidget>
    with TickerProviderStateMixin {
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  PerformanceMetrics? _currentMetrics;
  SyncStats? _currentSyncStats;
  bool _showDetails = false;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      duration: const Duration(milliseconds: 1000),
      vsync: this,
    );
    _pulseAnimation = Tween<double>(begin: 0.8, end: 1.2).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    _pulseController.repeat(reverse: true);

    _setupListeners();
  }

  void _setupListeners() {
    final performanceService = PerformanceService();
    final syncService = SyncService();

    performanceService.metricsStream.listen((metrics) {
      if (mounted) {
        setState(() {
          _currentMetrics = metrics;
        });
      }
    });

    syncService.syncStatsStream.listen((stats) {
      if (mounted) {
        setState(() {
          _currentSyncStats = stats;
        });
      }
    });

    performanceService.suggestionStream.listen((suggestion) {
      if (mounted) {
        _showOptimizationSuggestion(suggestion);
      }
    });
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_currentMetrics == null && _currentSyncStats == null) {
      return const SizedBox.shrink();
    }

    return GestureDetector(
      onTap: () {
        setState(() {
          _showDetails = !_showDetails;
        });
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        height: _showDetails ? 200 : 60,
        margin: const EdgeInsets.all(8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: _getOverallHealthColor().withValues(alpha: 0.3),
          ),
          boxShadow: [
            BoxShadow(
              color: _getOverallHealthColor().withValues(alpha: 0.1),
              blurRadius: 4,
              spreadRadius: 1,
            ),
          ],
        ),
        child: Column(
          children: [
            // Header row
            Row(
              children: [
                AnimatedBuilder(
                  animation: _pulseAnimation,
                  builder: (context, child) {
                    return Transform.scale(
                      scale: _pulseAnimation.value,
                      child: Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          color: _getOverallHealthColor(),
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: _getOverallHealthColor()
                                  .withValues(alpha: 0.5),
                              blurRadius: 4,
                              spreadRadius: 1,
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(width: 12),
                Icon(
                  MdiIcons.speedometer,
                  size: 20,
                  color: _getOverallHealthColor(),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _getOverallStatusText(),
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: _getOverallHealthColor(),
                    ),
                  ),
                ),
                _buildQuickMetrics(),
                Icon(
                  _showDetails ? Icons.expand_less : Icons.expand_more,
                  color: Colors.grey,
                ),
              ],
            ),

            // Details section
            if (_showDetails) ...[
              const SizedBox(height: 16),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      if (_currentMetrics != null) ...[
                        _buildPerformanceMetrics(_currentMetrics!),
                        const SizedBox(height: 12),
                      ],
                      if (_currentSyncStats != null) ...[
                        _buildSyncMetrics(_currentSyncStats!),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildQuickMetrics() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_currentMetrics != null) ...[
          _buildQuickMetric(
            icon: MdiIcons.memory,
            value: '${_currentMetrics!.cpuUsage.toInt()}%',
            color: _getCPUColor(_currentMetrics!.cpuUsage),
          ),
          const SizedBox(width: 8),
        ],
        if (_currentSyncStats != null) ...[
          _buildQuickMetric(
            icon: MdiIcons.timer,
            value: '${_currentSyncStats!.averageLatency.toInt()}ms',
            color: _getLatencyColor(_currentSyncStats!.averageLatency),
          ),
          const SizedBox(width: 8),
        ],
      ],
    );
  }

  Widget _buildQuickMetric({
    required IconData icon,
    required String value,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(
            value,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPerformanceMetrics(PerformanceMetrics metrics) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Performance Metrics',
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _buildMetricBar(
                'CPU',
                metrics.cpuUsage,
                '%',
                _getCPUColor(metrics.cpuUsage),
                MdiIcons.memory,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _buildMetricBar(
                'Memory',
                metrics.memoryUsage,
                '%',
                _getMemoryColor(metrics.memoryUsage),
                MdiIcons.harddisk,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _buildMetricInfo(
                'Network',
                '${(metrics.networkThroughput / 1024).toStringAsFixed(1)} KB/s',
                MdiIcons.networkOutline,
                _getNetworkColor(metrics.networkThroughput),
              ),
            ),
            Expanded(
              child: _buildMetricInfo(
                'Battery',
                '${metrics.batteryLevel.toInt()}%',
                MdiIcons.battery,
                _getBatteryColor(metrics.batteryLevel),
              ),
            ),
            Expanded(
              child: _buildMetricInfo(
                'Thermal',
                _getThermalText(metrics.thermalState),
                MdiIcons.thermometer,
                _getThermalColor(metrics.thermalState),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildSyncMetrics(SyncStats stats) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Synchronization Metrics',
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _buildMetricInfo(
                'Latency',
                '${stats.averageLatency.toStringAsFixed(1)}ms',
                MdiIcons.timer,
                _getLatencyColor(stats.averageLatency),
              ),
            ),
            Expanded(
              child: _buildMetricInfo(
                'Jitter',
                '${stats.jitter.toStringAsFixed(1)}ms',
                MdiIcons.waveform,
                _getJitterColor(stats.jitter),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: _buildMetricInfo(
                'Devices',
                '${stats.connectedDevices}',
                MdiIcons.devices,
                Colors.blue,
              ),
            ),
            Expanded(
              child: _buildMetricInfo(
                'Buffer',
                '${stats.totalBufferSize}',
                MdiIcons.database,
                Colors.orange,
              ),
            ),
            Expanded(
              child: _buildMetricInfo(
                'Dropped',
                '${stats.droppedFrames}',
                MdiIcons.alertCircle,
                stats.droppedFrames > 0 ? Colors.red : Colors.green,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildMetricBar(
    String label,
    double value,
    String unit,
    Color color,
    IconData icon,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: Colors.grey[600],
              ),
            ),
            const Spacer(),
            Text(
              '${value.toInt()}$unit',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        LinearProgressIndicator(
          value: value / 100,
          backgroundColor: Colors.grey.withValues(alpha: 0.2),
          valueColor: AlwaysStoppedAnimation<Color>(color),
        ),
      ],
    );
  }

  Widget _buildMetricInfo(
    String label,
    String value,
    IconData icon,
    Color color,
  ) {
    return Column(
      children: [
        Icon(icon, size: 20, color: color),
        const SizedBox(height: 2),
        Text(
          label,
          style: TextStyle(
            fontSize: 10,
            color: Colors.grey[600],
          ),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
      ],
    );
  }

  void _showOptimizationSuggestion(OptimizationSuggestion suggestion) {
    final color = _getImpactColor(suggestion.impact);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(
              _getImpactIcon(suggestion.impact),
              color: Colors.white,
              size: 20,
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(suggestion.message)),
          ],
        ),
        backgroundColor: color,
        behavior: SnackBarBehavior.floating,
        action: suggestion.action != null
            ? SnackBarAction(
                label: 'Apply',
                textColor: Colors.white,
                onPressed: suggestion.action!,
              )
            : null,
      ),
    );
  }

  // Color helpers
  Color _getOverallHealthColor() {
    if (_currentMetrics == null) return Colors.grey;

    final metrics = _currentMetrics!;
    if (metrics.cpuUsage > 80 ||
        metrics.memoryUsage > 85 ||
        metrics.thermalState == ThermalState.critical) {
      return Colors.red;
    } else if (metrics.cpuUsage > 60 ||
        metrics.memoryUsage > 70 ||
        metrics.thermalState == ThermalState.serious) {
      return Colors.orange;
    } else {
      return Colors.green;
    }
  }

  String _getOverallStatusText() {
    if (_currentMetrics == null) return 'Performance Monitor';

    final color = _getOverallHealthColor();
    if (color == Colors.red) {
      return 'Performance Issues Detected';
    } else if (color == Colors.orange) {
      return 'Performance Warning';
    } else {
      return 'Performance Optimal';
    }
  }

  Color _getCPUColor(double cpu) {
    if (cpu > 80) return Colors.red;
    if (cpu > 60) return Colors.orange;
    return Colors.green;
  }

  Color _getMemoryColor(double memory) {
    if (memory > 85) return Colors.red;
    if (memory > 70) return Colors.orange;
    return Colors.green;
  }

  Color _getNetworkColor(int throughput) {
    if (throughput < 10000) return Colors.red;
    if (throughput < 50000) return Colors.orange;
    return Colors.green;
  }

  Color _getBatteryColor(double battery) {
    if (battery < 20) return Colors.red;
    if (battery < 50) return Colors.orange;
    return Colors.green;
  }

  Color _getThermalColor(ThermalState state) {
    switch (state) {
      case ThermalState.normal:
        return Colors.green;
      case ThermalState.fair:
        return Colors.yellow;
      case ThermalState.serious:
        return Colors.orange;
      case ThermalState.critical:
        return Colors.red;
    }
  }

  String _getThermalText(ThermalState state) {
    switch (state) {
      case ThermalState.normal:
        return 'Normal';
      case ThermalState.fair:
        return 'Fair';
      case ThermalState.serious:
        return 'Hot';
      case ThermalState.critical:
        return 'Critical';
    }
  }

  Color _getLatencyColor(double latency) {
    if (latency > 150) return Colors.red;
    if (latency > 100) return Colors.orange;
    if (latency > 50) return Colors.yellow;
    return Colors.green;
  }

  Color _getJitterColor(double jitter) {
    if (jitter > 30) return Colors.red;
    if (jitter > 20) return Colors.orange;
    if (jitter > 10) return Colors.yellow;
    return Colors.green;
  }

  Color _getImpactColor(ImpactLevel impact) {
    switch (impact) {
      case ImpactLevel.low:
        return Colors.blue;
      case ImpactLevel.medium:
        return Colors.orange;
      case ImpactLevel.high:
        return Colors.red;
      case ImpactLevel.critical:
        return Colors.purple;
    }
  }

  IconData _getImpactIcon(ImpactLevel impact) {
    switch (impact) {
      case ImpactLevel.low:
        return MdiIcons.informationOutline;
      case ImpactLevel.medium:
        return MdiIcons.alertOutline;
      case ImpactLevel.high:
        return MdiIcons.alert;
      case ImpactLevel.critical:
        return MdiIcons.alertCircle;
    }
  }
}
