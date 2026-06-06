import 'dart:async';
import 'dart:typed_data';

import '../../core/contracts/i_transport.dart';
import 'transport_exceptions.dart';

/// Connection details for an SFU-backed WebRTC session.
///
/// Phase 4 starts on a hosted SFU (the plan: **LiveKit Cloud free tier**) so a
/// host's upload doesn't scale with the audience — the SFU fans out instead. The
/// host obtains a room + a signed access token from its own backend (so the
/// secret key never ships in the app) and hands this config to the transport.
///
/// This is a pure, serializable value type — fully testable now — even though
/// the transport that consumes it is deferred (see [WebRtcTransport]).
class SfuConfig {
  /// SFU signalling/websocket url, e.g. `wss://myproject.livekit.cloud`.
  final String url;

  /// Room name all participants of one session join.
  final String room;

  /// Short-lived access token (JWT) minted by the app backend, not the client.
  final String token;

  /// Optional ICE/TURN servers for NAT traversal.
  final List<String> iceServers;

  const SfuConfig({
    required this.url,
    required this.room,
    required this.token,
    this.iceServers = const [],
  });

  bool get isValid => url.isNotEmpty && room.isNotEmpty && token.isNotEmpty;

  Map<String, dynamic> toJson() => {
        'url': url,
        'room': room,
        'token': token,
        'iceServers': iceServers,
      };

  factory SfuConfig.fromJson(Map<String, dynamic> json) => SfuConfig(
        url: json['url'] as String,
        room: json['room'] as String,
        token: json['token'] as String,
        iceServers: [
          for (final s in (json['iceServers'] as List? ?? const []))
            s as String,
        ],
      );
}

/// WebRtcTransport — the WebRTC-DataChannel + SFU implementation of [ITransport]
/// (Phase 4). **[needs-service]**: it requires the `flutter_webrtc` plugin and a
/// reachable SFU (LiveKit Cloud free tier to start). Neither is available in this
/// build/test sandbox, so the real connect path is **deferred** behind a
/// capability probe — exactly the "scaffold + probe + documented deferral"
/// pattern Phases 1–2 used for native codec/DSP binaries.
///
/// What is real and tested today: it conforms to [ITransport] (streams, event
/// plumbing, name), validates and carries its [SfuConfig], and fails **loudly
/// and recoverably** ([TransportUnavailableException]) when asked to actually
/// connect — so the transport-mux facade can fall back to WebSocket/QUIC/HLS
/// rather than crash. When `flutter_webrtc` + an SFU are wired on the device
/// path, only [_bringUp] needs a real body.
class WebRtcTransport implements ITransport {
  final SfuConfig config;

  /// Capability probe. False here: no `flutter_webrtc` plugin is linked in this
  /// sandbox. On a real device build that links the plugin, flip this (or make
  /// it probe the plugin) and implement [_bringUp].
  static bool get isAvailable => false;

  final StreamController<Uint8List> _inbound =
      StreamController<Uint8List>.broadcast();
  final StreamController<TransportEvent> _events =
      StreamController<TransportEvent>.broadcast();

  WebRtcTransport({required this.config});

  @override
  String get name => 'webrtc-sfu';

  @override
  Stream<Uint8List> get inbound => _inbound.stream;

  @override
  Stream<TransportEvent> get events => _events.stream;

  Never _bringUp(String role) {
    throw TransportUnavailableException(
      name,
      'WebRTC/SFU is not available in this build ($role): the flutter_webrtc '
      'plugin is not linked and no SFU is configured. Wire LiveKit Cloud + '
      'flutter_webrtc on the device path, then implement WebRtcTransport. '
      'Config valid=${config.isValid}, room="${config.room}".',
    );
  }

  @override
  Future<void> startServer({required int port}) async => _bringUp('host');

  @override
  Future<void> connect({required String host, required int port}) async =>
      _bringUp('client');

  @override
  void send(int streamId, Uint8List frameBytes) {
    // No live DataChannel yet; surface as a recoverable error rather than throw
    // from a sync fan-out path.
    if (!_events.isClosed) {
      _events.add(TransportEvent.error('webrtc transport not connected'));
    }
  }

  @override
  Future<void> dispose() async {
    await _inbound.close();
    await _events.close();
  }
}
