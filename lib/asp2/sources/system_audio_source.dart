import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter/services.dart';

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

/// The real platform-channel backend. Binds the Dart side of the loopback
/// bridge to the same channels the legacy AudioService already declares
/// (`com.audiosplitter.app/system_audio` event stream +
/// `com.audiosplitter.app/system_audio_control` control), so the ONE remaining
/// piece of work is the native handler behind those channels
/// (WASAPI loopback on Windows, `AudioPlaybackCapture` via `MediaProjection` on
/// Android 10+).
///
/// [isSupported] is a real per-OS capability gate (Windows + Android today; the
/// native handler is what makes it actually stream). Where the native side is
/// absent — every non-Windows/Android platform, and unit tests — the channel is
/// never invoked and callers degrade to the microphone path with no crash,
/// exactly like `OpusCodec.tryCreate()` degrades to PCM16.
class PlatformLoopbackBackend implements SystemAudioBackend {
  const PlatformLoopbackBackend();

  /// Event stream of raw PCM16 loopback frames from native.
  static const EventChannel _events =
      EventChannel('com.audiosplitter.app/system_audio');

  /// Start/stop + capability control on the native side.
  static const MethodChannel _control =
      MethodChannel('com.audiosplitter.app/system_audio_control');

  @override
  AudioFormat get format => AudioFormat.cdStereo;

  @override
  bool get isSupported {
    // Loopback capture is a native feature; only Windows and Android have a
    // handler planned. Other platforms (and the pure-Dart test host) report
    // false so the source degrades to mic capture.
    try {
      return Platform.isWindows || Platform.isAndroid;
    } catch (_) {
      // Platform is unavailable on web / in some test hosts — treat as
      // unsupported rather than throwing.
      return false;
    }
  }

  @override
  Future<Stream<Uint8List>> start() async {
    // Ask native to begin capture; a MissingPluginException here means the
    // native handler isn't installed on this build — surface it so the source's
    // start() returns false and the app falls back to the mic.
    await _control.invokeMethod<void>('start');
    return _events
        .receiveBroadcastStream()
        .map((event) => event is Uint8List ? event : Uint8List(0));
  }

  @override
  Future<void> stop() async {
    try {
      await _control.invokeMethod<void>('stop');
    } catch (_) {
      // Native side already stopped, absent, or the binding isn't available
      // (unit-test host): stopping is best-effort, so swallow everything.
    }
  }
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
