import '../../core/contracts/audio_format.dart';
import '../../core/contracts/i_audio_sink.dart';
import '../../core/pipeline/audio_chunk.dart';

/// LeAudioBroadcastSink — the Auracast (Bluetooth LE Audio broadcast) output.
///
/// This is the v2 plan's genuine differentiator over classic A2DP: A2DP is a
/// point-to-point link to ONE paired device, whereas an LE Audio *broadcast*
/// (Auracast) transmits one Broadcast Isochronous Stream that ANY number of
/// nearby receivers can subscribe to — the Bluetooth-native way to do exactly
/// what Audio Splitter does at the app layer (one source, many listeners).
///
/// Mirrors [BtA2dpSink]'s design so the router/zone layer treats it as just
/// another [IAudioSink]:
///   - In [simulate] mode (the default and the only mode tests run) it accepts
///     the contract and records what it was asked to broadcast (chunk count,
///     byte total, last timestamp), so the pipeline is fully exercisable
///     headlessly.
///   - The real broadcast path ([_openReal]/[_writeReal]) is deferred behind a
///     `[needs-hardware]` seam: it needs an LE-Audio-capable adapter, the
///     platform's broadcast-source API (Android 13+ `BluetoothLeBroadcast`, or
///     a host stack that exposes BIS), and encodes to LC3 (codec_id 2, reserved
///     in the ASP-2 frame header). Until that lands, [open] with `simulate:false`
///     returns false with a clear [unavailableReason] and the pipeline routes
///     elsewhere — no crash.
class LeAudioBroadcastSink implements IAudioSink {
  LeAudioBroadcastSink({
    String? id,
    this.broadcastName = 'AudioSplitter',
    this.simulate = true,
  }) : id = id ?? 'le-audio-broadcast';

  @override
  final String id;

  /// The advertised Auracast broadcast name receivers see when they scan.
  final String broadcastName;

  /// When true, accept and account for chunks without a real BIS (test/dev).
  final bool simulate;

  bool _open = false;
  AudioFormat? _format;
  String? _unavailableReason;

  int _chunksBroadcast = 0;
  int _bytesBroadcast = 0;
  int _lastTsUs = 0;

  bool get isOpen => _open;
  AudioFormat? get format => _format;

  /// Why the real broadcast route is unavailable (set after a failed non-sim
  /// open); null in simulate mode or before an attempt.
  String? get unavailableReason => _unavailableReason;

  int get chunksBroadcast => _chunksBroadcast;
  int get bytesBroadcast => _bytesBroadcast;
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

  // [needs-hardware] Real Auracast open is deferred. On a device build, create
  // an LE Audio broadcast source named [broadcastName], configure the BIS for
  // [format] (LC3), start advertising, and return whether it started.
  Future<bool> _openReal(AudioFormat format) async {
    _open = false;
    _unavailableReason =
        'LE Audio (Auracast) broadcast "$broadcastName" is not available in '
        'this build: no platform LE-Audio broadcast source is wired (needs an '
        'LE-Audio-capable adapter + Android 13+ BluetoothLeBroadcast or an '
        'equivalent host BIS API + LC3 encode). Implement '
        'LeAudioBroadcastSink._openReal on the device path.';
    return false;
  }

  @override
  void write(PcmChunk chunk) {
    if (!_open) return; // tolerate writes before open / after a failed open
    if (simulate) {
      _chunksBroadcast++;
      _bytesBroadcast += chunk.pcm.length;
      _lastTsUs = chunk.presentationTsUs;
      return;
    }
    _writeReal(chunk);
  }

  // [needs-hardware] Real broadcast write is deferred — see [_openReal]. On a
  // device build, LC3-encode [chunk] and push it into the BIS.
  void _writeReal(PcmChunk chunk) {}

  @override
  Future<void> close() async {
    _open = false;
  }
}
