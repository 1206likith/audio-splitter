import 'dart:async';
import 'package:flutter/foundation.dart';
import '../asp2/security/permissions.dart';
import '../asp2/security/recording_consent.dart';
import '../asp2/record/stem_recorder.dart';
import '../models/connected_device.dart';
import '../models/audio_stream.dart' show AudioQuality;

// ---------------------------------------------------------------------------
// ClientStats — stub for web (no live connections possible).
// ---------------------------------------------------------------------------
class ClientStats {
  final DateTime connectedAt = DateTime.now();
  int bytesSent = 0;
  int packetsSent = 0;

  Duration get duration => DateTime.now().difference(connectedAt);
  double get kbps => 0;
}

// ---------------------------------------------------------------------------
// BroadcastRoom — stub for web.
// ---------------------------------------------------------------------------
class BroadcastRoom {
  String id;
  String name;
  int port;
  String? pin;

  BroadcastRoom({
    required this.id,
    required this.name,
    required this.port,
    this.pin,
  });

  bool get isActive => false;
  int get clientCount => 0;
}

// ---------------------------------------------------------------------------
// StreamingService — web no-op stub.
// ---------------------------------------------------------------------------
class StreamingService with ChangeNotifier {
  static final StreamingService _instance = StreamingService._internal();
  factory StreamingService() => _instance;
  StreamingService._internal();

  // Stream controllers
  final StreamController<Uint8List> _audioDataController =
      StreamController<Uint8List>.broadcast();
  Stream<Uint8List> get audioDataStream => _audioDataController.stream;

  final StreamController<Map<String, dynamic>> _audioPacketController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get audioPacketStream =>
      _audioPacketController.stream;

  final StreamController<ConnectedDevice> _deviceConnectedController =
      StreamController<ConnectedDevice>.broadcast();
  Stream<ConnectedDevice> get deviceConnectedStream =>
      _deviceConnectedController.stream;

  final StreamController<String> _deviceDisconnectedController =
      StreamController<String>.broadcast();
  Stream<String> get deviceDisconnectedStream =>
      _deviceDisconnectedController.stream;

  final StreamController<Map<String, dynamic>> _messageController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get messageStream => _messageController.stream;

  final StreamController<int> _latencyMsController =
      StreamController<int>.broadcast();
  Stream<int> get latencyStream => _latencyMsController.stream;

  final StreamController<Uint8List> _scheduledAudioController =
      StreamController<Uint8List>.broadcast();
  Stream<Uint8List> get scheduledAudioStream =>
      _scheduledAudioController.stream;

  final StreamController<bool> _connectionStateController =
      StreamController<bool>.broadcast();
  Stream<bool> get connectionStateStream => _connectionStateController.stream;

  final StreamController<Map<String, dynamic>> _discoveredHostController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get discoveredHostStream =>
      _discoveredHostController.stream;

  // Getters
  bool get isHosting => false;
  bool get isConnectedAsClient => false;
  List<String> get connectedClientIds => const [];
  int get connectedClientCount => 0;
  String? get hostAddress => null;
  int get port => 8080;
  bool get isPinProtected => false;
  bool get useBinaryTransport => false;
  bool get encryptionEnabled => false;
  String? get encryptionKeyHex => null;
  bool get loopbackTestEnabled => false;
  String get webClientUrl => '';
  AudioQuality get currentQuality => AudioQuality.ultra;
  bool get useAsp2Wire => false;

  ClientStats? getClientStats(String clientId) => null;
  Map<String, ClientStats> get allClientStats => const {};
  Map<String, BroadcastRoom> get activeRooms => const {};

  // --- ASP-2 public API ---
  final RecordingConsent _consent = RecordingConsent();
  RecordingConsent get recordingConsent => _consent;

  bool get isMultiStemRecording => false;

  Role clientRole(String clientId) => Role.listener;

  bool canClientDo(String clientId, Capability cap) => false;

  void setUseAsp2Wire(bool value) {}

  void setClientRole(String clientId, Role role) {}

  void setClientConsent(String clientId, bool granted) {
    _consent.setConsent(clientId, granted);
  }

  bool startMultiStemRecording(String sessionName, int nowUs) => false;

  RecordedSession? stopMultiStemRecording() => null;

  // Host methods
  Future<bool> startHosting({int port = 8080}) async => false;

  Future<void> stopHosting() async {}

  Future<bool> startRoom(
    String id, {
    required String name,
    required int port,
    String? pin,
  }) async =>
      false;

  Future<void> stopRoom(String id) async {}

  bool isRoomActive(String id) => false;

  void enableEncryption() {}

  void disableEncryption() {}

  void setHostPin(String? pin) {}

  void sendVolumeToClient(String clientId, double volume) {}

  void sendPinToHost(String pin) {}

  void broadcastAudioData(Uint8List audioData) {}

  void broadcastMessage(Map<String, dynamic> message) {}

  // Client methods
  Future<bool> connectToHost(String hostAddress, {int port = 8080}) async =>
      false;

  Future<void> disconnectFromHost() async {}

  void requestAudioConfig() {}

  void setSyncService(dynamic syncService) {}

  void setLoopbackTest(bool enabled) {}

  void setUseBinaryTransport(bool enabled) {}

  Future<void> scanForHosts({int port = 8080}) async {}

  @override
  Future<void> dispose() async {
    super.dispose();
    await _audioDataController.close();
    await _audioPacketController.close();
    await _scheduledAudioController.close();
    await _deviceConnectedController.close();
    await _deviceDisconnectedController.close();
    await _messageController.close();
    await _latencyMsController.close();
    await _connectionStateController.close();
    await _discoveredHostController.close();
  }
}
