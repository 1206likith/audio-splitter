import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show Random;
import 'package:flutter/foundation.dart';
import 'sync_service.dart';
import 'mdns_service.dart';
import '../asp2/asp2_config.dart';
import '../asp2/codec/pcm16_codec.dart';
import '../asp2/crypto/crypto_box.dart';
import '../asp2/frame/asp2_frame.dart';
import '../asp2/frame/legacy_frame.dart';
import '../asp2/record/stem_recorder.dart';
import '../asp2/security/permissions.dart';
import '../asp2/security/recording_consent.dart';
import '../asp2/transport/ws_transport.dart';
import '../core/contracts/audio_format.dart';
import '../core/pipeline/audio_chunk.dart';
import '../models/connected_device.dart';
import '../models/audio_stream.dart' show AudioQuality, AudioQualityExtension;

const _webClientHtml = r'''<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Audio Splitter — Web Client</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: system-ui, sans-serif; background: #1a1a2e; color: #eee; display: flex; align-items: center; justify-content: center; min-height: 100vh; }
  .card { background: #16213e; border-radius: 16px; padding: 32px; width: 340px; text-align: center; box-shadow: 0 8px 32px rgba(0,0,0,0.4); }
  h1 { font-size: 1.4rem; margin-bottom: 4px; }
  .subtitle { color: #aaa; font-size: 0.85rem; margin-bottom: 24px; }
  .status { font-size: 0.9rem; padding: 8px 16px; border-radius: 20px; display: inline-block; margin-bottom: 20px; background: #333; }
  .status.connected { background: #1a6b1a; color: #7fff7f; }
  .status.error { background: #6b1a1a; color: #ff7f7f; }
  button { width: 100%; padding: 14px; border: none; border-radius: 10px; font-size: 1rem; font-weight: 600; cursor: pointer; transition: opacity 0.2s; }
  button:hover { opacity: 0.85; }
  #connectBtn { background: #6750a4; color: #fff; }
  #disconnectBtn { background: #c62828; color: #fff; display: none; }
  .vol-row { display: flex; align-items: center; gap: 8px; margin-top: 20px; }
  .vol-row label { font-size: 0.8rem; color: #aaa; white-space: nowrap; }
  input[type=range] { flex: 1; }
  .meter { height: 4px; background: #333; border-radius: 2px; margin-top: 16px; overflow: hidden; }
  .meter-bar { height: 100%; width: 0%; background: #6750a4; border-radius: 2px; transition: width 0.1s; }
  .latency { font-size: 0.75rem; color: #888; margin-top: 12px; }
</style>
</head>
<body>
<div class="card">
  <h1>🎵 Audio Splitter</h1>
  <p class="subtitle">Web Browser Client</p>
  <div class="status" id="status">Disconnected</div>
  <br>
  <button id="connectBtn">Connect to Stream</button>
  <button id="disconnectBtn">Disconnect</button>
  <div class="vol-row">
    <label>🔈</label>
    <input type="range" id="volSlider" min="0" max="1" step="0.05" value="1">
    <label>🔊</label>
  </div>
  <div class="meter"><div class="meter-bar" id="meterBar"></div></div>
  <div class="latency" id="latency"></div>
</div>
<script>
(function() {
  const params = new URLSearchParams(window.location.search);
  const wsHost = params.get('host') || window.location.hostname;
  const wsPort = parseInt(params.get('port') || (parseInt(window.location.port || '8080') + 1));

  let ws = null, ctx = null, gainNode = null, nextPlayTime = 0;
  let connected = false, pingInterval = null;
  let lastPingTime = 0;
  const BUFFER_AHEAD = 0.12;

  let cryptoKey = null, cryptoIV = null;
  async function setupDecryption(keyHex) {
    const parts = keyHex.split(':');
    if (parts.length !== 2) return;
    const keyBytes = new Uint8Array(parts[0].match(/.{2}/g).map(b => parseInt(b, 16)));
    cryptoIV = new Uint8Array(parts[1].match(/.{2}/g).map(b => parseInt(b, 16)));
    cryptoKey = await crypto.subtle.importKey('raw', keyBytes, {name: 'AES-CTR'}, false, ['decrypt']);
  }
  async function decryptFrame(buffer) {
    if (!cryptoKey || !cryptoIV) return new Uint8Array(buffer);
    try {
      const decrypted = await crypto.subtle.decrypt({name: 'AES-CTR', counter: cryptoIV, length: 64}, cryptoKey, buffer);
      return new Uint8Array(decrypted);
    } catch (e) { return new Uint8Array(buffer); }
  }

  const statusEl = document.getElementById('status');
  const connectBtn = document.getElementById('connectBtn');
  const disconnectBtn = document.getElementById('disconnectBtn');
  const volSlider = document.getElementById('volSlider');
  const meterBar = document.getElementById('meterBar');
  const latencyEl = document.getElementById('latency');

  function setStatus(text, cls) {
    statusEl.textContent = text;
    statusEl.className = 'status' + (cls ? ' ' + cls : '');
  }

  function initAudio() {
    ctx = new (window.AudioContext || window.webkitAudioContext)({ sampleRate: 48000 });
    gainNode = ctx.createGain();
    gainNode.gain.value = parseFloat(volSlider.value);
    gainNode.connect(ctx.destination);
    nextPlayTime = ctx.currentTime + BUFFER_AHEAD;
  }

  function connect() {
    try {
      initAudio();
      ctx.resume();
      ws = new WebSocket(`ws://${wsHost}:${wsPort}`);
      ws.binaryType = 'arraybuffer';

      ws.onopen = () => {
        connected = true;
        setStatus('Connected', 'connected');
        connectBtn.style.display = 'none';
        disconnectBtn.style.display = 'block';
        ws.send(JSON.stringify({ type: 'device_info', deviceName: 'Web Browser', deviceType: 'computer', capabilities: ['audio_playback'], timestamp: new Date().toISOString() }));
        ws.send(JSON.stringify({ type: 'audio_request', requestedQuality: 'ultra', requestedFormat: 'pcm16', requestedSampleRate: 48000, requestedChannels: 2 }));
        pingInterval = setInterval(() => {
          lastPingTime = Date.now();
          if (ws && ws.readyState === 1) ws.send(JSON.stringify({ type: 'ping', t0: lastPingTime }));
        }, 2000);
      };

      ws.onmessage = (event) => {
        if (event.data instanceof ArrayBuffer) {
          playFrame(event.data);
        } else {
          try {
            const msg = JSON.parse(event.data);
            if (msg.type === 'welcome' && msg.encryptionEnabled && msg.encryptionKey) {
              setupDecryption(msg.encryptionKey);
            } else if (msg.type === 'pong') {
              const rtt = Date.now() - (msg.t0 || lastPingTime);
              latencyEl.textContent = `Latency: ${rtt}ms`;
            } else if (msg.type === 'set_volume') {
              gainNode.gain.value = Math.max(0, Math.min(1, msg.volume));
              volSlider.value = gainNode.gain.value;
            }
          } catch (_) {}
        }
      };

      ws.onclose = ws.onerror = () => {
        connected = false;
        clearInterval(pingInterval);
        setStatus('Disconnected');
        connectBtn.style.display = 'block';
        disconnectBtn.style.display = 'none';
        latencyEl.textContent = '';
      };
    } catch (e) {
      setStatus('Error: ' + e.message, 'error');
    }
  }

  async function playFrame(buffer) {
    if (!ctx || !gainNode) return;
    const data = await decryptFrame(buffer);
    const dv = new DataView(data.buffer);
    if (data.byteLength < 10 || dv.getUint8(0) !== 1) return;
    const pcm = new Int16Array(data.buffer, 9);
    if (pcm.length < 2) return;

    const numSamples = Math.floor(pcm.length / 2);
    const audioBuf = ctx.createBuffer(2, numSamples, 48000);
    const ch0 = audioBuf.getChannelData(0);
    const ch1 = audioBuf.getChannelData(1);
    let peak = 0;
    for (let i = 0; i < numSamples; i++) {
      ch0[i] = pcm[i * 2] / 32768.0;
      ch1[i] = pcm[i * 2 + 1] / 32768.0;
      const v = Math.abs(ch0[i]);
      if (v > peak) peak = v;
    }
    meterBar.style.width = Math.round(peak * 100) + '%';

    const now = ctx.currentTime;
    const start = Math.max(now + 0.02, nextPlayTime);
    const src = ctx.createBufferSource();
    src.buffer = audioBuf;
    src.connect(gainNode);
    src.start(start);
    nextPlayTime = start + audioBuf.duration;
  }

  connectBtn.addEventListener('click', connect);
  disconnectBtn.addEventListener('click', () => {
    if (ws) ws.close();
  });
  volSlider.addEventListener('input', () => {
    if (gainNode) gainNode.gain.value = parseFloat(volSlider.value);
  });
})();
</script>
</body>
</html>''';

