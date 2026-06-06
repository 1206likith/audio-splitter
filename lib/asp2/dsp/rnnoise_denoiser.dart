import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../../core/contracts/audio_format.dart';
import '../../core/contracts/i_effect.dart';
import '../../core/pipeline/audio_chunk.dart';
import 'native/rnnoise_bindings.dart';
import 'pcm_float.dart';

/// RNNoise neural denoiser ([IEffect]) — the Phase 2 voice-isolation node.
///
/// Like [OpusCodec], it is created through a **load-probe**: [tryCreate] returns
/// `null` when librnnoise is not vendored on this platform, so callers fall back
/// to a [PassthroughEffect] and CI stays green with no binary present. The real
/// binary (and the WebRTC `audio_processing` AGC/AEC/VAD sibling) are documented
/// as deferred in `third_party/README.md`.
///
/// RNNoise is mono / 48 kHz / 480-sample (10 ms) frames. Audio is buffered to
/// that frame boundary across [process] calls, so feeding arbitrary chunk sizes
/// works; a partial trailing frame is held until the next call.
class RnnoiseDenoiser implements IEffect {
  @override
  final String id;

  final RnnoiseBindings _bindings;
  final Pointer<Void> _state;
  final int _frameSize;

  // Reusable native scratch for one frame (allocated once, freed on dispose).
  final Pointer<Float> _inBuf;
  final Pointer<Float> _outBuf;

  // Dart-side accumulator of not-yet-processed mono samples (float, int16-scaled).
  final List<double> _pending = [];

  bool _disposed = false;

  RnnoiseDenoiser._(this._bindings, this._state, this._frameSize, this._inBuf,
      this._outBuf, this.id);

  /// 10 ms @ 48 kHz. Exposed so callers/tests can reason about latency.
  static const int expectedFrameSize = 480;

  /// Candidate library names per platform (next-to-exe on desktop, packaged
  /// `.so` on Android). Order is "most specific first".
  static List<String> _libraryCandidates() {
    if (Platform.isWindows) return ['rnnoise.dll', 'librnnoise.dll'];
    if (Platform.isMacOS) return ['librnnoise.dylib', 'rnnoise.dylib'];
    return ['librnnoise.so', 'rnnoise.so']; // Android / Linux
  }

  /// Attempt to load librnnoise and create a denoiser. Returns `null` (never
  /// throws) when the binary is absent or incompatible — the graceful-degrade
  /// contract every native node in this codebase follows.
  static RnnoiseDenoiser? tryCreate({String id = 'rnnoise'}) {
    DynamicLibrary? lib;
    for (final name in _libraryCandidates()) {
      try {
        lib = DynamicLibrary.open(name);
        break;
      } catch (_) {
        // Try the next candidate.
      }
    }
    if (lib == null) return null;

    try {
      final bindings = RnnoiseBindings(lib);
      final frameSize = bindings.getFrameSize();
      if (frameSize <= 0) return null;
      final state = bindings.create(nullptr);
      if (state == nullptr) return null;
      final inBuf = calloc<Float>(frameSize);
      final outBuf = calloc<Float>(frameSize);
      return RnnoiseDenoiser._(bindings, state, frameSize, inBuf, outBuf, id);
    } catch (_) {
      return null;
    }
  }

  /// True when a usable librnnoise was found on this platform.
  static bool get isAvailable {
    final probe = tryCreate();
    if (probe == null) return false;
    probe.dispose();
    return true;
  }

  @override
  PcmChunk process(PcmChunk chunk) {
    if (_disposed) return chunk;
    // RNNoise is mono; collapse to a single working channel for the model.
    final mono = _toMono(chunk);
    _pending.addAll(mono);

    final processed = <double>[];
    while (_pending.length >= _frameSize) {
      for (var i = 0; i < _frameSize; i++) {
        _inBuf[i] = _pending[i] * PcmFloat.scale; // rnnoise wants int16-scaled
      }
      _pending.removeRange(0, _frameSize);
      _bindings.processFrame(_state, _outBuf, _inBuf);
      for (var i = 0; i < _frameSize; i++) {
        processed.add(_outBuf[i] / PcmFloat.scale);
      }
    }

    if (processed.isEmpty) {
      // Not enough buffered for a full frame yet — emit silence-free passthrough
      // of nothing this call would desync the stream, so emit the input as-is.
      return chunk;
    }

    final outFloat = Float64List.fromList(processed);
    final outChannels = chunk.format.channels == 1
        ? [outFloat]
        : _fanOut(outFloat, chunk.format);
    final Uint8List pcm = PcmFloat.interleave(outChannels, chunk.format);
    return chunk.copyWith(pcm: pcm);
  }

  List<double> _toMono(PcmChunk chunk) {
    final channels = PcmFloat.deinterleave(chunk.pcm, chunk.format);
    if (channels.length == 1) return channels[0].toList();
    final frames = channels[0].length;
    final mono = List<double>.filled(frames, 0);
    for (var f = 0; f < frames; f++) {
      double sum = 0;
      for (final ch in channels) {
        sum += ch[f];
      }
      mono[f] = sum / channels.length;
    }
    return mono;
  }

  List<Float64List> _fanOut(Float64List mono, AudioFormat format) =>
      [for (var c = 0; c < format.channels; c++) mono];

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _bindings.destroy(_state);
    calloc.free(_inBuf);
    calloc.free(_outBuf);
    _pending.clear();
  }
}
