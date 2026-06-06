import '../pipeline/audio_chunk.dart';

/// A DSP effect node in the source-router DAG: denoise, AGC, AEC, parametric
/// EQ, compressor, limiter, etc.
///
/// Effects are pure transforms over [PcmChunk]s. In Phase 0 the only concrete
/// effect is the identity pass-through ([PassthroughEffect]); real DSP arrives
/// in Phase 2 via FFI.
abstract class IEffect {
  /// Stable identifier (used as a node id in the DAG).
  String get id;

  /// Transform a chunk. Must return a chunk in the same [PcmChunk.format]
  /// unless the effect explicitly documents a format change.
  PcmChunk process(PcmChunk chunk);

  /// Release any resources (native handles, buffers). Safe to call repeatedly.
  void dispose() {}
}

/// No-op effect: returns the chunk unchanged. Used as a DAG placeholder until
/// real DSP nodes land in Phase 2.
class PassthroughEffect implements IEffect {
  @override
  final String id;

  const PassthroughEffect([this.id = 'passthrough']);

  @override
  PcmChunk process(PcmChunk chunk) => chunk;

  @override
  void dispose() {}
}
