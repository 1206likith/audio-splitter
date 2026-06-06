import '../contracts/audio_format.dart';
import '../../asp2/mix/zone_mixer.dart';
import '../../asp2/mix/zone_route.dart';
import 'audio_chunk.dart';

/// The **M:N routing DAG** at the heart of Phase 3.
///
/// v1 had exactly one mix: every client heard the same stream. The
/// [SourceRouter] generalizes that to an arbitrary directed graph — M source
/// nodes fan into N zone-mixer nodes, each zone selecting its own subset of
/// sources, gains, EQ, and mix-minus rule via a [ZoneRoute]. The graph shape is
/// pure data (the set of routes), so it can be reconfigured live from the
/// control plane without touching the audio path.
///
/// ```
///   src:mic  ──┐         ┌─ zone:patio   (mic@0.8, music@1.0)
///   src:music ─┼─ router ┼─ zone:stage   (music@1.0, mic mix-minus)
///   src:guest ─┘         └─ zone:record  (all @1.0, no limiter)
/// ```
///
/// Each call to [route] processes **one synchronized frame**: a snapshot of the
/// current chunk from every active source (the scheduler's job to assemble and
/// time-align — that live wiring is deferred to the on-device path, same
/// discipline as Phases 0–2). The router is otherwise a pure, fully testable
/// function from `{source_id → chunk}` to `{zone_id → mixed chunk}`.
class SourceRouter {
  /// Default output format applied to a zone whose route does not request one.
  final AudioFormat zoneFormat;

  final Map<String, ZoneMixer> _zones = {};

  SourceRouter({this.zoneFormat = AudioFormat.cdStereo});

  /// Active zone ids, in insertion order.
  Iterable<String> get zoneIds => _zones.keys;

  int get zoneCount => _zones.length;

  /// The current route for [zoneId], or null if no such zone.
  ZoneRoute? routeFor(String zoneId) => _zones[zoneId]?.route;

  /// Snapshot of every zone's current route.
  List<ZoneRoute> get routes => [for (final z in _zones.values) z.route];

  /// Add a zone or update an existing one. An update reuses the live
  /// [ZoneMixer] (preserving its DSP filter state where the route's DSP config
  /// is unchanged); a new zone id creates a fresh mixer.
  void upsertZone(ZoneRoute route) {
    final existing = _zones[route.zoneId];
    if (existing != null) {
      existing.updateRoute(route);
    } else {
      _zones[route.zoneId] = ZoneMixer(route, format: zoneFormat);
    }
  }

  /// Remove a zone and release its DSP resources. No-op if absent.
  void removeZone(String zoneId) => _zones.remove(zoneId)?.dispose();

  /// Route one synchronized [frame] (`source_id → chunk`) to every zone,
  /// returning `zone_id → mixed chunk`. [tsUs] is the presentation timestamp
  /// stamped on every zone output (the frame's shared host-clock time).
  Map<String, PcmChunk> route(Map<String, PcmChunk> frame,
      {required int tsUs}) {
    final out = <String, PcmChunk>{};
    for (final entry in _zones.entries) {
      out[entry.key] = entry.value.render(frame, tsUs: tsUs);
    }
    return out;
  }

  /// Tear down every zone mixer. Safe to call repeatedly.
  void dispose() {
    for (final z in _zones.values) {
      z.dispose();
    }
    _zones.clear();
  }
}
