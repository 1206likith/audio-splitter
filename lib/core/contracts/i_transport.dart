import 'dart:typed_data';

/// Kinds of out-of-band events a transport surfaces alongside the media byte
/// stream.
enum TransportEventType {
  peerConnected,
  peerDisconnected,
  control, // a decoded control-plane message (JSON map)
  error,
}

/// An out-of-band transport event (peer lifecycle, control message, error).
class TransportEvent {
  final TransportEventType type;
  final String? peerId;

  /// For [TransportEventType.control], the decoded JSON message.
  final Map<String, dynamic>? message;

  /// For [TransportEventType.error], a human-readable description.
  final String? error;

  const TransportEvent({
    required this.type,
    this.peerId,
    this.message,
    this.error,
  });

  factory TransportEvent.peerConnected(String peerId) =>
      TransportEvent(type: TransportEventType.peerConnected, peerId: peerId);

  factory TransportEvent.peerDisconnected(String peerId) =>
      TransportEvent(type: TransportEventType.peerDisconnected, peerId: peerId);

  factory TransportEvent.control(Map<String, dynamic> message,
          {String? peerId}) =>
      TransportEvent(
        type: TransportEventType.control,
        message: message,
        peerId: peerId,
      );

  factory TransportEvent.error(String error, {String? peerId}) =>
      TransportEvent(
          type: TransportEventType.error, error: error, peerId: peerId);
}

/// The transport multiplexer contract: moves opaque frame bytes between a host
/// and its peers. Implementations include WebSocket (LAN), and later QUIC,
/// WebRTC SFU, mesh relay, and HLS fallback.
///
/// A transport knows nothing about codecs, framing, or encryption — it ships
/// already-built frame buffers and surfaces inbound buffers + lifecycle events.
abstract class ITransport {
  /// Human-readable transport name (e.g. "websocket"), for diagnostics.
  String get name;

  /// Start serving as a host on [port]. Completes when listening.
  Future<void> startServer({required int port});

  /// Connect to a host as a client.
  Future<void> connect({required String host, required int port});

  /// Send a fully-built frame to peers on [streamId]. For a host this fans out
  /// to connected peers; for a client it sends upstream.
  void send(int streamId, Uint8List frameBytes);

  /// Inbound frame buffers (already de-multiplexed from the socket).
  Stream<Uint8List> get inbound;

  /// Out-of-band events: peer connect/disconnect, control messages, errors.
  Stream<TransportEvent> get events;

  /// Tear down the transport and release sockets.
  Future<void> dispose();
}
