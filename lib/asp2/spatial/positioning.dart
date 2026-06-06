import 'dart:math' as math;

/// A 2-D point/vector on the venue floorplan, in **metres**. The floorplan
/// origin is arbitrary (top-left of the host's map) and shared by every client,
/// so a position telemetry value means the same thing on every device.
class Vec2 {
  final double x;
  final double y;

  const Vec2(this.x, this.y);

  static const Vec2 zero = Vec2(0, 0);

  Vec2 operator +(Vec2 o) => Vec2(x + o.x, y + o.y);
  Vec2 operator -(Vec2 o) => Vec2(x - o.x, y - o.y);
  Vec2 scale(double s) => Vec2(x * s, y * s);

  /// Euclidean distance to [o], metres.
  double distanceTo(Vec2 o) {
    final dx = x - o.x, dy = y - o.y;
    return math.sqrt(dx * dx + dy * dy);
  }

  /// Linear interpolation toward [o] by [t] in `[0,1]` (the "walk" parameter).
  Vec2 lerp(Vec2 o, double t) => Vec2(x + (o.x - x) * t, y + (o.y - y) * t);

  Map<String, dynamic> toJson() => {'x': x, 'y': y};

  factory Vec2.fromJson(Map<String, dynamic> json) =>
      Vec2((json['x'] as num).toDouble(), (json['y'] as num).toDouble());

  @override
  bool operator ==(Object other) =>
      other is Vec2 && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);

  @override
  String toString() => 'Vec2(${x.toStringAsFixed(2)}, ${y.toStringAsFixed(2)})';
}

/// Where a listener is and which way they face — the per-client telemetry that
/// drives both zone-bleed crossfade ([Floorplan]) and head-tracked spatial
/// rendering (ambisonic/HRTF). [headingDeg] is a compass-style yaw in degrees
/// (0 = facing +Y / "into the room", increasing clockwise), the only orientation
/// a first-order ambisonic decode needs.
class ListenerPose {
  final Vec2 position;
  final double headingDeg;

  const ListenerPose({this.position = Vec2.zero, this.headingDeg = 0.0});

  /// Heading folded to `[0, 360)`.
  double get normalizedHeadingDeg {
    var h = headingDeg % 360.0;
    if (h < 0) h += 360.0;
    return h;
  }

  ListenerPose copyWith({Vec2? position, double? headingDeg}) => ListenerPose(
        position: position ?? this.position,
        headingDeg: headingDeg ?? this.headingDeg,
      );

  Map<String, dynamic> toJson() =>
      {'position': position.toJson(), 'headingDeg': headingDeg};

  factory ListenerPose.fromJson(Map<String, dynamic> json) => ListenerPose(
        position:
            Vec2.fromJson((json['position'] as Map).cast<String, dynamic>()),
        headingDeg: (json['headingDeg'] as num?)?.toDouble() ?? 0.0,
      );

  @override
  bool operator ==(Object other) =>
      other is ListenerPose &&
      other.position == position &&
      other.headingDeg == headingDeg;

  @override
  int get hashCode => Object.hash(position, headingDeg);

  @override
  String toString() =>
      'ListenerPose($position, ${headingDeg.toStringAsFixed(0)}°)';
}

/// A named region of the venue with an acoustic centre — a "room" or area that
/// maps to a mix [zoneId] (the Phase 3 [ZoneRoute] id). A listener near this
/// centre hears mostly this zone; the crossfade between zones is handled by
/// [Floorplan.zoneGainsAt].
class RoomZone {
  /// The mix zone id this room plays (matches a [ZoneRoute.zoneId]).
  final String zoneId;

  /// Acoustic centre of the room on the floorplan, metres.
  final Vec2 center;

  /// Human label.
  final String name;

  const RoomZone({
    required this.zoneId,
    required this.center,
    String? name,
  }) : name = name ?? zoneId;

  Map<String, dynamic> toJson() =>
      {'zoneId': zoneId, 'center': center.toJson(), 'name': name};

  factory RoomZone.fromJson(Map<String, dynamic> json) => RoomZone(
        zoneId: json['zoneId'] as String,
        center: Vec2.fromJson((json['center'] as Map).cast<String, dynamic>()),
        name: json['name'] as String?,
      );

  @override
  String toString() => 'RoomZone($zoneId "$name" @$center)';
}

