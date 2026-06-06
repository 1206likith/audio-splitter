import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show Random;
import 'dart:typed_data';

import '../../core/contracts/i_transport.dart';

/// WsTransport — the LAN WebSocket implementation of [ITransport], extracted
/// from v1's `StreamingService` (Phase 0.2).
///
/// It moves opaque frame bytes and knows nothing about codecs, framing, or
/// crypto. A single instance plays one of two roles:
///   * **host** — [startServer] binds an [HttpServer], upgrades each connection
///     to a WebSocket, assigns a peer id, and fans [send] out to every peer.
///   * **client** — [connect] opens one upstream socket; [send] writes to it.
///
/// Inbound **binary** messages surface on [inbound]; inbound **text** messages
/// are decoded as JSON and surface as [TransportEventType.control] events, with
/// peer lifecycle as connect/disconnect events. This mirrors v1's split between
/// the binary audio frame path and the JSON control channel exactly, so the
/// facade can adopt it without any wire change.
class WsTransport implements ITransport {
  WsTransport({String Function()? idGenerator})
      : _idGenerator = idGenerator ?? _defaultIdGenerator;

  static final Random _random = Random();
  static String _defaultIdGenerator() =>
      '${DateTime.now().millisecondsSinceEpoch}_${_random.nextInt(99999)}';

  final String Function() _idGenerator;

  // Host role
  HttpServer? _server;
  final Map<String, WebSocket> _peers = {};

  // Client role
  WebSocket? _client;

  final StreamController<Uint8List> _inbound =
      StreamController<Uint8List>.broadcast();
  final StreamController<TransportEvent> _events =
      StreamController<TransportEvent>.broadcast();

  @override
  String get name => 'websocket';

  @override
  Stream<Uint8List> get inbound => _inbound.stream;

  @override
  Stream<TransportEvent> get events => _events.stream;

  /// Ids of currently-connected peers (host role).
  Iterable<String> get peerIds => _peers.keys;

  /// Number of connected peers (host role).
  int get peerCount => _peers.length;

  /// The actual bound port of the server, or null when not hosting. Useful for
  /// tests that bind to an ephemeral port (0).
  int? get boundPort => _server?.port;

  @override
  Future<void> startServer({required int port}) async {
    _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    _server!.listen((HttpRequest request) async {
      if (!WebSocketTransformer.isUpgradeRequest(request)) {
        request.response.statusCode = HttpStatus.ok;
        request.response.write('Audio Splitter WS endpoint');
        await request.response.close();
        return;
      }
      try {
        final ws = await WebSocketTransformer.upgrade(request);
        _acceptPeer(ws);
      } catch (e) {
        try {
          request.response.statusCode = HttpStatus.internalServerError;
          await request.response.close();
        } catch (_) {}
      }
    });
  }

  void _acceptPeer(WebSocket ws) {
    final peerId = _idGenerator();
    _peers[peerId] = ws;
    _emit(TransportEvent.peerConnected(peerId));
    ws.listen(
      (data) => _dispatchInbound(data, peerId),
      onDone: () {
        _peers.remove(peerId);
        _emit(TransportEvent.peerDisconnected(peerId));
      },
      onError: (Object error) {
        _peers.remove(peerId);
        _emit(TransportEvent.error(error.toString(), peerId: peerId));
        _emit(TransportEvent.peerDisconnected(peerId));
      },
    );
  }

