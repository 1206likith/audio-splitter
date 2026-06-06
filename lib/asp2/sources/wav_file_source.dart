import 'dart:async';
import 'dart:typed_data';

import '../../core/contracts/audio_format.dart';
import '../../core/contracts/i_audio_source.dart';
import '../../core/pipeline/audio_chunk.dart';

/// Parsed PCM16 WAV payload — the pure, testable core of v1's
/// `AudioService._startWavFileStreaming`.
///
/// Reproduces v1's header handling byte-for-byte: requires a `RIFF` magic, only
/// accepts 16-bit PCM, reads channels/sample-rate from the canonical fmt offsets
/// and locates the `data` chunk by scanning for its tag (falling back to offset
/// 44). This is the single source of truth both [WavFileSource] and the
/// AudioService facade parse through, so the wire bytes never diverge.
class WavPcmData {
  final Uint8List bytes;
  final int dataOffset;
  final AudioFormat format;

  const WavPcmData({
    required this.bytes,
    required this.dataOffset,
    required this.format,
  });

  /// Parse [bytes] as a PCM16 WAV, or return null when it is too short, not
  /// RIFF, or not 16-bit (mirroring v1's silent rejection).
  static WavPcmData? parse(Uint8List bytes) {
    if (bytes.length < 44) return null;
    final riff = String.fromCharCodes(bytes.sublist(0, 4));
    if (riff != 'RIFF') return null;

    final bd = ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.length);
    final numChannels = bd.getUint16(22, Endian.little);
    final sampleRate = bd.getUint32(24, Endian.little);
    final bitsPerSample = bd.getUint16(34, Endian.little);
    if (bitsPerSample != 16) return null;

    // Find the 'data' chunk offset (default 44 if the tag is not located).
    int dataOffset = 44;
    for (int i = 12; i < bytes.length - 8; i++) {
      if (bytes[i] == 0x64 &&
          bytes[i + 1] == 0x61 &&
          bytes[i + 2] == 0x74 &&
          bytes[i + 3] == 0x61) {
        dataOffset = i + 8;
        break;
      }
    }

    return WavPcmData(
      bytes: bytes,
      dataOffset: dataOffset,
      format: AudioFormat(
        sampleRate: sampleRate,
        channels: numChannels,
        bitDepth: 16,
      ),
    );
  }

  /// Slice the PCM data into [chunkMs]-millisecond chunks, using v1's exact
  /// chunk-size formula. The returned byte slices are identical to what v1's
  /// streaming timer emits, in order.
  List<Uint8List> sliceChunks({int chunkMs = 100}) {
    final bytesPerMs = (format.sampleRate * format.channels * 2) ~/ 1000;
    final chunkSize = bytesPerMs * chunkMs;
    final out = <Uint8List>[];
    if (chunkSize <= 0) return out;
    int offset = dataOffset;
    while (offset < bytes.length) {
      final end = (offset + chunkSize) > bytes.length
          ? bytes.length
          : offset + chunkSize;
      out.add(Uint8List.fromList(bytes.sublist(offset, end)));
      offset = end;
    }
    return out;
  }
}

/// WavFileSource — an [IAudioSource] that streams a PCM16 WAV file in real time,
/// emitting one [PcmChunk] every [chunkMs] milliseconds. This is the extracted,
/// unit-testable form of v1's WAV streaming branch; the AudioService facade
/// parses through the same [WavPcmData] so byte output is unchanged.
class WavFileSource implements IAudioSource {
  WavFileSource._(this._data, this.id, this._chunkMs);

  /// Build a source from raw WAV [bytes]. Parsing happens eagerly; an invalid
  /// WAV yields a source whose [start] returns false.
  factory WavFileSource.fromBytes(
    Uint8List bytes, {
    String id = 'wav-file',
    int chunkMs = 100,
  }) =>
      WavFileSource._(WavPcmData.parse(bytes), id, chunkMs);

  final WavPcmData? _data;
  final int _chunkMs;

  @override
  final String id;

  final StreamController<PcmChunk> _chunks =
      StreamController<PcmChunk>.broadcast();
  Timer? _timer;
  bool _active = false;

  /// Whether the supplied bytes parsed as a valid PCM16 WAV.
  bool get isValid => _data != null;

  @override
  AudioFormat get format => _data?.format ?? AudioFormat.cdStereo;

  @override
  Stream<PcmChunk> get chunks => _chunks.stream;

  @override
  bool get isActive => _active;

  @override
  Future<bool> start() async {
    final data = _data;
    if (data == null || _active) return false;
    final slices = data.sliceChunks(chunkMs: _chunkMs);
    if (slices.isEmpty) return false;

    _active = true;
    var index = 0;
    final chunkDurationUs = _chunkMs * 1000;
    _timer = Timer.periodic(Duration(milliseconds: _chunkMs), (_) {
      if (!_active || index >= slices.length) {
        _stopTimer();
        _active = false;
        return;
      }
      final pcm = slices[index];
      if (!_chunks.isClosed) {
        _chunks.add(PcmChunk(
          pcm: pcm,
          presentationTsUs: index * chunkDurationUs,
          format: data.format,
        ));
      }
      index++;
    });
    return true;
  }

  @override
  Future<void> stop() async {
    _stopTimer();
    _active = false;
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
  }

  /// Release the chunk stream. Call when the source is no longer needed.
  Future<void> dispose() async {
    await stop();
    await _chunks.close();
  }
}