// ---------------------------------------------------------------------------
// BroadcastRoom — an independently served WebSocket room on its own port.
// ---------------------------------------------------------------------------
class BroadcastRoom {
  String id;
  String name;
  int port;
  String? pin;
  HttpServer? server;
  final Map<String, WebSocket> clients = {};

  BroadcastRoom({
    required this.id,
    required this.name,
    required this.port,
    this.pin,
  });

  bool get isActive => server != null;
  int get clientCount => clients.length;
}

// ---------------------------------------------------------------------------
// ClientStats — per-client throughput tracking.
// ---------------------------------------------------------------------------
class ClientStats {
  final DateTime connectedAt;
  int bytesSent;
  int packetsSent;

  ClientStats()
      : connectedAt = DateTime.now(),
        bytesSent = 0,
        packetsSent = 0;

  Duration get duration => DateTime.now().difference(connectedAt);
  double get kbps =>
      duration.inSeconds > 0 ? (bytesSent / 1024.0) / duration.inSeconds : 0;
}

// ---------------------------------------------------------------------------
// StreamingService
// ---------------------------------------------------------------------------
class StreamingService with ChangeNotifier {
  static final StreamingService _instance = StreamingService._internal();
  factory StreamingService() => _instance;
  StreamingService._internal() {
    // Sync RBAC + consent with the device lifecycle so the maps stay accurate
    // without touching every disconnect site.
    _deviceConnectedController.stream.listen((device) {
      _clientRoles.putIfAbsent(device.id, () => Role.listener);
      _consent.join(device.id);
    });
    _deviceDisconnectedController.stream.listen((clientId) {
      _clientRoles.remove(clientId);
      _consent.leave(clientId);
    });
  }

  // Server components
  HttpServer? _httpServer;
  HttpServer? _wsHttpServer;

  // Client components
  WebSocket? _clientWebSocket;

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

  // Latency (RTT) measurements for clients
  final StreamController<int> _latencyMsController =
      StreamController<int>.broadcast();
  Stream<int> get latencyStream => _latencyMsController.stream;

  // Scheduled audio output (client-side)
  final StreamController<Uint8List> _scheduledAudioController =
      StreamController<Uint8List>.broadcast();
  Stream<Uint8List> get scheduledAudioStream =>
      _scheduledAudioController.stream;
  final List<Timer> _pendingPlaybackTimers = [];
  StreamSubscription<Map<String, dynamic>>? _packetSub;
  SyncService? _syncService;
  // Warm-up gating
  bool _schedulerWarmedUp = false;
  int _warmupDeadlineMs = 0;
  static const int _warmupTargetMs = 120; // target initial buffer

  // Client connection state and auto-reconnect
  final StreamController<bool> _connectionStateController =
      StreamController<bool>.broadcast();
  Stream<bool> get connectionStateStream => _connectionStateController.stream;
  bool _manualDisconnect = false;
  String? _lastHostAddress;
  int? _lastHostPort;
  int _reconnectAttempts = 0;

  // Per-client stats
  final Map<String, ClientStats> _clientStats = {};

  // State
  bool _isHosting = false;
  bool _isConnectedAsClient = false;
  final Map<String, WebSocket> _connectedClients = {};
  String? _hostAddress;
  int _port = 8080;
  String? _hostPin;
  Timer? _pingTimer;
  bool _loopbackTest = false;
  bool get loopbackTestEnabled => _loopbackTest;
  static const int _maxAudioFrameBytes = 512 * 1024;

  // --- ASP-2 engine wiring ------------------------------------------------
  // Per-client roles (all clients start as listener; promote via setClientRole).
  final Map<String, Role> _clientRoles = {};
  static const _ac = AccessControl();

  // All-party recording-consent gate.
  final RecordingConsent _consent = RecordingConsent();

  // Multi-stem session recorder — non-null while a recording is running.
  SessionRecorder? _sessionRecorder;

