import 'dart:typed_data';

import '../../core/contracts/audio_format.dart';
import '../../core/pipeline/audio_chunk.dart';
import '../dsp/pcm_float.dart';

/// A **beat grid** — the Phase 5 control-plane message that tells every client
/// where the music's beats fall, so lights, haptics, visualizers and the DJ
/// crossfader can all lock to the same pulse (the plan's `BeatGrid` =
/// `downbeat_ts_us, bpm, phase`).
///
/// The grid is an infinite ruler defined by three numbers:
///  * [downbeatTsUs] — the host-clock microsecond timestamp of one known
///    downbeat (beat 0 of a bar);
///  * [bpm] — tempo in beats per minute;
///  * [beatsPerBar] — bar length (4 for most dance music).
///
/// From those, the position of every other beat is pure arithmetic, so a client
/// that knows the grid (and is clock-synced via Phase 2 PTP) can predict beats
/// into the future and schedule a light flash *exactly* on the beat rather than
/// reacting late to audio.
class BeatGrid {
  /// Host-clock microseconds of a known downbeat (beat 0 of a bar).
  final int downbeatTsUs;

  /// Tempo in beats per minute (> 0).
  final double bpm;

  /// Beats per bar; the downbeat recurs every [beatsPerBar] beats.
  final int beatsPerBar;

  const BeatGrid({
    required this.downbeatTsUs,
    required this.bpm,
    this.beatsPerBar = 4,
  })  : assert(bpm > 0, 'bpm must be positive'),
        assert(beatsPerBar > 0, 'beatsPerBar must be positive');

  /// Microseconds between consecutive beats.
  double get beatPeriodUs => 60000000.0 / bpm;

  /// Microseconds between consecutive downbeats (one bar).
  double get barPeriodUs => beatPeriodUs * beatsPerBar;

  /// The (possibly negative) beat index at [tsUs], where index 0 is
  /// [downbeatTsUs]. Floored, so a timestamp anywhere inside a beat returns that
  /// beat's index.
  int beatIndexAt(int tsUs) {
    final beats = (tsUs - downbeatTsUs) / beatPeriodUs;
    return beats.floor();
  }

  /// True when the beat at [tsUs] is a downbeat (beat 0 of its bar).
  bool isDownbeatAt(int tsUs) => beatIndexAt(tsUs) % beatsPerBar == 0;

  /// Phase within the current beat at [tsUs], in `[0.0, 1.0)` — 0.0 exactly on
  /// the beat, approaching 1.0 just before the next. The plan's `phase`.
  double phaseAt(int tsUs) {
    final rel = (tsUs - downbeatTsUs) % beatPeriodUs;
    final p = rel / beatPeriodUs;
    return p < 0 ? p + 1.0 : p;
  }

  /// Microsecond timestamp of beat number [index].
  int beatTsUs(int index) => downbeatTsUs + (index * beatPeriodUs).round();

  /// Timestamp of the first beat at or after [tsUs] (the next beat to schedule).
  int nextBeatUs(int tsUs) {
    final idx = beatIndexAt(tsUs);
    final onBeat = beatTsUs(idx);
    return onBeat >= tsUs ? onBeat : beatTsUs(idx + 1);
  }

  /// Re-anchor the grid onto a fresh downbeat timestamp (e.g. after a tempo
  /// re-detect) without changing tempo/metre.
  BeatGrid reanchor(int downbeatTsUs) => BeatGrid(
        downbeatTsUs: downbeatTsUs,
        bpm: bpm,
        beatsPerBar: beatsPerBar,
      );

  Map<String, dynamic> toJson() => {
        'downbeatTsUs': downbeatTsUs,
        'bpm': bpm,
        'beatsPerBar': beatsPerBar,
      };

