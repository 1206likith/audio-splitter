import 'dart:typed_data';

import 'package:audio_splitter_app/asp2/transport/ws_transport.dart';
import 'package:audio_splitter_app/core/contracts/i_transport.dart';
import 'package:flutter_test/flutter_test.dart';

/// Host↔client loopback smoke test for the extracted WsTransport. This is the
/// automated stand-in for the Phase 0 "host↔client on Windows" gate: it binds a
/// real server on an ephemeral port, connects a real client over localhost, and
/// asserts opaque frame bytes move both directions byte-identically.
void main() {
  late WsTransport host;
  late WsTransport client;

  setUp(() {
    host = WsTransport();
    client = WsTransport();
  });

  tearDown(() async {
    await client.dispose();
    await host.dispose();
  });

  Future<int> startHostOnEphemeralPort() async {
    await host.startServer(port: 0);
    final port = host.boundPort;
    expect(port, isNotNull);
    return port!;
  }

  /// Connect the client and await peerConnected race-free: the listener is set
  /// up *before* connect() so a peerConnected emitted during the handshake is
  /// never dropped by the broadcast stream. Returns the connected event.
  Future<TransportEvent> connectAndAwait(int port) async {
    final connected = host.events
        .firstWhere((e) => e.type == TransportEventType.peerConnected)
        .timeout(const Duration(seconds: 5));
    await client.connect(host: '127.0.0.1', port: port);
    return connected;
  }

  test('client connect surfaces a peerConnected event on the host', () async {
    final port = await startHostOnEphemeralPort();
    final event = await connectAndAwait(port);
    expect(event.peerId, isNotNull);
    expect(host.peerCount, 1);
  });

  test('client -> host binary frame arrives byte-identical on inbound',
      () async {
    final port = await startHostOnEphemeralPort();
    await connectAndAwait(port);

    final frame =
        Uint8List.fromList(List<int>.generate(300, (i) => (i * 13) & 0xFF));
    final received = host.inbound.first;
    client.send(0, frame);
    expect(await received.timeout(const Duration(seconds: 5)), frame);
  });

  test('host -> client fan-out frame arrives byte-identical on inbound',
      () async {
    final port = await startHostOnEphemeralPort();
    await connectAndAwait(port);

    final frame = Uint8List.fromList([1, 2, 3, 4, 250, 251, 252]);
    final received = client.inbound.first;
    host.send(0, frame); // fan-out to all peers
    expect(await received.timeout(const Duration(seconds: 5)), frame);
  });

  test('text control message decodes to a control event', () async {
    final port = await startHostOnEphemeralPort();
    await connectAndAwait(port);

    final control = host.events
        .firstWhere((e) => e.type == TransportEventType.control)
        .timeout(const Duration(seconds: 5));
    client.sendControlUpstream({'type': 'ping', 't0': 42});
    final event = await control;
    expect(event.message?['type'], 'ping');
    expect(event.message?['t0'], 42);
  });

  test('client disconnect surfaces peerDisconnected on the host', () async {
    final port = await startHostOnEphemeralPort();
    await connectAndAwait(port);

    final gone = host.events
        .firstWhere((e) => e.type == TransportEventType.peerDisconnected)
        .timeout(const Duration(seconds: 5));
    await client.dispose();
    await gone;
    expect(host.peerCount, 0);
  });
}
