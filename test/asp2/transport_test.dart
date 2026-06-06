import 'dart:async';
import 'dart:typed_data';

import 'package:audio_splitter_app/core/contracts/audio_format.dart';
import 'package:audio_splitter_app/core/contracts/i_transport.dart';
import 'package:audio_splitter_app/core/pipeline/audio_chunk.dart';
import 'package:audio_splitter_app/asp2/sinks/bt_a2dp_sink.dart';
import 'package:audio_splitter_app/asp2/transport/discovery.dart';
import 'package:audio_splitter_app/asp2/transport/hls_fallback.dart';
import 'package:audio_splitter_app/asp2/transport/lossy_transport.dart';
import 'package:audio_splitter_app/asp2/transport/mesh_relay.dart';
import 'package:audio_splitter_app/asp2/transport/quic_transport.dart';
import 'package:audio_splitter_app/asp2/transport/transport_exceptions.dart';
import 'package:audio_splitter_app/asp2/transport/webrtc_transport.dart';
import 'package:flutter_test/flutter_test.dart';

/// A trivial in-memory [ITransport] used to exercise the [LossyTransport]
/// decorator deterministically (no sockets, no wall clock). [injectInbound]
/// pushes a frame as if it arrived from a peer; [send] records sent frames.
class FakeTransport implements ITransport {
  final StreamController<Uint8List> _inbound =
      StreamController<Uint8List>.broadcast();
  final StreamController<TransportEvent> _events =
      StreamController<TransportEvent>.broadcast();
  final List<Uint8List> sent = [];

  void injectInbound(Uint8List frame) {
    if (!_inbound.isClosed) _inbound.add(frame);
  }

  @override
  String get name => 'fake';
  @override
  Stream<Uint8List> get inbound => _inbound.stream;
  @override
  Stream<TransportEvent> get events => _events.stream;
  @override
  Future<void> startServer({required int port}) async {}
  @override
  Future<void> connect({required String host, required int port}) async {}
  @override
  void send(int streamId, Uint8List frameBytes) => sent.add(frameBytes);
  @override
  Future<void> dispose() async {
    await _inbound.close();
    await _events.close();
  }
}

Uint8List frame(int n) =>
    Uint8List.fromList(List<int>.generate(16, (i) => (n + i) & 0xFF));

