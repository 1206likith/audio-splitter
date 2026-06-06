import '../../core/contracts/audio_format.dart';
import '../dsp/parametric_eq.dart';

/// A **zone routing rule** — the Phase 3 control-plane message that tells the
/// [SourceRouter] how to build one output mix (the plan's `stream_id →
/// {source_ids, gain, EQ, fx send}`).
///
/// A "zone" is an independent output bus: a room, a stage monitor, a recording
/// stem, a Bluetooth speaker group. Each zone selects a subset of the active
/// sources, mixes them at per-source gains, then runs its own post-mix DSP
/// chain (tone EQ → optional glue compression → safety limiter). M sources fan
/// into N zones; this rule describes one of the N.
///
/// It is a plain, JSON-serializable value so it can ride the parallel control
/// channel ([ControlMessage]) and be diffed/persisted as zone state.
class ZoneRoute {
  /// Stable zone id; also the `stream_id` of the mix this zone emits.
  final String zoneId;

  /// Human-facing label (e.g. "Patio", "DJ Monitor"). Defaults to [zoneId].
  final String name;

  /// Per-source linear gain (`source_id → gain`). A source absent from this map
  /// does not feed the zone; the set of keys is the zone's input edge set.
  final Map<String, double> sourceGains;

  /// Post-mix tone EQ (the plan's per-zone "5-band parametric EQ"). Empty ⇒ no
  /// EQ stage.
  final List<EqBand> eq;

  /// Apply per-zone glue compression after the EQ. Off by default; live mixes
  /// often want it, stems usually do not.
  final bool compress;

  /// Apply the −1 dBTP safety limiter as the final post-mix node. On by default
  /// so a zone can never clip a sink regardless of summed source levels.
  final bool limit;

  /// **Mix-minus**: when set, this source is excluded from the zone even though
  /// it may appear in [sourceGains]. A performer's monitor zone sets this to
  /// their own source id so they never hear themselves echoed back. `null` ⇒ a
  /// normal full mix.
  final String? mixMinusSourceId;

  /// Spatial **HRTF mode** flag — a stub seam for Phase 6 (binaural/ambisonic
  /// rendering per zone). The mix engine ignores it today; it only needs to
  /// survive serialization so the control plane and zone UI can carry it now.
  final bool hrtfMode;

  const ZoneRoute({
    required this.zoneId,
    String? name,
    this.sourceGains = const {},
    this.eq = const [],
    this.compress = false,
    this.limit = true,
    this.mixMinusSourceId,
    this.hrtfMode = false,
  }) : name = name ?? zoneId;

  /// The source ids that actually feed the mix, with [mixMinusSourceId] removed.
  Iterable<String> get contributingSourceIds =>
      sourceGains.keys.where((id) => id != mixMinusSourceId);

  /// Linear gain for [sourceId], or 0 if it does not feed this zone (or is the
  /// mix-minus exclusion).
  double gainFor(String sourceId) =>
      sourceId == mixMinusSourceId ? 0.0 : (sourceGains[sourceId] ?? 0.0);

  /// True when [other] differs in a way that requires rebuilding the post-mix
  /// DSP chain (gains and mix-minus are hot-swappable; EQ/dynamics are not,
  /// because they carry filter state).
  bool dspDiffersFrom(ZoneRoute other) =>
      compress != other.compress ||
      limit != other.limit ||
      eq.length != other.eq.length ||
      !_eqEquals(eq, other.eq);

  static bool _eqEquals(List<EqBand> a, List<EqBand> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  ZoneRoute copyWith({
    String? name,
    Map<String, double>? sourceGains,
    List<EqBand>? eq,
    bool? compress,
    bool? limit,
    String? mixMinusSourceId,
    bool clearMixMinus = false,
    bool? hrtfMode,
  }) {
    return ZoneRoute(
      zoneId: zoneId,
      name: name ?? this.name,
      sourceGains: sourceGains ?? this.sourceGains,
      eq: eq ?? this.eq,
      compress: compress ?? this.compress,
      limit: limit ?? this.limit,
      mixMinusSourceId:
          clearMixMinus ? null : (mixMinusSourceId ?? this.mixMinusSourceId),
      hrtfMode: hrtfMode ?? this.hrtfMode,
    );
  }

  Map<String, dynamic> toJson() => {
        'zoneId': zoneId,
        'name': name,
        'sourceGains': sourceGains,
        'eq': [for (final b in eq) b.toJson()],
        'compress': compress,
        'limit': limit,
        if (mixMinusSourceId != null) 'mixMinusSourceId': mixMinusSourceId,
        'hrtfMode': hrtfMode,
      };

  factory ZoneRoute.fromJson(Map<String, dynamic> json) => ZoneRoute(
        zoneId: json['zoneId'] as String,
        name: json['name'] as String?,
        sourceGains: {
          for (final e in (json['sourceGains'] as Map).entries)
            e.key as String: (e.value as num).toDouble(),
        },
        eq: [
          for (final b in (json['eq'] as List? ?? const []))
            EqBand.fromJson((b as Map).cast<String, dynamic>()),
        ],
        compress: json['compress'] as bool? ?? false,
        limit: json['limit'] as bool? ?? true,
        mixMinusSourceId: json['mixMinusSourceId'] as String?,
        hrtfMode: json['hrtfMode'] as bool? ?? false,
      );

  /// Output format of the zone mix. Phase 3 zones are CD-stereo by default;
  /// carried as metadata here so a future monitor zone could request mono.
  static const AudioFormat defaultFormat = AudioFormat.cdStereo;

  @override
  String toString() => 'ZoneRoute($zoneId "$name", '
      'sources=${sourceGains.length}, '
      '${mixMinusSourceId != null ? 'mix-minus=$mixMinusSourceId, ' : ''}'
      'eq=${eq.length}, comp=$compress, limit=$limit, hrtf=$hrtfMode)';
}
