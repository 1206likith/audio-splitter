import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'plugin_sdk.dart';

/// Reference plugin demonstrating the Plugin SDK v1: it provides one source
/// ([ToneSource], a deterministic sine generator) and one effect ([GainEffect],
/// a linear gain stage). It builds against the public SDK surface only —
/// nothing engine-internal — so it doubles as the template third-party authors
/// copy. Used by the Phase 7 gate to prove a plugin's nodes drop into the
/// pipeline and process audio.
class SampleTonePlugin extends AudioPlugin {
  const SampleTonePlugin();

  @override
  PluginManifest get manifest => const PluginManifest(
        id: 'com.audiosplitter.sample.tone',
        name: 'Sample Tone & Gain',
        version: '1.0.0',
        author: 'Audio Splitter',
        capabilities: {PluginCapability.source, PluginCapability.effect},
      );

  @override
  IAudioSource createSource(String nodeId, Map<String, dynamic> params) =>
      ToneSource(
        id: nodeId,
        frequencyHz: (params['frequencyHz'] as num?)?.toDouble() ?? 440.0,
        amplitude: (params['amplitude'] as num?)?.toDouble() ?? 0.5,
        chunkCount: (params['chunks'] as int?) ?? 4,
        framesPerChunk: (params['framesPerChunk'] as int?) ?? 480,
      );

  @override
  IEffect createEffect(String nodeId, Map<String, dynamic> params) =>
      GainEffect(
        id: nodeId,
        gainDb: (params['gainDb'] as num?)?.toDouble() ?? 0.0,
      );
}

/// A deterministic finite sine source. On [start] it eagerly generates
/// [chunkCount] chunks of [framesPerChunk] frames each (phase-continuous across
/// chunk boundaries) and then completes — perfect for tests and demos, no
/// platform audio API required.
class ToneSource implements IAudioSource {
  @override
  final String id;
  @override
  final AudioFormat format;

  final double frequencyHz;
  final double amplitude;
  final int chunkCount;
  final int framesPerChunk;
  final int startTsUs;

  final StreamController<PcmChunk> _controller =
      StreamController<PcmChunk>.broadcast();
  bool _active = false;

  ToneSource({
    required this.id,
    this.frequencyHz = 440.0,
    this.amplitude = 0.5,
    this.chunkCount = 4,
    this.framesPerChunk = 480,
    this.format = AudioFormat.voiceMono,
    this.startTsUs = 0,
  });

  @override
  Stream<PcmChunk> get chunks => _controller.stream;

  @override
  bool get isActive => _active;

  @override
  Future<bool> start() async {
    if (_active) return true;
    _active = true;
    var sample = 0; // global sample index for phase continuity
    final usPerFrame = 1000000 ~/ format.sampleRate;
    for (var c = 0; c < chunkCount; c++) {
      final pcm = Uint8List(framesPerChunk * format.frameBytes);
      final bd = ByteData.view(pcm.buffer);
      for (var f = 0; f < framesPerChunk; f++) {
        final v = (amplitude *
                math.sin(
                    2 * math.pi * frequencyHz * sample / format.sampleRate) *
                32000)
            .round();
        for (var ch = 0; ch < format.channels; ch++) {
          bd.setInt16((f * format.channels + ch) * 2, v, Endian.little);
        }
        sample++;
      }
      _controller.add(PcmChunk(
        pcm: pcm,
        presentationTsUs: startTsUs + c * framesPerChunk * usPerFrame,
        format: format,
      ));
    }
    return true;
  }

  @override
  Future<void> stop() async {
    _active = false;
    await _controller.close();
  }
}

/// A linear gain effect: scales every sample by `10^(gainDb/20)`, clamped to the
/// 16-bit range. Stateless pure transform.
class GainEffect implements IEffect {
  @override
  final String id;
  final double gainDb;
  final double _gainLin;

  GainEffect({required this.id, this.gainDb = 0.0})
      : _gainLin = _dbToLin(gainDb);

  static double _dbToLin(double db) => math.pow(10.0, db / 20.0).toDouble();

  @override
  PcmChunk process(PcmChunk chunk) {
    if (_gainLin == 1.0) return chunk;
    final out = Uint8List(chunk.pcm.length);
    final src = ByteData.view(
        chunk.pcm.buffer, chunk.pcm.offsetInBytes, chunk.pcm.length);
    final dst = ByteData.view(out.buffer);
    final n = chunk.pcm.length ~/ 2;
    for (var i = 0; i < n; i++) {
      final scaled = (src.getInt16(i * 2, Endian.little) * _gainLin).round();
      dst.setInt16(i * 2, scaled.clamp(-32768, 32767), Endian.little);
    }
    return chunk.copyWith(pcm: out);
  }

  @override
  void dispose() {}
}