void main() {
  // ─────────────────────────────────────────────────────────────────────────
  group('MeshRelayPlanner', () {
    // A star where every peer has a direct (cheap) link to the host plus a few
    // peer-peer links, so relaying is possible when host fanout is capped.
    RttMatrix buildFullMatrix(int peerCount, {double base = 10}) {
      final m = RttMatrix();
      final peers = [for (var i = 0; i < peerCount; i++) 'p$i'];
      for (var i = 0; i < peerCount; i++) {
        // host link gets progressively more expensive so order is deterministic
        m.addLink(kMeshHostId, peers[i], base + i);
        for (var j = i + 1; j < peerCount; j++) {
          m.addLink(peers[i], peers[j], base + (i + j));
        }
      }
      return m;
    }

    test('cheapest peers attach directly to the host first', () {
      final m = buildFullMatrix(4);
      const planner = MeshRelayPlanner(hostFanout: 2, relayFanout: 2);
      final plan = planner.plan(m);

      expect(plan.isComplete, isTrue);
      // p0 and p1 have the cheapest host links → host's direct children.
      expect(plan.children[kMeshHostId], containsAll(<String>['p0', 'p1']));
      expect(plan.hostChildCount, 2);
    });

    test('host fanout cap is never exceeded yet all peers are reached', () {
      final m = buildFullMatrix(12);
      const planner = MeshRelayPlanner(hostFanout: 3, relayFanout: 3);
      final plan = planner.plan(m);

      expect(plan.isComplete, isTrue, reason: 'every peer placed');
      expect(plan.hostChildCount, lessThanOrEqualTo(3));
      expect(plan.maxDepth, greaterThan(1), reason: 'relays were used');
      // Every relay also respects its fanout budget.
      for (final entry in plan.children.entries) {
        if (entry.key == kMeshHostId) continue;
        expect(entry.value.length, lessThanOrEqualTo(3));
      }
    });

    test('every reached peer has a valid host-rooted path with rising latency',
        () {
      final m = buildFullMatrix(10);
      const planner = MeshRelayPlanner(hostFanout: 2, relayFanout: 3);
      final plan = planner.plan(m);

      for (final peer in plan.parent.keys) {
        final path = plan.pathTo(peer);
        expect(path, isNotNull);
        expect(path!.first, kMeshHostId);
        expect(path.last, peer);
        // Latency is monotonically non-decreasing along the path from the host.
        for (var i = 1; i < path.length; i++) {
          expect(plan.latencyMs[path[i]]!,
              greaterThanOrEqualTo(plan.latencyMs[path[i - 1]]!));
        }
      }
    });

    test('peers with no link are reported as unreached, not dropped silently',
        () {
      final m = RttMatrix()
        ..addLink(kMeshHostId, 'p0', 10)
        ..addLink(kMeshHostId, 'p1', 12);
      // p2 appears only via an isolated peer-peer link to nobody in the tree.
      m.addLink('p2', 'p3', 5);
      const planner = MeshRelayPlanner(hostFanout: 4, relayFanout: 4);
      final plan = planner.plan(m, peers: ['p0', 'p1', 'p2', 'p3']);

      expect(plan.parent.keys, containsAll(<String>['p0', 'p1']));
      expect(plan.unreached, containsAll(<String>['p2', 'p3']));
      expect(plan.isComplete, isFalse);
    });

    test('hostFanout 0 leaves every peer unreached (host cannot serve)', () {
      final m = buildFullMatrix(5);
      const planner = MeshRelayPlanner(hostFanout: 0, relayFanout: 4);
      final plan = planner.plan(m);
      expect(plan.parent, isEmpty);
      expect(plan.unreached.length, 5);
    });

    test('the plan is a pure function of the matrix (deterministic)', () {
      final m = buildFullMatrix(8);
      const planner = MeshRelayPlanner(hostFanout: 3, relayFanout: 2);
      final a = planner.plan(m);
      final b = planner.plan(m);
      expect(a.parent, b.parent);
      expect(a.depth, b.depth);
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  group('LossyTransport', () {
    test('zero loss forwards every inbound frame', () async {
      final fake = FakeTransport();
      final lossy = LossyTransport(fake);
      final got = <Uint8List>[];
      final sub = lossy.inbound.listen(got.add);

      for (var i = 0; i < 50; i++) {
        fake.injectInbound(frame(i));
      }
      await Future<void>.delayed(Duration.zero);
      expect(got.length, 50);
      expect(lossy.inboundDropped, 0);

      await sub.cancel();
      await lossy.dispose();
    });

    test('inbound loss drops a deterministic, reproducible subset', () async {
      Future<List<int>> once() async {
        final fake = FakeTransport();
        final lossy = LossyTransport(fake, inboundLoss: 0.5, seed: 777);
        final got = <int>[];
        final sub = lossy.inbound.listen((f) => got.add(f[0]));
        for (var i = 0; i < 100; i++) {
          fake.injectInbound(frame(i));
        }
        await Future<void>.delayed(Duration.zero);
        await sub.cancel();
        await lossy.dispose();
        return got;
      }

      final a = await once();
      final b = await once();
      expect(a, b, reason: 'same seed + order ⇒ identical surviving frames');
      expect(a.length, lessThan(100), reason: 'some frames dropped');
      expect(a.length, greaterThan(0), reason: 'not everything dropped');
    });

    test('outbound loss drops sent frames but keeps the rest flowing', () {
      final fake = FakeTransport();
      final lossy = LossyTransport(fake, outboundLoss: 0.5, seed: 42);
      for (var i = 0; i < 100; i++) {
        lossy.send(0, frame(i));
      }
      expect(lossy.outboundSeen, 100);
      expect(fake.sent.length, 100 - lossy.outboundDropped);
      expect(lossy.outboundDropped, greaterThan(0));
      expect(fake.sent.length, greaterThan(0));
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  group('HlsSegmenter', () {
    test('accumulates frames into target-duration segments, preserving bytes',
        () {
      final closed = <HlsSegment>[];
      final seg = HlsSegmenter(
        targetDuration: const Duration(seconds: 6),
        windowSize: 10,
        onSegment: closed.add,
      );
      // 30 frames × 1000ms = 30s ⇒ 5 segments of 6s (6 frames each).
      for (var i = 0; i < 30; i++) {
        seg.addFrame(Uint8List(100), durationMs: 1000);
      }
      expect(closed.length, 5);
      for (final s in closed) {
        expect(s.durationMs, 6000);
        expect(s.bytes.length, 30 * 100 / 5 * 1, reason: 'bytes preserved');
      }
      // Sequence numbers are monotonic from 0.
      expect([for (final s in closed) s.sequence], [0, 1, 2, 3, 4]);
    });

    test('window slides: only the most recent N segments stay in the playlist',
        () {
      final seg = HlsSegmenter(
        targetDuration: const Duration(seconds: 6),
        windowSize: 3,
      );
      for (var i = 0; i < 60; i++) {
        seg.addFrame(Uint8List(10), durationMs: 1000); // 6 frames/seg ⇒ 10 segs
      }
      expect(seg.segments.length, 3);
      expect(seg.segments.first.sequence, 7); // 0..9 closed, window keeps 7,8,9
      final m3u8 = seg.playlist();
      expect(m3u8, contains('#EXTM3U'));
      expect(m3u8, contains('#EXT-X-MEDIA-SEQUENCE:7'));
      expect(m3u8, contains('#EXT-X-TARGETDURATION:6'));
      expect(m3u8, contains('seg7.ts'));
      expect(m3u8, isNot(contains('seg6.ts')));
    });

    test('flush emits the short tail segment and endList tags VOD', () {
      final seg = HlsSegmenter(targetDuration: const Duration(seconds: 6));
      seg.addFrame(Uint8List(50), durationMs: 1000); // only 1s, below target
      expect(seg.segments, isEmpty);
      final tail = seg.flush();
      expect(tail, isNotNull);
      expect(tail!.durationMs, 1000);
      expect(seg.flush(), isNull, reason: 'nothing left to flush');
      expect(seg.playlist(endList: true), contains('#EXT-X-ENDLIST'));
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  group('Discovery (dual-stack)', () {
    test('service identity constants match RFC 6762 / the plan', () {
      expect(kServiceType, '_asplitter._tcp');
      expect(kMdnsIPv6Group, 'ff02::fb');
      expect(kMdnsIPv4Group, '224.0.0.251');
      expect(kMdnsPort, 5353);
    });

    test('HostDescriptor round-trips through JSON', () {
      const d = HostDescriptor(
        id: 'h1',
        name: 'Living Room',
        endpoints: [
          HostEndpoint('192.168.1.10', AddressFamily.ipv4),
          HostEndpoint('fe80::1', AddressFamily.ipv6),
        ],
        port: 8080,
        capabilities: {'ws', 'quic', 'mesh', 'hls'},
      );
      final back = HostDescriptor.fromJson(d.toJson());
      expect(back.id, 'h1');
      expect(back.name, 'Living Room');
      expect(back.endpoints, d.endpoints);
      expect(back.port, 8080);
      expect(back.capabilities, d.capabilities);
      expect(back.supports('quic'), isTrue);
    });

    test('endpoints are dialed IPv6-first, IPv4 as fallback', () {
      const d = HostDescriptor(
        id: 'h',
        name: 'h',
        endpoints: [
          HostEndpoint('10.0.0.5', AddressFamily.ipv4),
          HostEndpoint('2001:db8::5', AddressFamily.ipv6),
          HostEndpoint('10.0.0.6', AddressFamily.ipv4),
        ],
      );
      final pref = d.preferredEndpoints;
      expect(pref.first.family, AddressFamily.ipv6);
      expect(pref.last.family, AddressFamily.ipv4);
      expect(d.hasIPv6, isTrue);
    });

    test('HostEndpoint.infer reads family from the address text', () {
      expect(HostEndpoint.infer('192.168.0.1').family, AddressFamily.ipv4);
      expect(HostEndpoint.infer('fe80::abcd').family, AddressFamily.ipv6);
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  group('WebRtcTransport / QuicTransport scaffolds ([needs-service])', () {
    test('SfuConfig validates and round-trips', () {
      const cfg = SfuConfig(
        url: 'wss://x.livekit.cloud',
        room: 'party',
        token: 'jwt',
        iceServers: ['stun:stun.l.google.com:19302'],
      );
      expect(cfg.isValid, isTrue);
      expect(SfuConfig.fromJson(cfg.toJson()).room, 'party');
      expect(const SfuConfig(url: '', room: '', token: '').isValid, isFalse);
    });

    test('webrtc is unavailable in this build and fails recoverably', () async {
      expect(WebRtcTransport.isAvailable, isFalse);
      final t = WebRtcTransport(
        config: const SfuConfig(url: 'wss://x', room: 'r', token: 't'),
      );
      expect(t.name, 'webrtc-sfu');
      await expectLater(
        t.connect(host: 'x', port: 0),
        throwsA(isA<TransportUnavailableException>()),
      );
      await t.dispose();
    });

    test('quic is unavailable and models path migration state', () async {
      expect(QuicTransport.isAvailable, isFalse);
      final t = QuicTransport();
      expect(t.pathState, QuicPathState.idle);
      await expectLater(
        t.startServer(port: 0),
        throwsA(isA<TransportUnavailableException>()),
      );
      await t.dispose();
      expect(t.pathState, QuicPathState.closed);

      const mig = QuicMigration(fromPath: 'wifi', toPath: 'cellular');
      expect(mig.validated, isFalse);
      expect(mig.validate().validated, isTrue);
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  group('BtA2dpSink ([needs-hardware])', () {
    test('simulate mode opens and records what it was asked to play', () async {
      final sink = BtA2dpSink(deviceId: 'AA:BB:CC', simulate: true);
      expect(await sink.open(AudioFormat.cdStereo), isTrue);
      sink.write(PcmChunk(
        pcm: Uint8List(3840),
        presentationTsUs: 1000,
        format: AudioFormat.cdStereo,
      ));
      sink.write(PcmChunk(
        pcm: Uint8List(3840),
        presentationTsUs: 21000,
        format: AudioFormat.cdStereo,
      ));
      expect(sink.chunksWritten, 2);
      expect(sink.bytesWritten, 7680);
      expect(sink.lastTsUs, 21000);
      await sink.close();
      expect(sink.isOpen, isFalse);
    });

    test('real mode defers with a clear unavailable reason', () async {
      final sink = BtA2dpSink(deviceId: 'AA:BB:CC', simulate: false);
      expect(await sink.open(AudioFormat.cdStereo), isFalse);
      expect(sink.unavailableReason, isNotNull);
      expect(sink.unavailableReason, contains('AA:BB:CC'));
      // Writing before a successful open is tolerated (never throws).
      sink.write(PcmChunk(
        pcm: Uint8List(10),
        presentationTsUs: 0,
        format: AudioFormat.cdStereo,
      ));
      expect(sink.chunksWritten, 0);
    });
  });

  // ─────────────────────────────────────────────────────────────────────────
  // PHASE 4 GATE — "mesh survives host bandwidth saturation".
  //
  // 30 listeners, each with a host link and a web of peer-peer links. We then
  // *saturate the host*: cap its direct fanout to 2 (it can only upload two
  // streams). The mesh must still deliver to all 30 by relaying, the host's
  // direct load must stay ≤ 2, and a LossyTransport proves the relay edges
  // tolerate real packet loss without the plan ever depending on wall-clock or
  // randomness.
  // ─────────────────────────────────────────────────────────────────────────
  test('PHASE 4 GATE: mesh reaches all peers under host saturation + loss',
      () async {
    const peerCount = 30;
    final m = RttMatrix();
    final peers = [for (var i = 0; i < peerCount; i++) 'p$i'];
    for (var i = 0; i < peerCount; i++) {
      m.addLink(kMeshHostId, peers[i], 10 + (i % 7)); // varied host RTTs
      // a sparse but connected peer web: link each peer to the next 3
      for (var d = 1; d <= 3 && i + d < peerCount; d++) {
        m.addLink(peers[i], peers[i + d], 5 + d.toDouble());
      }
    }

    const saturated = MeshRelayPlanner(hostFanout: 2, relayFanout: 4);
    final plan = saturated.plan(m);

    // 1. Every listener is reached despite the host serving only 2 directly.
    expect(plan.isComplete, isTrue,
        reason: 'all $peerCount peers placed in the relay tree');
    expect(plan.hostChildCount, lessThanOrEqualTo(2),
        reason: 'host upload stayed within its saturated budget');
    expect(plan.maxDepth, greaterThan(1), reason: 'relays carried the load');

    // 2. No relay exceeds its own fanout budget (no peer is over-tasked).
    for (final e in plan.children.entries) {
      if (e.key == kMeshHostId) continue;
      expect(e.value.length, lessThanOrEqualTo(4));
    }

    // 3. Every peer has a finite host-rooted relay path.
    for (final peer in peers) {
      final path = plan.pathTo(peer);
      expect(path, isNotNull, reason: '$peer reachable from host');
      expect(plan.latencyMs[peer], isNotNull);
      expect(plan.latencyMs[peer]!.isFinite, isTrue);
    }

    // 4. A relay edge survives 30% packet loss deterministically (FEC/PLC is
    //    the recovery layer; here we prove the decorator + path move bytes).
    final fake = FakeTransport();
    final relayEdge = LossyTransport(fake, inboundLoss: 0.30, seed: 2026);
    final delivered = <int>[];
    final sub = relayEdge.inbound.listen((f) => delivered.add(f[0]));
    for (var i = 0; i < 200; i++) {
      fake.injectInbound(frame(i));
    }
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();
    await relayEdge.dispose();

    expect(delivered.length, greaterThan(0));
    expect(delivered.length, lessThan(200));
    final lossPct = relayEdge.inboundDropped / relayEdge.inboundSeen;
    expect(lossPct, closeTo(0.30, 0.10),
        reason: 'injected loss ~30% as configured');

    // ignore: avoid_print
    print('Phase 4 gate: $peerCount listeners, host fanout capped at '
        '${plan.hostChildCount}, relay tree depth ${plan.maxDepth}, '
        'max relay latency ${plan.maxLatencyMs.toStringAsFixed(1)}ms; '
        'relay edge held under ${(lossPct * 100).toStringAsFixed(0)}% loss '
        '(${delivered.length}/200 delivered pre-FEC).');
  });
}