/// The venue map: a set of [RoomZone]s and the rule that turns a listener
/// position into a **zone-bleed crossfade** — the per-zone gains a client mixes
/// so that walking between rooms is a smooth blend rather than a hard cut.
///
/// The gain model is a Gaussian kernel on distance-to-centre, **equal-power**
/// normalized (Σ gain² = 1). At a zone's centre that zone dominates; on the line
/// between two centres the nearer fades up and the farther fades down,
/// monotonically and with constant summed power — the "walk-between-rooms smooth
/// crossfade" the plan's gate calls for. [bleedRadius] (metres) sets how far a
/// room's sound carries: small ⇒ crisp room boundaries, large ⇒ everything
/// blends.
class Floorplan {
  final List<RoomZone> zones;

  /// Gaussian falloff scale in metres (σ). Larger ⇒ more bleed between rooms.
  final double bleedRadius;

  Floorplan(this.zones, {this.bleedRadius = 4.0})
      : assert(bleedRadius > 0, 'bleedRadius must be positive');

  /// Per-zone linear gains at [position], keyed by [RoomZone.zoneId] and
  /// equal-power normalized so Σ gain² = 1 (when at least one zone exists).
  ///
  /// Uses the squared distance in the Gaussian so the math stays in the cheap
  /// domain (no per-zone sqrt). Equal-power normalization keeps perceived
  /// loudness constant as the listener crosses a boundary.
  Map<String, double> zoneGainsAt(Vec2 position) {
    if (zones.isEmpty) return const {};
    final twoSigmaSq = 2 * bleedRadius * bleedRadius;
    final weights = <String, double>{};
    var sumSq = 0.0;
    for (final z in zones) {
      final dx = position.x - z.center.x;
      final dy = position.y - z.center.y;
      final w = math.exp(-(dx * dx + dy * dy) / twoSigmaSq);
      weights[z.zoneId] = w;
      sumSq += w * w;
    }
    final norm = sumSq > 0 ? 1.0 / math.sqrt(sumSq) : 0.0;
    return {
      for (final e in weights.entries) e.key: e.value * norm,
    };
  }

  /// The single nearest zone to [position] (the "you are in room X" label), or
  /// null when the floorplan is empty.
  RoomZone? nearestZone(Vec2 position) {
    RoomZone? best;
    var bestD = double.infinity;
    for (final z in zones) {
      final d = position.distanceTo(z.center);
      if (d < bestD) {
        bestD = d;
        best = z;
      }
    }
    return best;
  }
}

/// Source of live listener positions. The always-available implementation is
/// the manual tap-on-floorplan ([ManualFloorplanPositioning]); beacon-based
/// fixes (BLE room-level, UWB sub-metre) are [needs-hardware] and deferred to
/// [BeaconPositioning].
abstract class PositioningSource {
  /// Most recent known pose, or null until a first fix.
  ListenerPose? get pose;

  /// Whether this source can actually produce fixes on this build/device.
  bool get isAvailable;
}

/// The fallback that always works: the listener taps their spot on the host's
/// floorplan (and optionally drags a heading), so spatial features never hard-
/// depend on beacon hardware. Pure state holder — deterministic, testable.
class ManualFloorplanPositioning implements PositioningSource {
  ListenerPose _pose;

  ManualFloorplanPositioning([ListenerPose? initial])
      : _pose = initial ?? const ListenerPose();

  @override
  ListenerPose get pose => _pose;

  @override
  bool get isAvailable => true;

  /// The user tapped/dragged a new spot (and optionally turned).
  void setPose(ListenerPose pose) => _pose = pose;

  void setPosition(Vec2 position) => _pose = _pose.copyWith(position: position);

  void setHeading(double headingDeg) =>
      _pose = _pose.copyWith(headingDeg: headingDeg);
}

/// **[needs-hardware]** BLE/UWB beacon positioning scaffold. Trilaterating
/// device position from beacon RSSI (room-level) or UWB time-of-flight
/// (sub-metre) needs physical anchors on site, so it is deferred; the manual
/// floorplan source is the live path. The trilateration *math* is left as the
/// device-build's job behind this interface.
class BeaconPositioning implements PositioningSource {
  @override
  ListenerPose? get pose => null;

  @override
  bool get isAvailable => false;

  /// Why beacon positioning isn't active here (surfaced to the UI).
  String get unavailableReason =>
      'No BLE/UWB beacons configured on this build; '
      'use ManualFloorplanPositioning (tap-on-floorplan) instead.';
}