  factory BeatGrid.fromJson(Map<String, dynamic> json) => BeatGrid(
        downbeatTsUs: (json['downbeatTsUs'] as num).toInt(),
        bpm: (json['bpm'] as num).toDouble(),
        beatsPerBar: (json['beatsPerBar'] as num?)?.toInt() ?? 4,
      );

  @override
  bool operator ==(Object other) =>
      other is BeatGrid &&
      other.downbeatTsUs == downbeatTsUs &&
      other.bpm == bpm &&
      other.beatsPerBar == beatsPerBar;

  @override
  int get hashCode => Object.hash(downbeatTsUs, bpm, beatsPerBar);

  @override
  String toString() =>
      'BeatGrid(downbeat=${downbeatTsUs}us, ${bpm.toStringAsFixed(1)}bpm, '
      '$beatsPerBar/bar)';
}

/// Result of [BeatDetector.estimate]: the detected tempo plus the onset the
/// detector judged the strongest (used to anchor the grid's downbeat).
class BeatEstimate {
  final double bpm;

  /// Confidence in `[0.0, 1.0]` — the normalized strength of the winning
  /// autocorrelation lag. Low confidence ⇒ treat the tempo as a guess.
  final double confidence;

  /// Hop index of the strongest detected onset (anchor for the downbeat).
  final int anchorHop;

  const BeatEstimate({
    required this.bpm,
    required this.confidence,
    required this.anchorHop,
  });

  @override
  String toString() => 'BeatEstimate(${bpm.toStringAsFixed(1)}bpm, '
      'conf=${confidence.toStringAsFixed(2)}, anchorHop=$anchorHop)';
}

/// **Pure-Dart beat/tempo detector** — the testable core of Phase 5's beat
/// tracking. It builds an onset-strength envelope from the PCM energy flux, then
/// estimates tempo by autocorrelating that envelope over the lags corresponding
/// to a musical BPM range, and anchors the downbeat to the strongest onset.
///
/// `aubio` (FFI onset detection) is the optional accuracy upgrade and is
/// **deferred** behind the same load-probe discipline as Opus/RNNoise — see
/// [AubioBeatTracker]. This pure detector needs no native binary, so CI exercises
/// the whole beat-grid path; it is deterministic (no clocks/random), so a
/// synthetic click track yields the same BPM every run.
class BeatDetector {
  final AudioFormat format;

  /// Analysis hop in samples-per-channel (energy is measured per hop). 10 ms at
  /// the format's sample rate by default.
  final int hopSamples;

  final double minBpm;
  final double maxBpm;

  final List<double> _flux = [];
  final List<double> _monoAccum = [];
  double _prevEnergy = 0.0;

  BeatDetector({
    this.format = AudioFormat.cdStereo,
    int? hopSamples,
    this.minBpm = 60,
    this.maxBpm = 180,
  })  : assert(minBpm > 0 && maxBpm > minBpm, 'invalid BPM range'),
        hopSamples = hopSamples ?? (format.sampleRate ~/ 100);

  /// The onset-strength envelope built so far (one value per analyzed hop).
  List<double> get envelope => List.unmodifiable(_flux);

  /// Milliseconds of audio one hop represents.
  double get hopMs => 1000.0 * hopSamples / format.sampleRate;

  /// Feed a PCM chunk; updates the onset envelope.
  void process(PcmChunk chunk) {
    final channels = PcmFloat.deinterleave(chunk.pcm, chunk.format);
    if (channels.isEmpty) return;
    final frames = channels[0].length;
    for (var f = 0; f < frames; f++) {
      var sum = 0.0;
      for (final ch in channels) {
        sum += f < ch.length ? ch[f] : 0.0;
      }
      _monoAccum.add(sum / channels.length);
    }
    while (_monoAccum.length >= hopSamples) {
      var energy = 0.0;
      for (var i = 0; i < hopSamples; i++) {
        final s = _monoAccum[i];
        energy += s * s;
      }
      energy = energy / hopSamples;
      // Spectral/energy flux: rectified rise in energy marks an onset.
      final flux = energy - _prevEnergy;
      _flux.add(flux > 0 ? flux : 0.0);
      _prevEnergy = energy;
      _monoAccum.removeRange(0, hopSamples);
    }
  }

