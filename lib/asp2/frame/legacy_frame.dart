import 'dart:typed_data';

/// Result of parsing a legacy (v1) binary audio frame.
class LegacyFrame {
  /// PCM16 payload (the bytes after the 9-byte header).
  final Uint8List payload;

  /// Host-clock timestamp in **milliseconds** (v1 used ms, not µs).
  final int timestampMs;

  const LegacyFrame({required this.payload, required this.timestampMs});
}

/// Byte-for-byte reproduction of the v1 wire frame, extracted from
/// `StreamingService._buildBinaryAudioFrame` / `_handleHostBinary`.
///
/// v1 layout:
/// ```
/// byte 0       : frame type, always 1 (audio)
/// bytes 1..8   : int64 little-endian timestamp in milliseconds
/// bytes 9..N   : raw PCM16 payload
/// ```
///
/// This is the frame that ships on the wire during Phase 0 (`useAsp2Wire`
/// off) so existing v1 native clients and the embedded browser client keep
/// working unchanged. A golden-bytes test pins this against the original
/// inline implementation.
class LegacyFrameCodec {
  static const int headerSize = 9;
  static const int audioFrameType = 1;

  /// Build a v1 audio frame: `[1][int64 LE ts][payload]`.
  static Uint8List encode(Uint8List audioData, int timestampMs) {
    final header = Uint8List(headerSize);
    header[0] = audioFrameType;
    final bd = ByteData.view(header.buffer);
    bd.setInt64(1, timestampMs, Endian.little);
    final out = Uint8List(headerSize + audioData.length);
    out.setRange(0, headerSize, header);
    out.setRange(headerSize, out.length, audioData);
    return out;
  }

  /// Parse a v1 audio frame. Returns null when the buffer is too short or the
  /// type byte is not an audio frame (mirrors v1's silent drop behaviour).
  static LegacyFrame? decode(Uint8List data) {
    if (data.length < headerSize) return null;
    if (data[0] != audioFrameType) return null;
    final bd = ByteData.sublistView(data, 1, headerSize);
    final ts = bd.getInt64(0, Endian.little);
    final payload = Uint8List.sublistView(data, headerSize);
    if (payload.isEmpty) return null;
    return LegacyFrame(payload: Uint8List.fromList(payload), timestampMs: ts);
  }
}
