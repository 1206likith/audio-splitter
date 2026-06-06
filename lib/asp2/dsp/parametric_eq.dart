import 'dart:typed_data';

import '../../core/contracts/audio_format.dart';
import '../../core/contracts/i_effect.dart';
import '../../core/pipeline/audio_chunk.dart';
import 'biquad.dart';
import 'pcm_float.dart';

/// One band of a parametric EQ.
enum EqBandType { peaking, lowShelf, highShelf }

/// Configuration for a single EQ band.
class EqBand {
  final EqBandType type;
  final double freqHz;
  final double q;
  final double gainDb;

  const EqBand({
    required this.type,
    required this.freqHz,
    this.q = 0.707,
    required this.gainDb,
  });

  Biquad design(double sampleRate) {
    switch (type) {
      case EqBandType.peaking:
        return Biquad.peaking(
            freqHz: freqHz, sampleRate: sampleRate, q: q, gainDb: gainDb);
      case EqBandType.lowShelf:
        return Biquad.lowShelf(
            freqHz: freqHz, sampleRate: sampleRate, q: q, gainDb: gainDb);
      case EqBandType.highShelf:
        return Biquad.highShelf(
            freqHz: freqHz, sampleRate: sampleRate, q: q, gainDb: gainDb);
    }
  }

  /// Serialize for the control plane (a zone's EQ rides inside a `ZoneRoute`).
  Map<String, dynamic> toJson() => {
        'type': type.name,
        'freqHz': freqHz,
        'q': q,
        'gainDb': gainDb,
      };

  factory EqBand.fromJson(Map<String, dynamic> json) => EqBand(
        type: EqBandType.values.byName(json['type'] as String),
        freqHz: (json['freqHz'] as num).toDouble(),
        q: (json['q'] as num?)?.toDouble() ?? 0.707,
        gainDb: (json['gainDb'] as num).toDouble(),
      );

  @override
  bool operator ==(Object other) =>
      other is EqBand &&
      other.type == type &&
      other.freqHz == freqHz &&
      other.q == q &&
      other.gainDb == gainDb;

  @override
  int get hashCode => Object.hash(type, freqHz, q, gainDb);
}

/// A cascaded multi-band parametric EQ ([IEffect]). Phase 2 ships this as the
/// per-zone tone shaper (the plan's "5-band parametric EQ per zone"); the band
/// list is free-form so callers can use fewer or more.
///
/// State is per (band × channel), so the filter is continuous across chunk
/// boundaries — feeding audio in 20 ms frames sounds identical to processing it
/// in one pass.
class ParametricEq implements IEffect {
  @override
  final String id;

  final List<EqBand> bands;
  final AudioFormat format;

  final List<Biquad> _biquads;
  // _states[band][channel]
  final List<List<BiquadState>> _states;

  ParametricEq({
    required this.bands,
    this.format = AudioFormat.cdStereo,
    this.id = 'parametric-eq',
  })  : _biquads = [
          for (final b in bands) b.design(format.sampleRate.toDouble())
        ],
        _states = [
          for (var _ = 0; _ < bands.length; _++)
            [for (var c = 0; c < format.channels; c++) BiquadState()]
        ];

  /// A sensible default voice-clarity curve: trim rumble, dip boxiness, lift
  /// presence and air. Used by the voice path and as the A/B reference.
  factory ParametricEq.voiceClarity({AudioFormat? format}) {
    return ParametricEq(
      format: format ?? AudioFormat.voiceMono,
      id: 'eq-voice-clarity',
      bands: const [
        EqBand(type: EqBandType.highShelf, freqHz: 8000, gainDb: 3.5),
        EqBand(type: EqBandType.peaking, freqHz: 3000, q: 1.0, gainDb: 4.0),
        EqBand(type: EqBandType.peaking, freqHz: 300, q: 1.2, gainDb: -3.0),
        EqBand(type: EqBandType.lowShelf, freqHz: 90, gainDb: -6.0),
      ],
    );
  }

  @override
  PcmChunk process(PcmChunk chunk) {
    if (bands.isEmpty) return chunk;
    final channels = PcmFloat.deinterleave(chunk.pcm, format);
    for (var c = 0; c < channels.length; c++) {
      final samples = channels[c];
      for (var b = 0; b < _biquads.length; b++) {
        final bq = _biquads[b];
        final st = _states[b][c];
        for (var i = 0; i < samples.length; i++) {
          samples[i] = bq.process(samples[i], st);
        }
      }
    }
    final Uint8List out = PcmFloat.interleave(channels, format);
    return chunk.copyWith(pcm: out);
  }

  @override
  void dispose() {
    for (final perBand in _states) {
      for (final st in perBand) {
        st.reset();
      }
    }
  }
}