  // Monotonic sequence counter for ASP-2 frames on the media path.
  int _asp2Seq = 0;

  // Pcm16Codec instance (stateless, shared for the ASP-2 path).
  final _pcm16 = Pcm16Codec();

  // Getters
  bool get isHosting => _isHosting;
  bool get isConnectedAsClient => _isConnectedAsClient;
  List<String> get connectedClientIds => _connectedClients.keys.toList();
  int get connectedClientCount => _connectedClients.length;
  String? get hostAddress => _hostAddress;

  ClientStats? getClientStats(String clientId) => _clientStats[clientId];
  Map<String, ClientStats> get allClientStats => Map.unmodifiable(_clientStats);
  int get port => _port;
  bool get isPinProtected => _hostPin != null && _hostPin!.isNotEmpty;
  bool _useBinaryTransport = true;
  bool get useBinaryTransport => _useBinaryTransport;
  final Random _random = Random();

  // Encryption — delegated to the ASP-2 CryptoBox seam (Phase 0.2). The box
  // plays the sender role on the host (seal) and the receiver role on the
  // client (open); the `keyHex:ivHex` exchange string is byte-identical to v1.
  final CryptoBox _cryptoBox = CryptoBox();

  // ASP-2 transport seam (Phase 0.2). Currently owns LAN discovery (subnet
  // scan); the host/client socket lifecycle is migrated onto it incrementally
  // in later sub-steps. Exposed as the target the facade delegates to.
  final WsTransport _wsTransport = WsTransport();

  bool get encryptionEnabled => _cryptoBox.enabled;

  // --- ASP-2 public API ---------------------------------------------------

  /// The current role of a connected client (default: listener).
  Role clientRole(String clientId) => _clientRoles[clientId] ?? Role.listener;

  /// Whether [clientId] is permitted to perform [cap].
  bool canClientDo(String clientId, Capability cap) =>
      _ac.can(clientRole(clientId), cap);

  /// The all-party recording-consent gate. Expose to the UI to build consent
  /// dialogs and check [RecordingConsent.canStartRecording] before arming.
  RecordingConsent get recordingConsent => _consent;

  /// True while a multi-stem session recording is in progress.
  bool get isMultiStemRecording => _sessionRecorder != null;

  /// Expose the current [Asp2Config.useAsp2Wire] flag for the settings UI.
  bool get useAsp2Wire => Asp2Config.useAsp2Wire;

  /// Toggle the ASP-2 native wire format. Changes take effect on the next
  /// audio frame — no session restart required.
  void setUseAsp2Wire(bool value) {
    Asp2Config.useAsp2Wire = value;
    notifyListeners();
  }

  /// Promote or demote [clientId] to [role]. Only the host (admin level) should
  /// call this — RBAC enforcement is up to the calling layer.
  void setClientRole(String clientId, Role role) {
    _clientRoles[clientId] = role;
    notifyListeners();
  }

  /// Record the consent decision for [clientId] on behalf of their UI prompt.
  void setClientConsent(String clientId, bool granted) {
    _consent.setConsent(clientId, granted);
    notifyListeners();
  }

  /// Start a multi-stem session recording. The host acts as the operator (admin)
  /// and their consent is implicit. Returns false if already recording.
  /// [nowUs] is the session start in microseconds (pass
  /// `DateTime.now().microsecondsSinceEpoch`).
  bool startMultiStemRecording(String sessionName, int nowUs) {
    if (_sessionRecorder != null) return false;
    final rec = SessionRecorder(
      sessionName: sessionName,
      sessionStartTsUs: nowUs,
    );
    rec.registerSource('master', 'Master Mix');
    _sessionRecorder = rec;
    notifyListeners();
    return true;
  }

  /// Stop the current multi-stem recording and return the captured session,
  /// or null if no recording was active.
  RecordedSession? stopMultiStemRecording() {
    final rec = _sessionRecorder;
    if (rec == null) return null;
    _sessionRecorder = null;
    final session = rec.stop();
    notifyListeners();
    return session;
  }

  // ---------------------------------------------------------------------------
  // TASK 1 — Adaptive bitrate (upgrade + downgrade)
  //
  // Quality adjustments are driven by the RTT measured in _handlePong, which is
  // the natural place where the client-side service has a per-ping latency value.
  // Because the singleton acts as both host and client, _currentQuality governs
  // what quality level this device requests / advertises.
  //
  // Thresholds (milliseconds, one-way approximated as RTT):
  //   Downgrade when RTT > 150 ms
  //   Upgrade   when RTT <  60 ms  for 10 consecutive pings
  // ---------------------------------------------------------------------------
  static const int _badLatencyThresholdMs = 150;
  static const int _goodLatencyThresholdMs = 60;
  static const int _goodSamplesRequired = 10;

  AudioQuality _currentQuality = AudioQuality.ultra;
  AudioQuality get currentQuality => _currentQuality;

  // Per-client good-sample counter for upgrade decisions.
  final Map<String, int> _goodSampleCount = {};

  void _checkAdaptiveBitrate(String clientId, int rttMs) {
    if (rttMs > _badLatencyThresholdMs) {
      // --- DOWNGRADE ---
      _goodSampleCount[clientId] = 0;
      final idx = _currentQuality.index;
      if (idx > 0) {
        _currentQuality = AudioQuality.values[idx - 1];
        debugPrint(
            '[Streaming] Adaptive bitrate downgrade → ${_currentQuality.displayName}');
        // Reset upgrade counters for all clients on a quality change.
        _goodSampleCount.updateAll((_, __) => 0);
      }
    } else if (rttMs < _goodLatencyThresholdMs) {
      // --- Potential UPGRADE ---
      final count = (_goodSampleCount[clientId] ?? 0) + 1;
      _goodSampleCount[clientId] = count;

      if (count >= _goodSamplesRequired) {
        // Reset this client's counter first.
        _goodSampleCount[clientId] = 0;

        final idx = _currentQuality.index;
        final maxIdx = AudioQuality.values.length - 1;
        if (idx < maxIdx) {
          _currentQuality = AudioQuality.values[idx + 1];
          debugPrint(
              '[Streaming] Adaptive bitrate upgrade → ${_currentQuality.displayName}');
          // Reset all clients' counters so the next upgrade cycle starts fresh.
          _goodSampleCount.updateAll((_, __) => 0);
        }
      }
    } else {
      // Latency is in the acceptable middle band — reset the good-sample streak
      // for this client so upgrades require a clean run of good measurements.
      _goodSampleCount[clientId] = 0;
    }
  }

