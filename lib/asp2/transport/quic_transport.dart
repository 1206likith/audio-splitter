import 'dart:async';
import 'dart:typed_data';

import '../../core/contracts/i_transport.dart';
import 'transport_exceptions.dart';

/// The current state of a QUIC connection's path, used to model **connection
/// migration** — QUIC's ability to keep a session alive across a network change
/// (e.g. a phone leaving WiFi for cellular) because the connection is keyed by a
/// connection id, not the 4-tuple.
enum QuicPathState {
  /// No active path.
  idle,

  /// Path established and validated; media flowing.
  active,

  /// The local address changed; a new path is being validated while the old one
  /// is kept as a fallback (QUIC path migration in progress).
  migrating,

  /// Connection closed.
  closed,
}

/// Models a QUIC connection-migration event for telemetry/testing. Pure value
/// type so the migration state machine can be exercised without a real QUIC
/// stack.
class QuicMigration {
  final String fromPath;
  final String toPath;

  /// True once the new path passed QUIC path validation.
  final bool validated;

  const QuicMigration({
    required this.fromPath,
    required this.toPath,
    this.validated = false,
  });

  QuicMigration validate() =>
      QuicMigration(fromPath: fromPath, toPath: toPath, validated: true);

  @override
  String toString() => 'QuicMigration($fromPath→$toPath, validated=$validated)';
}

/// QuicTransport — the WAN low-latency implementation of [ITransport] (Phase 4):
/// QUIC for low handshake latency (0-RTT resumption) and seamless WiFi↔cellular
/// migration. **[needs-service]/native**: Dart has no built-in QUIC and no pure
/// HTTP/3 package is linked in this sandbox, so the real transport is
/// **deferred** behind a capability probe — same discipline as the WebRTC
/// scaffold and the Phase 1–2 native binaries.
///
/// Real and tested today: [ITransport] conformance (streams, name, lifecycle),
/// the [QuicPathState] / [QuicMigration] migration model, and a loud-but-
/// recoverable [TransportUnavailableException] on the actual connect path so the
/// facade can fall back. When a QUIC stack is linked on the device path, only
/// [_bringUp] and the path-migration glue need real bodies.
class QuicTransport implements ITransport {
  /// Capability probe. False here: no QUIC/HTTP-3 stack is linked. Flip on the
  /// device build that provides one.
  static bool get isAvailable => false;

  QuicPathState _path = QuicPathState.idle;
  QuicPathState get pathState => _path;

  final StreamController<Uint8List> _inbound =
      StreamController<Uint8List>.broadcast();
  final StreamController<TransportEvent> _events =
      StreamController<TransportEvent>.broadcast();

  @override
  String get name => 'quic';

  @override
  Stream<Uint8List> get inbound => _inbound.stream;

  @override
  Stream<TransportEvent> get events => _events.stream;

  Never _bringUp(String role) {
    throw TransportUnavailableException(
      name,
      'QUIC is not available in this build ($role): no QUIC/HTTP-3 stack is '
      'linked. Wire a native QUIC transport on the device path (0-RTT + '
      'connection migration), then implement QuicTransport.',
    );
  }

  @override
  Future<void> startServer({required int port}) async => _bringUp('host');

  @override
  Future<void> connect({required String host, required int port}) async =>
      _bringUp('client');

  @override
  void send(int streamId, Uint8List frameBytes) {
    if (!_events.isClosed) {
      _events.add(TransportEvent.error('quic transport not connected'));
    }
  }

  @override
  Future<void> dispose() async {
    _path = QuicPathState.closed;
    await _inbound.close();
    await _events.close();
  }
}
