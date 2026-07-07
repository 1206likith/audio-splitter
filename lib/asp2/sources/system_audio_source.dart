import 'dart:async';
import 'dart:typed_data';

import '../../core/contracts/audio_format.dart';
import '../../core/contracts/i_audio_source.dart';
import '../../core/pipeline/audio_chunk.dart';

/// A backend that pulls raw PCM16 frames from the OS's system-audio /
/// loopback capture API (WASAPI loopback on Windows, `MediaProjection` +
/// `AudioPlaybackCapture` on Android 10+, ScreenCaptureKit / a Core Audio tap
/// on macOS 13+). This is the ONE seam that touches native code.
///
/// It is an interface — not a concrete platform channel — so [SystemAudioSource]
/// can be driven headlessly in tests by a fake backend, exactly the way
/// `OpusCodec.tryCreate()` isolates libopus. The real platform-channel
/// implementation (`PlatformLoopbackBackend`, below) is a documented stub until
/// the native side is wired per-OS; `SystemAudioSource.tryCreate()` returns
/// null on platforms where loopback is unavailable so callers fall back to the
/// microphone path with no crash.
abstract class SystemAudioBackend {
  /// The PCM format this backend will emit. Loopback is typically 48 kHz
  /// stereo 16-bit (the shared-mixer format most OSes expose).
  AudioFormat get format;

  /// Whether the current platform/build actually supports loopback capture.
  bool get isSupported;

  /// Begin native capture. Emits interleaved little-endian PCM16 buffers on the
  /// returned stream, one per native callback. Throws or completes-with-error
  /// if capture cannot start (permission denied, device busy).
  Future<Stream<Uint8List>> start();

  /// Stop native capture and release the OS handle.
  Future<void> stop();
}

/// The real platform-channel backend. **Stub for now** — the Dart↔native bridge
/// (a `MethodChannel`/`EventChannel` pair per platform) is not yet wired, so
/// [isSupported] is false and [start] throws. When the native side lands, this
/// class flips [isSupported] to a real per-OS capability check and streams
/// frames off the platform's audio callback. Kept behind the [SystemAudioBackend]
/// interface so nothing above it changes when that happens.
class PlatformLoopbackBackend implements SystemAudioBackend {
  const PlatformLoopbackBackend();

  @override
  AudioFormat get format => AudioFormat.cdStereo;

  @override
  bool get isSupported => false; // TODO(native): WASAPI/MediaProjection/CoreAudio

  @override
  Future<Stream<Uint8List>> start() async {
    throw UnsupportedError(
      'System-audio loopback capture is not yet wired to the native platform '
      'channel. See third_party/README.md and lib/asp2/sources/'
      'system_audio_source.dart for the SystemAudioBackend seam to implement.',
    );
  }

  @override
  Future<void> stop() async {}
}

/// [IAudioSource] that streams the device's own system/loopback audio — the
/// #1 capability a best-in-class audio splitter needs (send the clean digital
/// stream the device is playing, not a re-recording of the room through a mic).
///
/// The source logic here — start/stop lifecycle, re-timestamping native frames
/// onto the host clock in microseconds, chunk fan-out, graceful failure — is
/// pure Dart and fully unit-tested via an injected [SystemAudioBackend]. The
/// only untestable-in-CI part is the native capture itself, which lives behind
/// the backend seam.
class SystemAudioSource implements IAudioSource {
  SystemAudioSource(this._backend, {this.id = 'system-audio'});

  /// Construct with the real platform backend, or return null when loopback is
  /// unsupported on this platform/build — mirroring `OpusCodec.tryCreate()` so
  /// callers degrade to the microphone source instead of crashing.
  static SystemAudioSource? tryCreate({SystemAudioBackend? backend}) {
    final b = backend ?? const PlatformLoopbackBackend();
    if (!b.isSupported) return null;
    return SystemAudioSource(b);
  }

  final SystemAudioBackend _backend;

  @override
  final String id;

  final StreamController<PcmChunk> _chunks =
      StreamController<PcmChunk>.broadcast();
  StreamSubscription<Uint8List>? _sub;
  bool _active = false;
  int _tsUs = 0;

  @override
  AudioFormat get format => _backend.format;

  @override
  Stream<PcmChunk> get chunks => _chunks.stream;

  @override
  bool get isActive => _active;

  @override
  Future<bool> start() async {
    if (_active) return false;
    if (!_backend.isSupported) return false;
    final Stream<Uint8List> native;
    try {
      native = await _backend.start();
    } catch (_) {
      // Permission denied / device busy / unsupported at runtime: fail closed,
      // exactly like the IAudioSource contract documents (start() -> false).
      return false;
    }
    _active = true;
    _tsUs = 0;
    _sub = native.listen(
      _onNativeFrame,
      onError: (_) {
        // A native capture error ends the stream; stop cleanly.
        unawaited(stop());
      },
      onDone: () {
        _active = false;
      },
    );
    return true;
  }

  void _onNativeFrame(Uint8List pcm) {
    if (!_active || _chunks.isClosed || pcm.isEmpty) return;
    final chunk = PcmChunk(
      pcm: pcm,
      presentationTsUs: _tsUs,
      format: _backend.format,
    );
    _chunks.add(chunk);
    // Advance the host-clock timestamp by this frame's real duration so
    // downstream framing/sync sees a monotonic, gap-free pts.
    _tsUs += chunk.durationUs;
  }

  @override
  Future<void> stop() async {
    _active = false;
    await _sub?.cancel();
    _sub = null;
    await _backend.stop();
  }

  /// Release the chunk stream. Call when the source is no longer needed.
  Future<void> dispose() async {
    await stop();
    if (!_chunks.isClosed) await _chunks.close();
  }
}
