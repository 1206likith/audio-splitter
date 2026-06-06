import 'dart:typed_data';

import '../contracts/audio_format.dart';

/// A chunk of PCM audio flowing through the ASP-2 pipeline.
///
/// Note on time units: ASP-2 frames carry a presentation timestamp in
/// **microseconds** (`pts_us`), whereas v1 used milliseconds. [PcmChunk] is the
/// internal currency and stores microseconds; adapters bridging to the legacy
/// wire multiply/divide by 1000.
class PcmChunk {
  /// Raw little-endian PCM samples (interleaved if multi-channel).
  final Uint8List pcm;

  /// Presentation timestamp on the host clock, in microseconds.
  final int presentationTsUs;

  final AudioFormat format;

  const PcmChunk({
    required this.pcm,
    required this.presentationTsUs,
    required this.format,
  });

  /// Convenience: timestamp in milliseconds (v1/legacy bridge).
  int get presentationTsMs => presentationTsUs ~/ 1000;

  /// Approximate duration of this chunk in microseconds, derived from byte
  /// count and format.
  int get durationUs {
    final frames = pcm.length ~/ format.frameBytes;
    if (format.sampleRate == 0) return 0;
    return (frames * 1000000) ~/ format.sampleRate;
  }

  PcmChunk copyWith({
    Uint8List? pcm,
    int? presentationTsUs,
    AudioFormat? format,
  }) {
    return PcmChunk(
      pcm: pcm ?? this.pcm,
      presentationTsUs: presentationTsUs ?? this.presentationTsUs,
      format: format ?? this.format,
    );
  }

  @override
  String toString() =>
      'PcmChunk(${pcm.length}B, ts=${presentationTsUs}us, $format)';
}
