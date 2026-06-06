/// Immutable PCM audio format descriptor used across every layer of the
/// ASP-2 pipeline (sources, effects, codecs, sinks).
///
/// Part of the Phase 0 layered refactor. Lower layers never know about higher
/// layers; this value type is the shared contract for "what shape is this PCM".
class AudioFormat {
  final int sampleRate;
  final int channels;
  final int bitDepth;

  const AudioFormat({
    this.sampleRate = 48000,
    this.channels = 2,
    this.bitDepth = 16,
  });

  /// CD-quality stereo, the v2 default.
  static const AudioFormat cdStereo = AudioFormat();

  /// Mono 48k, typical for microphone / voice paths.
  static const AudioFormat voiceMono =
      AudioFormat(sampleRate: 48000, channels: 1, bitDepth: 16);

  int get bytesPerSample => bitDepth ~/ 8;

  /// Total bytes for one sample frame across all channels.
  int get frameBytes => bytesPerSample * channels;

  /// Number of PCM bytes that represent [ms] milliseconds of audio.
  int bytesPerMs(int ms) => (sampleRate * frameBytes * ms) ~/ 1000;

  /// Samples-per-channel in [ms] milliseconds (e.g. 20ms @48k = 960).
  int samplesPerChannel(int ms) => (sampleRate * ms) ~/ 1000;

  AudioFormat copyWith({int? sampleRate, int? channels, int? bitDepth}) {
    return AudioFormat(
      sampleRate: sampleRate ?? this.sampleRate,
      channels: channels ?? this.channels,
      bitDepth: bitDepth ?? this.bitDepth,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AudioFormat &&
      other.sampleRate == sampleRate &&
      other.channels == channels &&
      other.bitDepth == bitDepth;

  @override
  int get hashCode => Object.hash(sampleRate, channels, bitDepth);

  @override
  String toString() =>
      'AudioFormat(${sampleRate}Hz, ${channels}ch, ${bitDepth}bit)';
}
