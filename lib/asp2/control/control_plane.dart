import 'dart:convert';

import '../mix/zone_route.dart';
import '../party/beat_grid.dart';
import '../party/karaoke.dart';
import '../party/reactions.dart';
import '../spatial/positioning.dart';
import '../sync/client_sync_report.dart';
import '../sync/ptp_lite.dart';

/// The kinds of message that ride the **control plane** — the parallel,
/// reliable channel that runs alongside the real-time audio path (the plan's
/// `⇅ Control Plane`). Audio frames carry samples; control messages carry
/// everything *about* the session: clock sync, telemetry, routing, and (later
/// phases) beat grids, reactions, captions.
enum ControlMessageType {
  /// Client→host clock-sync probe ([PtpProbe]).
  ptpProbe,

  /// Host→client clock-sync response ([PtpResponse]).
  ptpResponse,

  /// Client→host playout telemetry ([ClientSyncReport]).
  syncReport,

  /// Host→clients (or host-local) zone routing rule ([ZoneRoute]) — Phase 3.
  zoneRoute,

  /// Host→clients zone teardown: payload `{zoneId}`.
  zoneRemove,

  /// Host→clients beat grid ([BeatGrid]) — Phase 5. Lets every client lock
  /// lights/haptics/visuals to the music's pulse.
  beatGrid,

  /// Client→host crowd reaction ([Reaction]) — Phase 5. Feeds the energy meter.
  reaction,

  /// Host→clients on-screen caption/lyric line ([CaptionLine]) — Phase 5
  /// (karaoke) and reused by Phase 6 (live STT captions/translation).
  caption,

  /// Client→host listener position + heading ([ListenerPose]) — Phase 6. Feeds
  /// the zone-bleed crossfade (which rooms the client mixes) and head-tracked
  /// spatial rendering.
  listenerPose,
}

/// A typed, JSON-serializable envelope for one control-plane message.
///
/// Phase 2 introduced the individual payloads ([PtpProbe], [PtpResponse],
/// [ClientSyncReport]); Phase 3 adds [ZoneRoute] and the need to multiplex them
/// over one channel. [ControlMessage] is that multiplexer: a discriminated
/// union of `{type, data}` that wraps the existing payloads without changing
/// them, so the control channel can carry any message type and the receiver can
/// dispatch on [type].
///
/// Wire form is JSON (the control plane is reliable and low-rate, so the audio
/// path's binary ASP-2 framing is unnecessary here): `{"type": "...", "data":
/// {...}}`.
class ControlMessage {
  final ControlMessageType type;

  /// The wrapped payload as a JSON map. Use the typed accessors
  /// ([asPtpProbe], [asZoneRoute], …) to decode it.
  final Map<String, dynamic> data;

  const ControlMessage(this.type, this.data);

  ControlMessage.ptpProbe(PtpProbe probe)
      : type = ControlMessageType.ptpProbe,
        data = probe.toJson();

  ControlMessage.ptpResponse(PtpResponse response)
      : type = ControlMessageType.ptpResponse,
        data = response.toJson();

  ControlMessage.syncReport(ClientSyncReport report)
      : type = ControlMessageType.syncReport,
        data = report.toJson();

  ControlMessage.zoneRoute(ZoneRoute route)
      : type = ControlMessageType.zoneRoute,
        data = route.toJson();

  ControlMessage.zoneRemove(String zoneId)
      : type = ControlMessageType.zoneRemove,
        data = {'zoneId': zoneId};

  ControlMessage.beatGrid(BeatGrid grid)
      : type = ControlMessageType.beatGrid,
        data = grid.toJson();

  ControlMessage.reaction(Reaction reaction)
      : type = ControlMessageType.reaction,
        data = reaction.toJson();

  ControlMessage.caption(CaptionLine line)
      : type = ControlMessageType.caption,
        data = line.toJson();

  ControlMessage.listenerPose(ListenerPose pose)
      : type = ControlMessageType.listenerPose,
        data = pose.toJson();

  PtpProbe asPtpProbe() => PtpProbe.fromJson(data);
  PtpResponse asPtpResponse() => PtpResponse.fromJson(data);
  ClientSyncReport asSyncReport() => ClientSyncReport.fromJson(data);
  ZoneRoute asZoneRoute() => ZoneRoute.fromJson(data);
  String asZoneRemoveId() => data['zoneId'] as String;
  BeatGrid asBeatGrid() => BeatGrid.fromJson(data);
  Reaction asReaction() => Reaction.fromJson(data);
  CaptionLine asCaption() => CaptionLine.fromJson(data);
  ListenerPose asListenerPose() => ListenerPose.fromJson(data);

  Map<String, dynamic> toJson() => {'type': type.name, 'data': data};

  factory ControlMessage.fromJson(Map<String, dynamic> json) => ControlMessage(
        ControlMessageType.values.byName(json['type'] as String),
        (json['data'] as Map).cast<String, dynamic>(),
      );

  /// Encode straight to a wire string for the transport.
  String encode() => jsonEncode(toJson());

  /// Decode a wire string back into a typed message.
  factory ControlMessage.decode(String wire) => ControlMessage.fromJson(
      (jsonDecode(wire) as Map).cast<String, dynamic>());

  /// Like [decode] but never throws (Phase 8 hardening). Returns null on
  /// malformed JSON, a non-object root, a missing/non-object `data` field, or an
  /// unknown message `type`. The control plane's receive path uses this so a
  /// corrupt or hostile peer can't crash the host with a bad frame — the message
  /// is simply dropped. Per-type payload decoding (the `as…` accessors) still
  /// assumes a well-formed envelope; wrap those at the dispatch site if the
  /// payload itself is untrusted.
  static ControlMessage? tryDecode(String wire) {
    try {
      return ControlMessage.decode(wire);
    } catch (_) {
      return null;
    }
  }

  @override
  String toString() => 'ControlMessage(${type.name}, $data)';
}