  /// Add an event only while the controller is open. Socket `onDone`/`onError`
  /// callbacks can fire asynchronously after [dispose] has closed the
  /// controllers, so every emit is guarded.
  void _emit(TransportEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  @override
  Future<void> connect({required String host, required int port}) async {
    final ws = await WebSocket.connect('ws://$host:$port');
    _client = ws;
    ws.listen(
      (data) => _dispatchInbound(data, 'host'),
      onDone: () {
        _client = null;
        _emit(TransportEvent.peerDisconnected('host'));
      },
      onError: (Object error) {
        _client = null;
        _emit(TransportEvent.error(error.toString(), peerId: 'host'));
        _emit(TransportEvent.peerDisconnected('host'));
      },
    );
  }

  /// Route an inbound socket message: binary → [inbound], text → a decoded
  /// control event. Malformed JSON is surfaced as an error event, not thrown.
  void _dispatchInbound(dynamic data, String peerId) {
    if (data is String) {
      try {
        final msg = jsonDecode(data) as Map<String, dynamic>;
        _emit(TransportEvent.control(msg, peerId: peerId));
      } catch (e) {
        _emit(TransportEvent.error('bad control json: $e', peerId: peerId));
      }
    } else if (_inbound.isClosed) {
      return;
    } else if (data is Uint8List) {
      _inbound.add(data);
    } else if (data is List<int>) {
      _inbound.add(Uint8List.fromList(data));
    }
  }

  @override
  void send(int streamId, Uint8List frameBytes) {
    // Legacy single-stream wire ignores streamId; multiplexing arrives with the
    // ASP-2 header in a later phase.
    if (_client != null) {
      _safeAdd(_client!, frameBytes);
      return;
    }
    final stale = <String>[];
    _peers.forEach((id, ws) {
      if (!_safeAdd(ws, frameBytes)) stale.add(id);
    });
    for (final id in stale) {
      _peers.remove(id);
      _emit(TransportEvent.peerDisconnected(id));
    }
  }

  /// Send raw bytes to a single peer (host role).
  void sendTo(String peerId, Uint8List frameBytes) {
    final ws = _peers[peerId];
    if (ws != null) _safeAdd(ws, frameBytes);
  }

  /// Send a JSON control message to a single peer (host role).
  void sendControl(String peerId, Map<String, dynamic> message) {
    final ws = _peers[peerId];
    if (ws != null) _safeAdd(ws, jsonEncode(message));
  }

  /// Send a JSON control message upstream (client role).
  void sendControlUpstream(Map<String, dynamic> message) {
    final ws = _client;
    if (ws != null) _safeAdd(ws, jsonEncode(message));
  }

  bool _safeAdd(WebSocket ws, Object data) {
    try {
      ws.add(data);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Probe the local IPv4 subnet for v1 `/discover` HTTP endpoints. Yields each
  /// host descriptor as it responds. This is the subnet-scan half of v1's
  /// `scanForHosts` (mDNS browse remains orchestrated by the facade).
  Stream<Map<String, dynamic>> scanSubnet({int port = 8080}) async* {
    final controller = StreamController<Map<String, dynamic>>();
    unawaited(_runSubnetScan(port, controller));
    yield* controller.stream;
  }

  Future<void> _runSubnetScan(
    int port,
    StreamController<Map<String, dynamic>> out,
  ) async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      if (interfaces.isEmpty) return;
      final ip = interfaces.first.addresses.first.address;
      final parts = ip.split('.');
      if (parts.length != 4) return;
      final subnet = '${parts[0]}.${parts[1]}.${parts[2]}';

      final futures = <Future>[];
      final limiter = ConcurrencyLimiter(32);
      for (int i = 1; i <= 254; i++) {
        final target = '$subnet.$i';
        futures.add(limiter.run(() async {
          final desc = await _probeHost(target, port);
          if (desc != null && !out.isClosed) out.add(desc);
        }));
      }
      await Future.wait(futures);
    } catch (_) {
      // ignore scan errors
    } finally {
      if (!out.isClosed) await out.close();
    }
  }

  Future<Map<String, dynamic>?> _probeHost(String host, int port) async {
    final uri = Uri.parse('http://$host:$port/discover');
    final client = HttpClient();
    client.connectionTimeout = const Duration(milliseconds: 400);
    try {
      final request =
          await client.getUrl(uri).timeout(const Duration(milliseconds: 600));
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response =
          await request.close().timeout(const Duration(milliseconds: 800));
      if (response.statusCode == HttpStatus.ok) {
        final body = await response.transform(utf8.decoder).join();
        final data = jsonDecode(body) as Map<String, dynamic>;
        data['host'] = host;
        data['port'] = port;
        return data;
      }
    } catch (_) {
      // ignore timeouts/connection errors
    } finally {
      client.close(force: true);
    }
    return null;
  }

  @override
  Future<void> dispose() async {
    // Snapshot before closing: each ws.close() triggers onDone, which mutates
    // _peers, so iterating the live collection would throw.
    for (final ws in _peers.values.toList()) {
      try {
        await ws.close();
      } catch (_) {}
    }
    _peers.clear();
    try {
      await _client?.close();
    } catch (_) {}
    _client = null;
    await _server?.close(force: true);
    _server = null;
    await _inbound.close();
    await _events.close();
  }
}

/// Bounded-concurrency task runner (moved verbatim from v1's `StreamingService`).
/// Caps in-flight async tasks at [_max]; excess tasks queue and run as slots
/// free. Used by [WsTransport.scanSubnet] to avoid opening 254 sockets at once.
class ConcurrencyLimiter {
  final int _max;
  int _running = 0;
  final List<Completer<void>> _queue = [];
  final List<FutureOr<void> Function()> _tasks = [];

  ConcurrencyLimiter(this._max);

  Future<void> run(FutureOr<void> Function() task) async {
    if (_running >= _max) {
      final c = Completer<void>();
      _queue.add(c);
      _tasks.add(task);
      await c.future;
      return;
    }
    _running++;
    try {
      await task();
    } finally {
      _running--;
      if (_queue.isNotEmpty) {
        final nextCompleter = _queue.removeAt(0);
        final nextTask = _tasks.removeAt(0);
        // ignore: unawaited_futures
        _runNext(nextTask, nextCompleter);
      }
    }
  }

  Future<void> _runNext(
    FutureOr<void> Function() task,
    Completer<void> completer,
  ) async {
    _running++;
    try {
      await task();
    } finally {
      _running--;
      completer.complete();
      if (_queue.isNotEmpty) {
        final nextCompleter = _queue.removeAt(0);
        final nextTask = _tasks.removeAt(0);
        // ignore: unawaited_futures
        _runNext(nextTask, nextCompleter);
      }
    }
  }
}