  // ---------------------------------------------------------------------------
  // TASK 2 — Multiple broadcast rooms
  // ---------------------------------------------------------------------------
  final Map<String, BroadcastRoom> _rooms = {};

  /// Read-only view of all active secondary rooms.
  Map<String, BroadcastRoom> get activeRooms => Map.unmodifiable(_rooms);

  /// Start a new broadcast room on [port] with the given [name].
  /// Returns false if a room with [id] already exists or the port cannot be bound.
  Future<bool> startRoom(
    String id, {
    required String name,
    required int port,
    String? pin,
  }) async {
    if (_rooms.containsKey(id)) return false;

    final room = BroadcastRoom(id: id, name: name, port: port, pin: pin);
    try {
      room.server = await HttpServer.bind(InternetAddress.anyIPv4, port);
      _rooms[id] = room;
      _serveRoom(room);
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('[Rooms] Failed to start room $name on port $port: $e');
      return false;
    }
  }

  /// Stop and remove the room identified by [id].
  Future<void> stopRoom(String id) async {
    final room = _rooms.remove(id);
    if (room == null) return;
    for (final ws in room.clients.values) {
      try {
        await ws.close();
      } catch (_) {}
    }
    room.clients.clear();
    await room.server?.close(force: true);
    room.server = null;
    notifyListeners();
  }

  /// Whether a room with [id] is currently active.
  bool isRoomActive(String id) => _rooms[id]?.isActive ?? false;

  /// Internal: begin serving HTTP/WebSocket on a room's server.
  void _serveRoom(BroadcastRoom room) {
    room.server!.listen((HttpRequest request) async {
      if (!WebSocketTransformer.isUpgradeRequest(request)) {
        request.response.statusCode = HttpStatus.ok;
        request.response.write('Audio Splitter Room: ${room.name}');
        await request.response.close();
        return;
      }
      try {
        final remoteIp =
            request.connectionInfo?.remoteAddress.address ?? 'unknown';
        final ws = await WebSocketTransformer.upgrade(request);
        _handleRoomClientConnection(room, ws, remoteIp);
      } catch (e) {
        debugPrint(
            '[Rooms] WebSocket upgrade failed for room ${room.name}: $e');
        try {
          request.response.statusCode = HttpStatus.internalServerError;
          await request.response.close();
        } catch (_) {}
      }
    });
  }

  void _handleRoomClientConnection(
    BroadcastRoom room,
    WebSocket ws,
    String remoteIp,
  ) {
    final clientId = _generateClientId();
    room.clients[clientId] = ws;

    debugPrint('[Rooms] Client $clientId connected to room ${room.name}');

    // Send welcome
    try {
      ws.add(jsonEncode({
        'type': 'welcome',
        'clientId': clientId,
        'roomName': room.name,
        'requiresPin': room.pin != null && room.pin!.isNotEmpty,
        'encryptionEnabled': _cryptoBox.enabled,
        if (_cryptoBox.enabled && encryptionKeyHex != null)
          'encryptionKey': encryptionKeyHex,
        'timestamp': DateTime.now().toIso8601String(),
      }));
    } catch (_) {}

    ws.listen(
      (data) {
        _handleRoomClientMessage(room, clientId, remoteIp, ws, data);
      },
      onDone: () {
        room.clients.remove(clientId);
        _deviceDisconnectedController.add(clientId);
        debugPrint(
            '[Rooms] Client $clientId disconnected from room ${room.name}');
      },
      onError: (error) {
        debugPrint(
            '[Rooms] Client $clientId error in room ${room.name}: $error');
        room.clients.remove(clientId);
        _deviceDisconnectedController.add(clientId);
      },
    );
  }