  /// Estimate tempo from the accumulated envelope by autocorrelation over the
  /// lag range implied by [minBpm]/[maxBpm].
  BeatEstimate estimate() {
    final n = _flux.length;
    if (n < 4) {
      return const BeatEstimate(bpm: 0, confidence: 0, anchorHop: 0);
    }
    // Lag (in hops) for a given BPM: hops_per_beat = 60 / bpm / hopSeconds.
    final hopSeconds = hopSamples / format.sampleRate;
    final minLag = (60.0 / maxBpm / hopSeconds).floor().clamp(1, n - 1);
    final maxLag = (60.0 / minBpm / hopSeconds).ceil().clamp(1, n - 1);

    // Zero-mean the envelope so a DC pedestal doesn't dominate autocorrelation.
    var mean = 0.0;
    for (final v in _flux) {
      mean += v;
    }
    mean /= n;
    final centered = [for (final v in _flux) v - mean];

    var energy0 = 0.0;
    for (final v in centered) {
      energy0 += v * v;
    }
    if (energy0 <= 0) {
      return const BeatEstimate(bpm: 0, confidence: 0, anchorHop: 0);
    }

    var bestLag = minLag;
    var bestScore = double.negativeInfinity;
    for (var lag = minLag; lag <= maxLag; lag++) {
      var acc = 0.0;
      for (var i = lag; i < n; i++) {
        acc += centered[i] * centered[i - lag];
      }
      if (acc > bestScore) {
        bestScore = acc;
        bestLag = lag;
      }
    }

    final bpm = 60.0 / (bestLag * hopSeconds);
    final confidence = (bestScore / energy0).clamp(0.0, 1.0);
    return BeatEstimate(
      bpm: bpm,
      confidence: confidence,
      anchorHop: _strongestOnsetHop(),
    );
  }

  int _strongestOnsetHop() {
    var bestHop = 0;
    var bestVal = double.negativeInfinity;
    for (var i = 0; i < _flux.length; i++) {
      if (_flux[i] > bestVal) {
        bestVal = _flux[i];
        bestHop = i;
      }
    }
    return bestHop;
  }

  /// Build a [BeatGrid] from the current estimate. [streamStartTsUs] is the host
  /// timestamp of the first sample fed to the detector; the anchor onset's hop
  /// is converted to an absolute downbeat timestamp.
  BeatGrid? toBeatGrid({
    required int streamStartTsUs,
    int beatsPerBar = 4,
  }) {
    final est = estimate();
    if (est.bpm <= 0) return null;
    final anchorUs = streamStartTsUs +
        (est.anchorHop * hopSamples * 1000000 ~/ format.sampleRate);
    return BeatGrid(
      downbeatTsUs: anchorUs,
      bpm: est.bpm,
      beatsPerBar: beatsPerBar,
    );
  }

  /// Discard the accumulated envelope (e.g. on a track change).
  void reset() {
    _flux.clear();
    _monoAccum.clear();
    _prevEnergy = 0.0;
  }
}

/// **[needs-hardware/native]** capability-probe scaffold for `aubio`-based beat
/// tracking. aubio is a C library (onset/tempo detection) wrapped via FFI; no
/// binary is vendored in this sandbox, so [isAvailable] is false and the
/// pure-Dart [BeatDetector] is the live path. When an aubio `.so/.dll` is
/// vendored, this is where the higher-accuracy tracker plugs in — same deferral
/// pattern as Opus/RNNoise/soundtouch.
class AubioBeatTracker {
  static bool get isAvailable => false;

  /// Placeholder so the interface is exercised by tests without a binary.
  static BeatEstimate? track(Uint8List pcm, AudioFormat format) => null;
}
