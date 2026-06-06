import 'dart:async';
import 'dart:typed_data';

import '../../core/contracts/i_transport.dart';

/// LossyTransport — a deterministic packet-loss decorator over any [ITransport].
///
/// The plan's verification section calls for "a reusable LossyTransport
/// decorator [that] injects packet loss for pipeline tests". This is it: wrap a
/// real transport (LAN WebSocket, an in-memory loopback, …) and it forwards
/// every API verbatim **except** that a configurable fraction of frames are
/// dropped on the way in and/or out. It is what lets the FEC/PLC resilience
/// tests and the Phase 4 mesh host-saturation test exercise loss without a flaky
/// real network.
///
/// Loss is driven by a **seeded linear congruential generator**, never
/// [Math.random] or the wall clock, so a given (seed, frame order) always drops
/// exactly the same frames — every test is reproducible and order-independent of
/// real time, consistent with the rest of the ASP-2 test suite.
///
/// Control-plane traffic and lifecycle events pass through untouched: only the
/// binary media path ([send] / [inbound]) is subject to loss, matching how a
/// real lossy link behaves (the reliable control channel would be retransmitted).
class LossyTransport implements ITransport {
  final ITransport _inner;

  /// Fraction in [0,1] of inbound media frames to drop.
  final double inboundLoss;

  /// Fraction in [0,1] of outbound (sent) media frames to drop.
  final double outboundLoss;

  int _state;

  int _inboundSeen = 0;
  int _inboundDropped = 0;
  int _outboundSeen = 0;
  int _outboundDropped = 0;

  StreamSubscription<Uint8List>? _sub;
  final StreamController<Uint8List> _inbound =
      StreamController<Uint8List>.broadcast();

  LossyTransport(
    this._inner, {
    this.inboundLoss = 0.0,
    this.outboundLoss = 0.0,
    int seed = 0x1234abcd,
  })  : assert(inboundLoss >= 0 && inboundLoss <= 1, 'inboundLoss in [0,1]'),
        assert(outboundLoss >= 0 && outboundLoss <= 1, 'outboundLoss in [0,1]'),
        _state = seed & 0x7fffffff {
    _sub = _inner.inbound.listen((frame) {
      _inboundSeen++;
      if (_roll() < inboundLoss) {
        _inboundDropped++;
        return;
      }
      if (!_inbound.isClosed) _inbound.add(frame);
    });
  }

  /// Next pseudo-random double in [0,1) from the seeded LCG (glibc constants).
  double _roll() {
    _state = (1103515245 * _state + 12345) & 0x7fffffff;
    return _state / 0x80000000;
  }

  /// Total inbound media frames the decorator has seen.
  int get inboundSeen => _inboundSeen;

  /// Inbound media frames dropped by injected loss.
  int get inboundDropped => _inboundDropped;

  /// Outbound media frames the decorator has seen.
  int get outboundSeen => _outboundSeen;

  /// Outbound media frames dropped by injected loss.
  int get outboundDropped => _outboundDropped;

  @override
  String get name => 'lossy(${_inner.name})';

  @override
  Stream<Uint8List> get inbound => _inbound.stream;

  @override
  Stream<TransportEvent> get events => _inner.events;

  @override
  Future<void> startServer({required int port}) =>
      _inner.startServer(port: port);

  @override
  Future<void> connect({required String host, required int port}) =>
      _inner.connect(host: host, port: port);

  @override
  void send(int streamId, Uint8List frameBytes) {
    _outboundSeen++;
    if (_roll() < outboundLoss) {
      _outboundDropped++;
      return;
    }
    _inner.send(streamId, frameBytes);
  }

  @override
  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
    await _inbound.close();
    await _inner.dispose();
  }
}
