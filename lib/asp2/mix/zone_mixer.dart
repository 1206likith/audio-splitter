import 'dart:typed_data';

import '../../core/contracts/audio_format.dart';
import '../../core/contracts/i_effect.dart';
import '../../core/pipeline/audio_chunk.dart';
import '../dsp/compressor.dart';
import '../dsp/effect_chain.dart';
import '../dsp/limiter.dart';
import '../dsp/parametric_eq.dart';
import '../dsp/pcm_float.dart';
import 'mixer.dart';
import 'zone_route.dart';

/// The stateful mix engine for a single zone.
///
/// Given a [ZoneRoute] and one synchronized frame of source chunks (a map of
/// `source_id → PcmChunk`, all sharing a presentation timestamp), it:
///   1. selects the contributing sources (honouring **mix-minus** — the route's
///      own source is dropped so a performer never hears themselves),
///   2. channel-adapts and weighted-sums them at the route's per-source gains
///      ([Mixer]),
///   3. runs the result through this zone's own post-mix DSP chain (tone EQ →
///      optional glue compression → −1 dBTP safety limiter, reusing the Phase 2
///      effects), whose filter state is **continuous across frames** so feeding
///      20 ms ticks sounds identical to one-shot processing.
///
/// One [ZoneMixer] exists per active zone; the [SourceRouter] owns the set.
class ZoneMixer {
  /// The zone's output PCM format (what every sink on this bus receives).
  final AudioFormat format;

  ZoneRoute _route;
  EffectChain _chain;

  ZoneMixer(ZoneRoute route, {this.format = AudioFormat.cdStereo})
      : _route = route,
        _chain = _buildChain(route, format);

  ZoneRoute get route => _route;

  String get zoneId => _route.zoneId;

  /// Swap in a new [next] route. Gains and mix-minus take effect immediately at
  /// zero cost; the post-mix DSP chain is rebuilt **only** when its
  /// configuration actually changed (rebuilding resets filter state, so we avoid
  /// it on a pure gain tweak — see [ZoneRoute.dspDiffersFrom]).
  void updateRoute(ZoneRoute next) {
    assert(next.zoneId == _route.zoneId, 'updateRoute must keep the same zone');
    if (_route.dspDiffersFrom(next)) {
      _chain.dispose();
      _chain = _buildChain(next, format);
    }
    _route = next;
  }

  /// Render one zone-output chunk from a frame of aligned source chunks.
  ///
  /// Sources not routed to this zone (or the mix-minus exclusion) are ignored.
  /// When no routed source is present this tick the zone still emits aligned
  /// silence (length matched to the frame) rather than a zero-length gap, so a
  /// momentarily-idle source never glitches the bus.
  PcmChunk render(Map<String, PcmChunk> frame, {required int tsUs}) {
    final contributions = <List<Float64List>>[];
    final gains = <double>[];

    for (final id in _route.contributingSourceIds) {
      final chunk = frame[id];
      if (chunk == null || chunk.pcm.isEmpty) continue;
      final channels = PcmFloat.deinterleave(chunk.pcm, chunk.format);
      contributions.add(Mixer.adaptChannels(channels, format.channels));
      gains.add(_route.gainFor(id));
    }

    final List<Float64List> mixed;
    if (contributions.isEmpty) {
      mixed = _silence(_fallbackFrames(frame));
    } else {
      mixed = Mixer.sum(contributions, gains, format.channels);
    }

    final Uint8List pcm = PcmFloat.interleave(mixed, format);
    final out = PcmChunk(pcm: pcm, presentationTsUs: tsUs, format: format);
    return _chain.process(out);
  }

  /// Release the post-mix DSP resources (native handles, delay lines).
  void dispose() => _chain.dispose();

  // Longest chunk anywhere in the frame, in frames — the silence length to emit
  // when this zone has no contributor this tick (keeps zones length-aligned).
  int _fallbackFrames(Map<String, PcmChunk> frame) {
    var maxFrames = 0;
    for (final chunk in frame.values) {
      final f = chunk.pcm.length ~/ chunk.format.frameBytes;
      if (f > maxFrames) maxFrames = f;
    }
    return maxFrames;
  }

  List<Float64List> _silence(int frames) =>
      [for (var c = 0; c < format.channels; c++) Float64List(frames)];

  /// Build the post-mix chain from a route. The limiter is last (so it catches
  /// any overshoot from summing or EQ boost); the compressor, if enabled, sits
  /// between EQ and limiter. An empty config yields an empty (pass-through)
  /// chain.
  static EffectChain _buildChain(ZoneRoute route, AudioFormat format) {
    final effects = <IEffect>[
      if (route.eq.isNotEmpty)
        ParametricEq(format: format, bands: route.eq, id: 'eq-${route.zoneId}'),
      if (route.compress)
        Compressor(
          format: format,
          thresholdDb: -14,
          ratio: 2.0,
          kneeDb: 8,
          makeupDb: 1.0,
          id: 'comp-${route.zoneId}',
        ),
      if (route.limit)
        Limiter(format: format, ceilingDb: -1.0, id: 'limiter-${route.zoneId}'),
    ];
    return EffectChain(effects, id: 'zone-chain-${route.zoneId}');
  }
}
