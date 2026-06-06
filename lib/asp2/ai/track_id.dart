import 'dart:math' as math;

import '../../core/pipeline/audio_chunk.dart';
import '../dsp/pcm_float.dart';

/// Acoustic-fingerprint metadata for a recognized track (the shape an
/// AcoustID/MusicBrainz lookup fills in).
class TrackMatch {
  final String title;
  final String artist;
  final double score; // 0..1 match confidence

  const TrackMatch({
    required this.title,
    required this.artist,
    this.score = 0.0,
  });

  @override
  String toString() =>
      'TrackMatch("$title" — $artist, ${(score * 100).round()}%)';
}

/// **Chromaprint-style acoustic fingerprint** (pure Dart). It reduces audio to a
/// **chroma** representation — the 12 pitch classes (C, C#, … B), folding every
/// octave together — using a bank of [Goertzel] detectors (one per note across a
/// few octaves), then packs each frame's above-average bins into a 12-bit
/// sub-fingerprint. The same audio always yields the same fingerprint, and
/// perceptually similar audio yields similar bit patterns — the local half of
/// track ID. Matching a fingerprint to a song needs the online AcoustID
/// database ([AcoustIdLookup], [needs-service]).
class ChromaFingerprint {
  ChromaFingerprint._();

  /// MIDI note range to analyze (C3..B5 = three octaves of musical energy).
  static const int _lowMidi = 48;
  static const int _highMidi = 84; // exclusive

  /// Frequency of a MIDI note (A4 = 69 = 440 Hz).
  static double _midiToHz(int n) => 440.0 * math.pow(2, (n - 69) / 12.0);

  /// Goertzel magnitude² of [samples] at frequency [freqHz].
  static double _goertzel(
      List<double> samples, double freqHz, double sampleRate) {
    final n = samples.length;
    if (n == 0) return 0.0;
    final k = 2 * math.cos(2 * math.pi * freqHz / sampleRate);
    var s1 = 0.0, s2 = 0.0;
    for (var i = 0; i < n; i++) {
      final s = samples[i] + k * s1 - s2;
      s2 = s1;
      s1 = s;
    }
    return s1 * s1 + s2 * s2 - k * s1 * s2;
  }

  /// 12-bin chroma vector for [chunk] (index 0 = C … 11 = B), L∞-normalized to a
  /// peak of 1.0 so it's level-independent.
  static List<double> chromaVector(PcmChunk chunk) {
    final channels = PcmFloat.deinterleave(chunk.pcm, chunk.format);
    final chroma = List<double>.filled(12, 0.0);
    if (channels.isEmpty || channels[0].isEmpty) return chroma;

    // Collapse to mono once.
    final frames = channels[0].length;
    final mono = List<double>.filled(frames, 0.0);
    for (var f = 0; f < frames; f++) {
      var sum = 0.0;
      for (final ch in channels) {
        sum += f < ch.length ? ch[f] : 0.0;
      }
      mono[f] = sum / channels.length;
    }

    final sr = chunk.format.sampleRate.toDouble();
    for (var n = _lowMidi; n < _highMidi; n++) {
      final mag = _goertzel(mono, _midiToHz(n), sr);
      chroma[n % 12] += math.sqrt(mag);
    }

    // Normalize to peak 1.0.
    final peak = chroma.reduce(math.max);
    if (peak > 0) {
      for (var i = 0; i < 12; i++) {
        chroma[i] /= peak;
      }
    }
    return chroma;
  }

  /// Pack one chunk's chroma into a 12-bit sub-fingerprint: bit `p` is set when
  /// pitch class `p` is above the mean energy of the frame. Deterministic.
  static int subFingerprint(PcmChunk chunk) {
    final chroma = chromaVector(chunk);
    final mean = chroma.reduce((a, b) => a + b) / 12.0;
    var bits = 0;
    for (var p = 0; p < 12; p++) {
      if (chroma[p] > mean) bits |= 1 << p;
    }
    return bits;
  }

  /// Full fingerprint of a sequence of (already framed) chunks.
  static List<int> fingerprint(List<PcmChunk> frames) =>
      [for (final c in frames) subFingerprint(c)];

  /// Hamming similarity in `[0,1]` between two fingerprints (1 = identical).
  /// Compares the overlapping prefix; differing lengths penalize the score.
  static double similarity(List<int> a, List<int> b) {
    if (a.isEmpty || b.isEmpty) return 0.0;
    final n = math.min(a.length, b.length);
    var matchingBits = 0;
    for (var i = 0; i < n; i++) {
      final agree = ~(a[i] ^ b[i]) & 0xFFF; // 12 bits
      matchingBits += _popcount12(agree);
    }
    final maxBits = math.max(a.length, b.length) * 12;
    return matchingBits / maxBits;
  }

  static int _popcount12(int v) {
    var x = v & 0xFFF;
    var c = 0;
    while (x != 0) {
      c += x & 1;
      x >>= 1;
    }
    return c;
  }
}

/// **[needs-service]** AcoustID/MusicBrainz online lookup scaffold. The local
/// fingerprint ([ChromaFingerprint]) is computed on device; resolving it to a
/// title/artist needs the AcoustID web API (an API key + network), so it is
/// deferred. Returns no match until a backend is wired.
class AcoustIdLookup {
  final String apiKey;

  const AcoustIdLookup({this.apiKey = ''});

  static bool get isAvailable => false;

  String get unavailableReason =>
      'No AcoustID API key/network on this build; fingerprinting works offline '
      'but track resolution is deferred to the device path.';

  /// Resolve [fingerprint] to a [TrackMatch], or null when unavailable/no match.
  Future<TrackMatch?> identify(List<int> fingerprint) async => null;
}
