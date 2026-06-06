import '../pipeline/audio_chunk.dart';
import 'audio_format.dart';

/// A playback/output sink in the ASP-2 pipeline: the local speaker, an A2DP
/// Bluetooth device, an LE Audio broadcast, a wired DAC, a file recorder, or a
/// captions/haptic/light controller.
///
/// Sinks consume [PcmChunk]s. Like sources, they know nothing about the wire.
abstract class IAudioSink {
  /// Stable identifier (used as a node id in the source-router DAG).
  String get id;

  /// Open the sink for the given PCM format. Returns false on failure.
  Future<bool> open(AudioFormat format);

  /// Render a chunk. Must tolerate being called before [open] resolves by
  /// buffering or dropping, never throwing.
  void write(PcmChunk chunk);

  /// Close the sink and release resources. Safe to call when not open.
  Future<void> close();
}
