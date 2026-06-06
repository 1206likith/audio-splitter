import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/connected_device.dart';
import '../models/audio_stream.dart';
import '../services/settings_service.dart';

class AppStateProvider extends ChangeNotifier {
  final SettingsService _settingsService;

  /// Guards against [notifyListeners] firing after the provider is disposed.
  /// In production the top-level provider lives for the whole app lifetime, so
  /// this never trips; it protects the async [_loadSettings] callback during
  /// widget-test teardown, where each test disposes its own provider.
  bool _disposed = false;

  AppStateProvider({SettingsService? settingsService})
      : _settingsService = settingsService ?? SettingsService() {
    _loadSettings();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  Future<void> _loadSettings() async {
    final port = await _settingsService.loadPort(defaultPort: _port);
    final qualityName =
        await _settingsService.loadQuality(defaultQuality: 'high');
    if (_disposed) return;
    final quality = AudioQuality.values.firstWhere(
      (q) => q.name == qualityName,
      orElse: () => AudioQuality.high,
    );
    _port = port;
    _audioQuality = quality;

    try {
      final prefs = await SharedPreferences.getInstance();
      if (_disposed) return;
      _stereo = prefs.getBool('stereo') ?? true;
      _bufferSizeMs = prefs.getInt('bufferSizeMs') ?? 120;
      _showDiagnostics = prefs.getBool('show_diagnostics') ?? false;
    } catch (e) {
      debugPrint('Error loading stereo/buffer settings: $e');
    }

    if (_disposed) return;
    notifyListeners();
  }

  // App mode - Host or Client
  AppMode _mode = AppMode.host;
  AppMode get mode => _mode;

  // Connected devices
  final List<ConnectedDevice> _connectedDevices = [];
  List<ConnectedDevice> get connectedDevices =>
      List.unmodifiable(_connectedDevices);

  // Available devices for connection
  final List<ConnectedDevice> _availableDevices = [];
  List<ConnectedDevice> get availableDevices =>
      List.unmodifiable(_availableDevices);

  // Audio streams
  final List<AudioStream> _audioStreams = [];
  List<AudioStream> get audioStreams => List.unmodifiable(_audioStreams);

  // Current active stream
  AudioStream? _activeStream;
  AudioStream? get activeStream => _activeStream;

  // Connection status
  bool _isHosting = false;
  bool get isHosting => _isHosting;

  bool _isConnectedToHost = false;
  bool get isConnectedToHost => _isConnectedToHost;

  bool _connectionAttempted = false;
  bool get connectionAttempted => _connectionAttempted;

  // Host information
  String? _hostAddress;
  String? get hostAddress => _hostAddress;

  String? _hostName;
  String? get hostName => _hostName;

  // Network quality metrics
  int _currentLatencyMs = 0;
  int get currentLatencyMs => _currentLatencyMs;

  double _jitter = 0.0;
  double get jitter => _jitter;

  // Audio settings
  AudioSource _selectedAudioSource = AudioSource.microphone;
  AudioSource get selectedAudioSource => _selectedAudioSource;

  AudioQuality _audioQuality = AudioQuality.high;
  AudioQuality get audioQuality => _audioQuality;

  double _volume = 1.0;
  double get volume => _volume;

  bool _isMuted = false;
  bool get isMuted => _isMuted;

  // Network settings
  int _port = 8080;
  int get port => _port;

  // Developer settings
  bool _showDiagnostics = false;
  bool get showDiagnostics => _showDiagnostics;

  // Audio channel settings
  bool _stereo = true;
  bool get stereo => _stereo;

  int _bufferSizeMs = 120;
  int get bufferSizeMs => _bufferSizeMs;

  // Streaming source URL
  String _streamingUrl = '';
  String get streamingUrl => _streamingUrl;

  // Methods to update app mode
  void setMode(AppMode newMode) {
    if (_mode != newMode) {
      _mode = newMode;
      _resetConnectionState();
      notifyListeners();
    }
  }

  // Device management
  void addConnectedDevice(ConnectedDevice device) {
    final existingIndex =
        _connectedDevices.indexWhere((d) => d.id == device.id);
    if (existingIndex != -1) {
      _connectedDevices[existingIndex] = device;
    } else {
      _connectedDevices.add(device);
    }
    notifyListeners();
  }

  void removeConnectedDevice(String deviceId) {
    _connectedDevices.removeWhere((device) => device.id == deviceId);
    notifyListeners();
  }

  void updateDeviceConnection(String deviceId, bool isConnected) {
    final deviceIndex = _connectedDevices.indexWhere((d) => d.id == deviceId);
    if (deviceIndex != -1) {
      _connectedDevices[deviceIndex] = _connectedDevices[deviceIndex].copyWith(
        isConnected: isConnected,
      );
      notifyListeners();
    }
  }

  void addAvailableDevice(ConnectedDevice device) {
    if (!_availableDevices.any((d) => d.id == device.id)) {
      _availableDevices.add(device);
      notifyListeners();
    }
  }

  void removeAvailableDevice(String deviceId) {
    _availableDevices.removeWhere((device) => device.id == deviceId);
    notifyListeners();
  }

  void clearAvailableDevices() {
    _availableDevices.clear();
    notifyListeners();
  }

  // Audio stream management
  void addAudioStream(AudioStream stream) {
    final existingIndex = _audioStreams.indexWhere((s) => s.id == stream.id);
    if (existingIndex != -1) {
      _audioStreams[existingIndex] = stream;
    } else {
      _audioStreams.add(stream);
    }
    notifyListeners();
  }

  void removeAudioStream(String streamId) {
    _audioStreams.removeWhere((stream) => stream.id == streamId);
    if (_activeStream?.id == streamId) {
      _activeStream = null;
    }
    notifyListeners();
  }

  void setActiveStream(AudioStream? stream) {
    _activeStream = stream;
    notifyListeners();
  }

  void updateStreamActivity(String streamId, bool isActive) {
    final streamIndex = _audioStreams.indexWhere((s) => s.id == streamId);
    if (streamIndex != -1) {
      _audioStreams[streamIndex] = _audioStreams[streamIndex].copyWith(
        isActive: isActive,
      );
      if (_activeStream?.id == streamId) {
        _activeStream = _audioStreams[streamIndex];
      }
      notifyListeners();
    }
  }

  // Connection management
  void setHosting(bool hosting) {
    _isHosting = hosting;
    if (!hosting) {
      _connectedDevices.clear();
    }
    notifyListeners();
  }

  void setConnectedToHost(bool connected,
      {String? hostAddress, String? hostName}) {
    _isConnectedToHost = connected;
    _hostAddress = connected ? hostAddress : null;
    _hostName = connected ? hostName : null;
    if (connected) _connectionAttempted = true;
    notifyListeners();
  }

  void updateNetworkMetrics({required int latencyMs, required double jitter}) {
    _currentLatencyMs = latencyMs;
    _jitter = jitter;
    notifyListeners();
  }

  String get connectionQuality {
    if (_currentLatencyMs <= 0) return 'Unknown';
    if (_currentLatencyMs < 30 && _jitter < 5) return 'Excellent';
    if (_currentLatencyMs < 60 && _jitter < 10) return 'Good';
    if (_currentLatencyMs < 100 && _jitter < 20) return 'Fair';
    return 'Poor';
  }

  // Settings
  void setSelectedAudioSource(AudioSource source) {
    _selectedAudioSource = source;
    notifyListeners();
  }

  void setAudioQuality(AudioQuality quality) {
    _audioQuality = quality;
    notifyListeners();
    _settingsService.saveQuality(quality.name);
  }

  void setVolume(double volume) {
    _volume = volume.clamp(0.0, 1.0);
    notifyListeners();
  }

  void setMuted(bool muted) {
    _isMuted = muted;
    notifyListeners();
  }

  void setPort(int port) {
    _port = port;
    notifyListeners();
    _settingsService.savePort(port);
  }

  void setStereo(bool stereo) {
    _stereo = stereo;
    notifyListeners();
    SharedPreferences.getInstance().then((prefs) {
      prefs.setBool('stereo', stereo);
    }).catchError((Object e) {
      debugPrint('Error saving stereo setting: $e');
    });
  }

  void setBufferSizeMs(int ms) {
    _bufferSizeMs = ms;
    notifyListeners();
    SharedPreferences.getInstance().then((prefs) {
      prefs.setInt('bufferSizeMs', ms);
    }).catchError((Object e) {
      debugPrint('Error saving bufferSizeMs setting: $e');
    });
  }

  void setStreamingUrl(String url) {
    _streamingUrl = url;
    notifyListeners();
  }

  Future<void> setShowDiagnostics(bool value) async {
    _showDiagnostics = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('show_diagnostics', value);
  }

  // Utility methods
  void _resetConnectionState() {
    _isHosting = false;
    _isConnectedToHost = false;
    _connectionAttempted = false;
    _hostAddress = null;
    _hostName = null;
    _currentLatencyMs = 0;
    _jitter = 0.0;
    _connectedDevices.clear();
    _availableDevices.clear();
    _audioStreams.clear();
    _activeStream = null;
    _selectedAudioSource = AudioSource.microphone;
  }

  int get connectedDeviceCount =>
      _connectedDevices.where((d) => d.isConnected).length;

  bool get hasActiveConnections =>
      connectedDeviceCount > 0 || _isConnectedToHost;

  bool get canStartStreaming => _mode == AppMode.host && _isHosting;

  bool get hasClientsForStreaming => connectedDeviceCount > 0;
}

enum AppMode {
  host,
  client,
}
