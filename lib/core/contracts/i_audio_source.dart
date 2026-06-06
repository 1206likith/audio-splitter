import '../pipeline/audio_chunk.dart';
import 'audio_format.dart';

/// A capture source in the ASP-2 pipeline: microphone, system audio, a WAV
/// file, an FFmpeg-converted media file, an HLS relay, or a plugin source.
///
/// Sources emit [PcmChunk]s on [chunks]. They sit at the bottom of the layer
/// stack and know nothing about codecs, framing, or transport.
abstract class IAudioSource {
  /// Stable identifier (used as a node id in the source-router DAG).
  String get id;

  /// The PCM format this source produces.
  AudioFormat get format;

  /// PCM chunks produced by this source while active.
  Stream<PcmChunk> get chunks;

  /// Whether the source is currently producing audio.
  bool get isActive;

  /// Begin capture. Returns false if the source could not start (e.g.
  /// unsupported on this platform or permission denied).
  Future<bool> start();

  /// Stop capture and release transient resources. Safe to call when idle.
  Future<void> stop();
}
