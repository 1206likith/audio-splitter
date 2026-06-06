import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:bonsoir/bonsoir.dart';

class MdnsService {
  static final MdnsService _instance = MdnsService._internal();
  factory MdnsService() => _instance;
  MdnsService._internal();

  BonsoirBroadcast? _broadcast;
  BonsoirDiscovery? _discovery;
  StreamSubscription<BonsoirDiscoveryEvent>? _discoverySub;

  bool get isAdvertising => _broadcast != null;
  bool get isDiscovering => _discovery != null;

  Future<void> advertise(
      {required String name,
      required int port,
      String type = '_audio-splitter._tcp'}) async {
    if (kIsWeb) return; // Not supported on web
    if (_broadcast != null) return;
    final service = BonsoirService(name: name, type: type, port: port);
    _broadcast = BonsoirBroadcast(service: service);
    await _broadcast!.ready;
    await _broadcast!.start();
  }

  Future<void> stopAdvertise() async {
    await _broadcast?.stop();
    _broadcast = null;
  }

  Stream<Map<String, dynamic>> browse(
      {String type = '_audio-splitter._tcp'}) async* {
    if (kIsWeb) return; // No-op on web
    final controller = StreamController<Map<String, dynamic>>();
    _discovery = BonsoirDiscovery(type: type);
    await _discovery!.ready;
    _discoverySub = _discovery!.eventStream!.listen((event) async {
      if (event.type == BonsoirDiscoveryEventType.discoveryServiceResolved) {
        final srv = (event.service as ResolvedBonsoirService);
        final host = srv.host;
        if (host != null) {
          controller.add({'host': host, 'port': srv.port, 'name': srv.name});
        }
      }
    });
    await _discovery!.start();
    yield* controller.stream;
    await _discovery?.stop();
    await _discoverySub?.cancel();
    _discovery = null;
  }

  Future<void> dispose() async {
    await stopAdvertise();
    await _discovery?.stop();
    await _discoverySub?.cancel();
    _discovery = null;
  }
}
