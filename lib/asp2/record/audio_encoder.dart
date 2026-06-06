import 'dart:typed_data';

import '../../core/contracts/audio_format.dart';
import 'flac_writer.dart';
import 'wav_writer.dart';

/// One-shot encoder of an in-memory PCM buffer to a container format. The two
/// **lossless, pure-Dart** encoders ([WavEncoder], [FlacEncoder]) are live and
/// always available; the lossy ones ([Mp3Encoder] = LAME, [OggOpusEncoder] =
/// libopus) need native libraries and ship as load-probed scaffolds
/// (`isAvailable => false`, [needs-FFI]), the same discipline as the Opus codec
/// and RNNoise denoiser elsewhere in ASP-2.
abstract class AudioEncoder {
  /// Short format key (`wav`, `flac`, `mp3`, `opus`).
  String get name;

  /// File extension (no dot).
  String get extension;

  /// Whether this encoder can run on the current build.
  bool get isAvailable;

  /// Encode [pcm] (interleaved 16-bit PCM in [format]) to the container bytes.
  /// Throws [UnsupportedError] when [isAvailable] is false.
  Uint8List encode(AudioFormat format, Uint8List pcm);
}

/// Lossless WAV (RIFF/PCM) — the default recording format.
class WavEncoder implements AudioEncoder {
  const WavEncoder();
  @override
  String get name => 'wav';
  @override
  String get extension => 'wav';
  @override
  bool get isAvailable => true;
  @override
  Uint8List encode(AudioFormat format, Uint8List pcm) =>
      WavWriter.encode(format, pcm);
}

/// Lossless FLAC (verbatim/constant subframes) — pure Dart, always available.
class FlacEncoder implements AudioEncoder {
  const FlacEncoder();
  @override
  String get name => 'flac';
  @override
  String get extension => 'flac';
  @override
  bool get isAvailable => true;
  @override
  Uint8List encode(AudioFormat format, Uint8List pcm) =>
      FlacWriter.encode(format, pcm);
}

/// **[needs-FFI]** MP3 via LAME. Lossy MP3 encoding needs `libmp3lame` vendored
/// per platform; deferred behind the load-probe contract. Reports unavailable
/// so callers fall back to WAV/FLAC.
class Mp3Encoder implements AudioEncoder {
  const Mp3Encoder({this.bitrateKbps = 192});

  /// Target bitrate a device build would request.
  final int bitrateKbps;

  @override
  String get name => 'mp3';
  @override
  String get extension => 'mp3';
  @override
  bool get isAvailable => false;

  String get unavailableReason =>
      'libmp3lame not vendored on this build; record WAV/FLAC (lossless) or '
      'wire the LAME FFI binding on the device path.';

  @override
  Uint8List encode(AudioFormat format, Uint8List pcm) =>
      throw UnsupportedError(unavailableReason);
}

/// **[needs-FFI]** Opus-in-Ogg via libopus + libogg. Reuses the Phase 1 Opus
/// codec FFI once its binary lands; the file muxer (Ogg pages) is deferred with
/// it. Reports unavailable until then.
class OggOpusEncoder implements AudioEncoder {
  const OggOpusEncoder({this.bitrateKbps = 128});

  final int bitrateKbps;

  @override
  String get name => 'opus';
  @override
  String get extension => 'opus';
  @override
  bool get isAvailable => false;

  String get unavailableReason =>
      'libopus/libogg file muxer not vendored on this build; record WAV/FLAC '
      '(lossless) or enable the Opus codec FFI (Phase 1) plus an Ogg muxer.';

  @override
  Uint8List encode(AudioFormat format, Uint8List pcm) =>
      throw UnsupportedError(unavailableReason);
}

/// Looks up encoders by [AudioEncoder.name] and reports which are live on this
/// build. The stem recorder and session bundle resolve formats through here so
/// an unavailable lossy format degrades to a documented fallback rather than a
/// silent skip.
class EncoderRegistry {
  EncoderRegistry._();

  static const List<AudioEncoder> all = [
    WavEncoder(),
    FlacEncoder(),
    Mp3Encoder(),
    OggOpusEncoder(),
  ];

  /// The encoder for [name], or null if unknown.
  static AudioEncoder? forName(String name) {
    for (final e in all) {
      if (e.name == name) return e;
    }
    return null;
  }

  /// Encoders that can actually run on this build (always includes wav, flac).
  static List<AudioEncoder> get available =>
      all.where((e) => e.isAvailable).toList();

  /// Resolve [name]; if its encoder is unavailable, fall back to [fallback]
  /// (default WAV, which is always live).
  static AudioEncoder resolveOrFallback(String name,
      {AudioEncoder fallback = const WavEncoder()}) {
    final e = forName(name);
    if (e != null && e.isAvailable) return e;
    return fallback;
  }
}
