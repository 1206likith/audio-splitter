import '../../core/contracts/audio_format.dart';
import '../../core/contracts/i_audio_sink.dart';
import '../../core/pipeline/audio_chunk.dart';

/// BtA2dpSink — Phase 4 of the v2 plan: route a zone's mixed PCM to a **real**
/// A2DP Bluetooth audio device (speaker/earbuds).
///
/// This replaces v1's Bluetooth, which only *scanned and listed* devices and
/// never played a sample (see `BluetoothService`). Real A2DP output is
/// **[needs-hardware]**: it needs a paired BT sink and platform audio-routing
/// APIs, neither of which exists in this build/test sandbox. So the sink ships
/// in two modes, mirroring the native-binary deferral discipline of earlier
/// phases:
///
///   * **simulate** (default in tests) — a fully working in-memory sink that
///     accepts the [IAudioSink] contract and records what it was asked to play
///     (chunk count, byte total, last timestamp). This lets the router/zone
///     pipeline be tested end-to-end into a "BT speaker" without hardware.
///   * **real** — deferred: [open] returns `false` with [unavailableReason] set,
///     because no platform A2DP route is wired here. On a device build, replace
///     [_openReal]/[_writeReal] with the platform audio-route calls; the rest of
///     the pipeline is unchanged.
///
/// The live `BluetoothService` (scan/list, wired into the host/home/client
/// screens) is intentionally **left in place** for now: rewriting it from
/// list-only to routing and deleting its dead paths is device-path adoption,
/// gated on a real BT sink, and is tracked as deferred — same call the prior
/// phases made for live-path wiring.
class BtA2dpSink implements IAudioSink {
  @override
  final String id;

  /// The paired device's address/identifier this sink targets.
  final String deviceId;

  /// When true, behave as a working in-memory sink (testable). When false, the
  /// real A2DP route is required and is currently deferred.
  final bool simulate;

  bool _open = false;
  AudioFormat? _format;
  String? _unavailableReason;

  // Simulator bookkeeping — lets tests assert audio actually reached the sink.
  int _chunksWritten = 0;
  int _bytesWritten = 0;
  int _lastTsUs = -1;

  BtA2dpSink({
    required this.deviceId,
    String? id,
    this.simulate = true,
  }) : id = id ?? 'bt-a2dp:$deviceId';

  bool get isOpen => _open;
  AudioFormat? get format => _format;

  /// Why the real sink could not open (null until a failed real [open]).
  String? get unavailableReason => _unavailableReason;

  int get chunksWritten => _chunksWritten;
  int get bytesWritten => _bytesWritten;
  int get lastTsUs => _lastTsUs;

  @override
  Future<bool> open(AudioFormat format) async {
    _format = format;
    if (simulate) {
      _open = true;
      return true;
    }
    return _openReal(format);
  }

  // [needs-hardware] Real A2DP open is deferred. On a device build, request the
  // BT audio route to [deviceId] for [format] here and return its success.
  Future<bool> _openReal(AudioFormat format) async {
    _open = false;
    _unavailableReason =
        'A2DP output to "$deviceId" is not available in this build: no '
        'platform Bluetooth audio route is wired (needs paired hardware + '
        'device-side routing). Implement BtA2dpSink._openReal on the device '
        'path.';
    return false;
  }

  @override
  void write(PcmChunk chunk) {
    if (!_open) return; // tolerate writes before open / after a failed open
    if (simulate) {
      _chunksWritten++;
      _bytesWritten += chunk.pcm.length;
      _lastTsUs = chunk.presentationTsUs;
      return;
    }
    _writeReal(chunk);
  }

  // [needs-hardware] Real A2DP write is deferred — see [_openReal].
  void _writeReal(PcmChunk chunk) {}

  @override
  Future<void> close() async {
    _open = false;
  }
}