  Future<void> _handleRoomClientMessage(
    BroadcastRoom room,
    String clientId,
    String clientRemoteIp,
    WebSocket ws,
    dynamic data,
  ) async {
    try {
      if (data is! String) return;
      final message = jsonDecode(data) as Map<String, dynamic>;

      switch (message['type'] as String?) {
        case 'device_info':
          final device = ConnectedDevice(
            id: clientId,
            name: message['deviceName'] ?? 'Unknown Device',
            type: _parseDeviceType(message['deviceType'] as String?),
            ipAddress: clientRemoteIp,
            isConnected: true,
          );
          _deviceConnectedController.add(device);
          break;

        case 'ping':
          ws.add(jsonEncode({
            'type': 'pong',
            't0': message['t0'],
            'serverTimeMs': DateTime.now().millisecondsSinceEpoch,
          }));
          break;

        case 'audio_request':
          ws.add(jsonEncode({
            'type': 'audio_config',
            'quality': _currentQuality.name,
            'format': 'pcm16',
            'sampleRate': 48000,
            'channels': 2,
          }));
          break;

        case 'pin_response':
          final submitted = message['pin'] as String?;
          if (room.pin != null && submitted != room.pin) {
            ws.add(jsonEncode({'type': 'pin_rejected'}));
            room.clients.remove(clientId);
            await ws.close(4001, 'Invalid PIN');
          } else {
            ws.add(jsonEncode({'type': 'pin_accepted'}));
          }
          break;
      }
    } catch (e) {
      debugPrint('[Rooms] Error handling message from $clientId: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Encryption helpers
  // ---------------------------------------------------------------------------
  void enableEncryption() {
    _cryptoBox.enable();
    debugPrint('Encryption enabled');
  }

  void disableEncryption() {
    _cryptoBox.disable();
  }

  /// Returns the hex-encoded key and IV for sharing with clients.
  /// Format: "keyHex:ivHex"
  String? get encryptionKeyHex => _cryptoBox.keyHex;

  void _setupClientDecryption(String keyHex) {
    _cryptoBox.configureReceiver(keyHex);
    debugPrint('Client decryption configured');
  }

  String _generateClientId() {
    return '${DateTime.now().millisecondsSinceEpoch}_${_random.nextInt(99999)}';
  }

  void setHostPin(String? pin) {
    _hostPin = pin;
  }

  // ---------------------------------------------------------------------------
  // Host methods
  // ---------------------------------------------------------------------------
  Future<bool> startHosting({int port = 8080}) async {
    if (_isHosting) return true;

    try {
      // Hosting is not supported on Web builds
      if (kIsWeb) {
        debugPrint('Hosting is disabled on Web platform.');
        return false;
      }
      _port = port;

      // Start HTTP server for device discovery
      _httpServer = await HttpServer.bind(InternetAddress.anyIPv4, port);
      debugPrint('HTTP Server started on port $port');

      // Handle HTTP requests for device discovery
      _httpServer!.listen((HttpRequest request) {
        _handleHttpRequest(request);
      });

      // Start WebSocket server for audio streaming on port+1
      await _startWebSocketServer(port + 1);
      // Advertise via mDNS
      try {
        await MdnsService()
            .advertise(name: 'Audio Splitter Host', port: port + 1);
      } catch (e) {
        debugPrint('mDNS advertise failed: $e');
      }

      _isHosting = true;
      return true;
    } catch (e) {
      debugPrint('Error starting host: $e');
      return false;
    }
  }

  void _handleHostBinary(Uint8List frame) {
    try {
      // Decrypt via the CryptoBox receiver role (no-op / fail-open when the
      // client has no session key), then parse with the golden-pinned legacy
      // codec — byte-identical to v1's inline frame handling.
      final data = _cryptoBox.open(frame);
      if (data.length > _maxAudioFrameBytes) return;
      final parsed = LegacyFrameCodec.decode(data);
      if (parsed == null) return;
      if (parsed.payload.length > _maxAudioFrameBytes) return;
      _audioPacketController
          .add({'data': parsed.payload, 'ts': parsed.timestampMs});
      _audioDataController.add(parsed.payload);
    } catch (e) {
      debugPrint('Error parsing binary frame: $e');
    }
  }

  Future<void> stopHosting() async {
    if (!_isHosting) return;

    try {
      // Close all client connections
      for (final client in _connectedClients.values) {
        await client.close();
      }
      _connectedClients.clear();

      // Stop servers
      await _httpServer?.close(force: true);
      await _wsHttpServer?.close(force: true);
      _httpServer = null;
      _wsHttpServer = null;
      // Stop mDNS advertising
      try {
        await MdnsService().stopAdvertise();
      } catch (e) {
        debugPrint('mDNS stop advertise failed: $e');
      }
      _isHosting = false;
      disableEncryption();
      // Stop any in-progress recording and clear RBAC / consent state.
      _sessionRecorder?.stop();
      _sessionRecorder = null;
      _clientRoles.clear();
      notifyListeners();
      debugPrint('Stopped hosting');
    } catch (e) {
      debugPrint('Error stopping host: $e');
    }
  }

  Future<void> _startWebSocketServer(int wsPort) async {
    try {
      _wsHttpServer = await HttpServer.bind(InternetAddress.anyIPv4, wsPort);
      debugPrint('WebSocket HTTP Server started on port $wsPort');

      _wsHttpServer!.listen((HttpRequest request) async {
        // Upgrade any incoming request to WebSocket
        if (WebSocketTransformer.isUpgradeRequest(request)) {
          try {
            final remoteIp =
                request.connectionInfo?.remoteAddress.address ?? 'unknown';
            final webSocket = await WebSocketTransformer.upgrade(request);
            _handleClientConnection(webSocket, remoteIp);
          } catch (e) {
            debugPrint('Failed to upgrade to WebSocket: $e');
            try {
              request.response.statusCode = HttpStatus.internalServerError;
              await request.response.close();
            } catch (_) {}
          }
        } else {
          // Simple info response for non-WS requests
          request.response.statusCode = HttpStatus.ok;
          request.response.write('Audio Splitter WS endpoint');
          await request.response.close();
        }
      });
    } catch (e) {
      debugPrint('Error starting WebSocket server: $e');
    }
  }

  void _handleHttpRequest(HttpRequest request) {
    // Handle CORS
    request.response.headers.add('Access-Control-Allow-Origin', '*');
    request.response.headers
        .add('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    request.response.headers
        .add('Access-Control-Allow-Headers', 'Content-Type');

    if (request.method == 'OPTIONS') {
      request.response.statusCode = HttpStatus.ok;
      request.response.close();
      return;
    }

    switch (request.uri.path) {
      case '/discover':
        _handleDiscoveryRequest(request);
        break;
      case '/info':
        _handleInfoRequest(request);
        break;
      case '/client':
        _handleWebClientRequest(request);
        break;
      default:
        request.response.statusCode = HttpStatus.notFound;
        request.response.write('Not Found');
        request.response.close();
    }
  }

  void _handleDiscoveryRequest(HttpRequest request) {
    final response = {
      'name': 'Audio Splitter Host',
      'type': 'audio_splitter',
      'version': '1.0.0',
      'wsPort': _port + 1,
      'capabilities': ['audio_streaming', 'device_management'],
      'timestamp': DateTime.now().toIso8601String(),
    };

    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(response));
    request.response.close();
  }

  void _handleInfoRequest(HttpRequest request) {
    final response = {
      'connectedClients': connectedClientCount,
      'isStreaming': _isHosting,
      'supportedFormats': ['aac', 'pcm', 'mp3'],
      'maxClients': 10,
    };

    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(response));
    request.response.close();
  }

  void _handleWebClientRequest(HttpRequest request) {
    request.response.headers.contentType = ContentType.html;
    request.response.headers.add('Access-Control-Allow-Origin', '*');
    // Pass the WebSocket port as a query param hint in the page
    final html = _webClientHtml.replaceFirst(
        "window.location.port || '8080'", "'$_port'");
    request.response.write(html);
    request.response.close();
  }

  String get webClientUrl => 'http://[device-ip]:$_port/client';

  void _handleClientConnection(WebSocket webSocket, String remoteIp) {
    final clientId = _generateClientId();
    _connectedClients[clientId] = webSocket;
    _clientStats[clientId] = ClientStats();

    debugPrint('Client connected: $clientId');

    // Notify about new device connection
    final device = ConnectedDevice(
      id: clientId,
      name: 'Client Device',
      type: DeviceType.phone,
      ipAddress: remoteIp,
      isConnected: true,
    );
    _deviceConnectedController.add(device);

    // Handle messages from client
    webSocket.listen(
      (data) {
        _handleClientMessage(clientId, data);
      },
      onDone: () {
        _connectedClients.remove(clientId);
        _clientStats.remove(clientId);
        _goodSampleCount.remove(clientId);
        _deviceDisconnectedController.add(clientId);
        debugPrint('Client disconnected: $clientId');
      },
      onError: (error) {
        debugPrint('Client error: $error');
        _connectedClients.remove(clientId);
        _clientStats.remove(clientId);
        _goodSampleCount.remove(clientId);
        _deviceDisconnectedController.add(clientId);
      },
    );

    // Send welcome message
    _sendToClient(clientId, {
      'type': 'welcome',
      'clientId': clientId,
      'requiresPin': _hostPin != null && _hostPin!.isNotEmpty,
      'encryptionEnabled': _cryptoBox.enabled,
      if (_cryptoBox.enabled && encryptionKeyHex != null)
        'encryptionKey': encryptionKeyHex,
      'timestamp': DateTime.now().toIso8601String(),
    });
  }

  Future<void> _handleClientMessage(String clientId, dynamic data) async {
    try {
      final message = jsonDecode(data as String) as Map<String, dynamic>;
      message['clientId'] = clientId;
      _messageController.add(message);

      // Handle specific message types
      switch (message['type']) {
        case 'device_info':
          _handleDeviceInfo(clientId, message);
          break;
        case 'audio_request':
          _handleAudioRequest(clientId, message);
          break;
        case 'ping':
          _sendToClient(clientId, {
            'type': 'pong',
            't0': message['t0'],
            'serverTimeMs': DateTime.now().millisecondsSinceEpoch,
          });
          break;
        case 'pin_response':
          final submittedPin = message['pin'] as String?;
          if (_hostPin != null && submittedPin != _hostPin) {
            _sendToClient(clientId, {'type': 'pin_rejected'});
            final ws = _connectedClients.remove(clientId);
            _deviceDisconnectedController.add(clientId);
            await ws?.close(4001, 'Invalid PIN');
          } else {
            _sendToClient(clientId, {'type': 'pin_accepted'});
          }
          break;
      }
    } catch (e) {
      debugPrint('Error handling client message: $e');
    }
  }

  void _handleDeviceInfo(String clientId, Map<String, dynamic> message) {
    final device = ConnectedDevice(
      id: clientId,
      name: message['deviceName'] ?? 'Unknown Device',
      type: _parseDeviceType(message['deviceType'] as String?),
      ipAddress: message['ipAddress'] ?? 'unknown',
      isConnected: true,
    );
    _deviceConnectedController.add(device);
  }

  void _handleAudioRequest(String clientId, Map<String, dynamic> message) {
    // Handle audio quality requests, format preferences, etc.
    final response = {
      'type': 'audio_config',
      'quality': _currentQuality.name,
      'format': 'pcm16',
      'sampleRate': 48000,
      'channels': 2,
    };
    _sendToClient(clientId, response);
  }

  void _sendToClient(String clientId, Map<String, dynamic> message) {
    final webSocket = _connectedClients[clientId];
    if (webSocket != null) {
      webSocket.add(jsonEncode(message));
    }
  }

  void sendVolumeToClient(String clientId, double volume) {
    _sendToClient(clientId, {
      'type': 'set_volume',
      'volume': volume.clamp(0.0, 1.0),
    });
  }

  void sendPinToHost(String pin) {
    _sendToHost({'type': 'pin_response', 'pin': pin});
  }

  void broadcastAudioData(Uint8List audioData) {
    if (!_isHosting) return;
    if (audioData.isEmpty || audioData.length > _maxAudioFrameBytes) return;
    if (_connectedClients.isEmpty && _rooms.isEmpty) return;

    final ts = DateTime.now().millisecondsSinceEpoch;
    final tsUs = ts * 1000;

    // Feed the multi-stem session recorder (master-mix stem) while active.
    final rec = _sessionRecorder;
    if (rec != null) {
      rec.write(
        'master',
        PcmChunk(
            pcm: audioData,
            presentationTsUs: tsUs,
            format: AudioFormat.cdStereo),
      );
    }

    // Build the wire frame. When useAsp2Wire is true, emit an ASP-2 PCM16 frame
    // (pure Dart, no native binary required). Until two-device smoke-testing
    // enables this, the flag stays false and the legacy v1 frame is used.
    final Uint8List rawFrame;
    if (Asp2Config.useAsp2Wire) {
      rawFrame = Asp2Frame(
        codecId: _pcm16.codecId,
        sequenceNumber: _asp2Seq++,
        presentationTsUs: tsUs,
        payload: audioData,
      ).encode();
    } else {
      // Legacy v1 PCM16 frame — byte-identical to the original implementation.
      rawFrame = LegacyFrameCodec.encode(audioData, ts);
    }

    // --- Default room (main _connectedClients) ---
    if (_connectedClients.isNotEmpty) {
      final staleClients = <String>[];
      if (_useBinaryTransport) {
        // seal() is a no-op (returns rawFrame) when encryption is off and
        // fail-open on error, so unencrypted clients see identical bytes.
        final Uint8List frameToSend = _cryptoBox.seal(rawFrame);
        _connectedClients.forEach((clientId, webSocket) {
          try {
            webSocket.add(frameToSend);
            _clientStats[clientId]?.bytesSent += frameToSend.length;
            _clientStats[clientId]?.packetsSent += 1;
          } catch (e) {
            debugPrint('Error sending binary audio to client: $e');
            staleClients.add(clientId);
          }
        });
      } else {
        final encodedMessage = jsonEncode({
          'type': 'audio_data',
          'data': base64Encode(audioData),
          'ts': ts,
        });
        _connectedClients.forEach((clientId, webSocket) {
          try {
            webSocket.add(encodedMessage);
            _clientStats[clientId]?.bytesSent += encodedMessage.length;
            _clientStats[clientId]?.packetsSent += 1;
          } catch (e) {
            debugPrint('Error sending audio data to client: $e');
            staleClients.add(clientId);
          }
        });
      }

      for (final clientId in staleClients.toSet()) {
        _connectedClients.remove(clientId);
        _deviceDisconnectedController.add(clientId);
      }
    }

    // Optional local loopback for testing
    if (_loopbackTest) {
      _audioPacketController.add({'data': audioData, 'ts': ts});
      _audioDataController.add(audioData);
    }

    // --- Secondary rooms ---
    // Rooms receive unencrypted frames (each room manages its own auth/PIN).
    if (_rooms.isNotEmpty) {
      final roomJsonFrame = _useBinaryTransport
          ? null
          : jsonEncode({
              'type': 'audio_data',
              'data': base64Encode(audioData),
              'ts': ts
            });

      for (final room in _rooms.values) {
        if (room.clients.isEmpty) continue;
        final staleRoomClients = <String>[];
        for (final entry in room.clients.entries) {
          try {
            if (_useBinaryTransport) {
              entry.value.add(rawFrame);
            } else {
              entry.value.add(roomJsonFrame!);
            }
          } catch (_) {
            staleRoomClients.add(entry.key);
          }
        }
        for (final id in staleRoomClients) {
          room.clients.remove(id);
        }
      }
    }
  }

  void broadcastMessage(Map<String, dynamic> message) {
    if (!_isHosting) return;

    final encodedMessage = jsonEncode(message);
    final staleClients = <String>[];

    _connectedClients.forEach((clientId, webSocket) {
      try {
        webSocket.add(encodedMessage);
      } catch (e) {
        debugPrint('Error broadcasting message: $e');
        staleClients.add(clientId);
      }
    });

    for (final clientId in staleClients.toSet()) {
      _connectedClients.remove(clientId);
      _deviceDisconnectedController.add(clientId);
    }
  }

  // ---------------------------------------------------------------------------
  // Client methods
  // ---------------------------------------------------------------------------
  Future<bool> connectToHost(String hostAddress, {int port = 8080}) async {
    if (_isConnectedAsClient) return true;

    try {
      _hostAddress = hostAddress;
      _port = port;
      _lastHostAddress = hostAddress;
      _lastHostPort = port;

      // Connect to WebSocket server
      final wsUrl = 'ws://$hostAddress:${port + 1}';
      _clientWebSocket = await WebSocket.connect(wsUrl);

      // Handle messages from host
      _clientWebSocket!.listen(
        (data) {
          if (data is String) {
            _handleHostMessage(data);
          } else if (data is List<int> || data is Uint8List) {
            _handleHostBinary(Uint8List.fromList(data as List<int>));
          }
        },
        onDone: () {
          _isConnectedAsClient = false;
          _connectionStateController.add(false);
          _stopClientScheduler();
          debugPrint('Disconnected from host');
          _pingTimer?.cancel();
          if (!_manualDisconnect) {
            _scheduleReconnect();
          }
        },
        onError: (error) {
          debugPrint('Connection error: $error');
          _isConnectedAsClient = false;
          _connectionStateController.add(false);
          _stopClientScheduler();
          _pingTimer?.cancel();
          if (!_manualDisconnect) {
            _scheduleReconnect();
          }
        },
      );

      _isConnectedAsClient = true;

      // Send device info to host
      _sendToHost({
        'type': 'device_info',
        'deviceName': 'Flutter Client',
        'deviceType': 'phone',
        'capabilities': ['audio_playback'],
        'timestamp': DateTime.now().toIso8601String(),
      });

      // Start periodic ping to measure RTT and enable sync
      _startClientPing();

      // Start client-side scheduler if SyncService available (set via setSyncService)
      if (_syncService != null) {
        _startClientScheduler();
      }

      _connectionStateController.add(true);
      _reconnectAttempts = 0;
      return true;
    } catch (e) {
      debugPrint('Error connecting to host: $e');
      return false;
    }
  }

  Future<void> disconnectFromHost() async {
    if (!_isConnectedAsClient) return;

    try {
      _manualDisconnect = true;
      await _clientWebSocket?.close();
      _isConnectedAsClient = false;
      _clientWebSocket = null;
      _hostAddress = null;
      _cryptoBox.clearReceiver();
      debugPrint('Disconnected from host');
      _pingTimer?.cancel();
      _stopClientScheduler();
      _connectionStateController.add(false);
      _reconnectAttempts = 0;
      _manualDisconnect = false;
    } catch (e) {
      debugPrint('Error disconnecting from host: $e');
    }
  }

  Future<void> _handleHostMessage(dynamic data) async {
    try {
      final message = jsonDecode(data as String) as Map<String, dynamic>;
      _messageController.add(message);

      // Handle specific message types
      switch (message['type']) {
        case 'audio_data':
          _handleAudioData(message);
          break;
        case 'audio_config':
          _handleAudioConfig(message);
          break;
        case 'welcome':
          debugPrint('Connected to host successfully');
          if (message['encryptionEnabled'] == true &&
              message['encryptionKey'] is String) {
            _setupClientDecryption(message['encryptionKey'] as String);
          }
          break;
        case 'pong':
          _handlePong(message);
          break;
        case 'set_volume':
          final vol = (message['volume'] ?? 1.0) as double;
          _messageController.add({'type': 'set_volume', 'volume': vol});
          break;
        case 'pin_rejected':
          debugPrint('PIN rejected by host');
          _isConnectedAsClient = false;
          _connectionStateController.add(false);
          await _clientWebSocket?.close();
          break;
        case 'pin_accepted':
          debugPrint('PIN accepted');
          break;
      }
    } catch (e) {
      debugPrint('Error handling host message: $e');
    }
  }

  void _handleAudioData(Map<String, dynamic> message) {
    try {
      final audioData = base64Decode(message['data'] as String);
      final ts =
          (message['ts'] ?? DateTime.now().millisecondsSinceEpoch) as int;
      _audioDataController.add(audioData);
      _audioPacketController.add({'data': audioData, 'ts': ts});
    } catch (e) {
      debugPrint('Error handling audio data: $e');
    }
  }

  // --- Client-side audio scheduler ---
  void setSyncService(SyncService syncService) {
    _syncService = syncService;
  }

  void _startClientScheduler({String deviceId = 'host'}) {
    _packetSub?.cancel();
    if (_syncService == null) return;
    _schedulerWarmedUp = false;
    _warmupDeadlineMs = DateTime.now().millisecondsSinceEpoch + _warmupTargetMs;
    _packetSub = _audioPacketController.stream.listen((packet) {
      try {
        final data = packet['data'] as Uint8List;
        final ts = packet['ts'] as int;
        final res = _syncService!.synchronizeAudio(deviceId, data, ts);
        switch (res.action) {
          case SyncAction.drop:
            // ignore
            break;
          case SyncAction.playImmediate:
            if (_schedulerWarmedUp) {
              _scheduledAudioController.add(res.audioData!);
            } else {
              final now = DateTime.now().millisecondsSinceEpoch;
              final extraDelay = (_warmupDeadlineMs - now).clamp(0, 1000);
              final timer = Timer(Duration(milliseconds: extraDelay), () {
                if (!_scheduledAudioController.isClosed &&
                    res.audioData != null) {
                  _scheduledAudioController.add(res.audioData!);
                }
              });
              _pendingPlaybackTimers.add(timer);
            }
            break;
          case SyncAction.play:
          case SyncAction.buffer:
            int delayMs = res.delayMs.clamp(0, 1000);
            if (!_schedulerWarmedUp) {
              final now = DateTime.now().millisecondsSinceEpoch;
              final need = (_warmupDeadlineMs - now).clamp(0, 1000);
              if (need > delayMs) delayMs = need;
            }
            // Backpressure: cap pending timers to avoid buildup under jitter
            const maxPending = 200;
            if (_pendingPlaybackTimers.length >= maxPending) {
              // Drop oldest timer and schedule latest to favor freshness
              _pendingPlaybackTimers.first.cancel();
              _pendingPlaybackTimers.removeAt(0);
            }
            final timer = Timer(Duration(milliseconds: delayMs), () {
              if (!_scheduledAudioController.isClosed &&
                  res.audioData != null) {
                _scheduledAudioController.add(res.audioData!);
              }
            });
            _pendingPlaybackTimers.add(timer);
            break;
        }
        if (!_schedulerWarmedUp &&
            DateTime.now().millisecondsSinceEpoch >= _warmupDeadlineMs) {
          _schedulerWarmedUp = true;
        }
      } catch (e) {
        debugPrint('Scheduler error: $e');
      }
    });
  }

  void _stopClientScheduler() {
    for (final t in _pendingPlaybackTimers) {
      t.cancel();
    }
    _pendingPlaybackTimers.clear();
    _packetSub?.cancel();
    _packetSub = null;
    _schedulerWarmedUp = false;
  }

  void _scheduleReconnect() {
    if (_lastHostAddress == null || _lastHostPort == null) return;
    _reconnectAttempts = (_reconnectAttempts + 1).clamp(1, 8);
    final delayMs = (1000 * (1 << (_reconnectAttempts - 1))).clamp(1000, 30000);
    debugPrint(
        'Scheduling reconnect in ${delayMs}ms (attempt: $_reconnectAttempts)');
    Timer(Duration(milliseconds: delayMs), () async {
      if (_isConnectedAsClient || _manualDisconnect) return;
      await connectToHost(_lastHostAddress!, port: _lastHostPort!);
    });
  }

  void _handleAudioConfig(Map<String, dynamic> message) {
    // Handle audio configuration from host
    debugPrint('Audio config received: $message');
  }

  void requestAudioConfig() {
    _sendToHost({
      'type': 'audio_request',
      'requestedQuality': _currentQuality.name,
      'requestedFormat': 'pcm16',
      'requestedSampleRate': 48000,
      'requestedChannels': 2,
    });
  }

  void _sendToHost(Map<String, dynamic> message) {
    if (_clientWebSocket != null && _isConnectedAsClient) {
      _clientWebSocket!.add(jsonEncode(message));
    }
  }

  // Enable/disable simple loopback test mode
  void setLoopbackTest(bool enabled) {
    _loopbackTest = enabled;
  }

  // Enable/disable binary WS transport
  void setUseBinaryTransport(bool enabled) {
    _useBinaryTransport = enabled;
  }

  void _startClientPing() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      final t0 = DateTime.now().millisecondsSinceEpoch;
      _sendToHost({
        'type': 'ping',
        't0': t0,
      });
    });
  }

  void _handlePong(Map<String, dynamic> message) {
    try {
      final int t0 = (message['t0'] ?? 0) as int;
      final int serverTimeMs = (message['serverTimeMs'] ?? 0) as int;
      final int t1 = DateTime.now().millisecondsSinceEpoch;
      final rtt = t1 - t0;
      _latencyMsController.add(rtt);
      _syncService?.updateClockSync(serverTimeMs, rtt);

      // Adaptive bitrate check — use the host's clientId as a stable key.
      // When connected as a client there is a single upstream connection; we
      // use the sentinel key 'upstream' so upgrade counters are tracked cleanly.
      _checkAdaptiveBitrate('upstream', rtt);
    } catch (e) {
      debugPrint('Error handling pong: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Utility methods
  // ---------------------------------------------------------------------------
  DeviceType _parseDeviceType(String? typeString) {
    switch (typeString?.toLowerCase()) {
      case 'phone':
        return DeviceType.phone;
      case 'tablet':
        return DeviceType.tablet;
      case 'computer':
        return DeviceType.computer;
      case 'bluetooth_headset':
        return DeviceType.bluetoothHeadset;
      case 'bluetooth_speaker':
        return DeviceType.bluetoothSpeaker;
      case 'smart_watch':
        return DeviceType.smartWatch;
      default:
        return DeviceType.other;
    }
  }

  @override
  Future<void> dispose() async {
    super.dispose();
    await stopHosting();
    // Stop all secondary rooms.
    final roomIds = _rooms.keys.toList();
    for (final id in roomIds) {
      await stopRoom(id);
    }
    await disconnectFromHost();
    await _wsTransport.dispose();

    _pingTimer?.cancel();
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

  // --- Simple LAN discovery (scan nearby IPs for /discover endpoint) ---
  final StreamController<Map<String, dynamic>> _discoveredHostController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get discoveredHostStream =>
      _discoveredHostController.stream;

  Future<void> scanForHosts({int port = 8080}) async {
    try {
      // First try mDNS discovery
      try {
        final mdnsStream = MdnsService().browse();
        final sub = mdnsStream.listen((srv) {
          _discoveredHostController.add({
            'host': srv['host'],
            'port': srv['port'] - 1, // our HTTP discover is port, WS is +1
            'name': srv['name'] ?? 'Host',
          });
        });
        // Give mDNS a short window
        await Future.delayed(const Duration(seconds: 3));
        await sub.cancel();
      } catch (e) {
        debugPrint('mDNS browse failed: $e');
      }

      // Subnet probe is delegated to the WsTransport discovery layer (Phase
      // 0.2); each responding host is forwarded to the discovery stream.
      await for (final host in _wsTransport.scanSubnet(port: port)) {
        if (!_discoveredHostController.isClosed) {
          _discoveredHostController.add(host);
        }
      }
    } catch (e) {
      debugPrint('Host scan error: $e');
    }
  }
}
