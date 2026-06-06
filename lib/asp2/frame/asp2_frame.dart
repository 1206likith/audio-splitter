import 'dart:typed_data';

/// ASP-2 binary media frame.
///
/// Wire layout (all integers little-endian) — locked in Phase 0:
/// ```
/// Offset  Size  Field
/// 0       1     version (high 4 bits) | flags (low 4 bits)
/// 1       1     codec_id      (0=PCM16, 1=Opus, 2=LC3, 3=FLAC, 4..15 reserved)
/// 2       2     stream_id     (uint16, zone/track identifier)
/// 4       4     sequence_no   (uint32, monotonic per stream)
/// 8       8     pts_us        (uint64, host clock microseconds)
/// 16      2     payload_len   (uint16)
/// 18      1     fec_group_id  (0 = no FEC)
/// 19      1     fec_index     (data or parity index within the group)
/// 20      N     payload       (ciphertext when the encrypted flag is set)
/// 20+N    16    Poly1305 tag  (only when encrypted)
/// 36+N    12    AEAD nonce    (only when encrypted)
/// ```
///
/// The 20-byte header is also used verbatim as the AEAD associated data (AAD),
/// so any tampering with codec_id / stream_id / seq / pts is detected.
class Asp2Frame {
  /// Fixed header length in bytes.
  static const int headerSize = 20;

  /// Poly1305 / AEAD tag length appended after the payload when encrypted.
  static const int tagSize = 16;

  /// AEAD nonce length appended after the tag when encrypted.
  ///
  /// Note: 12 bytes — the v2 build uses ChaCha20-Poly1305-IETF (12-byte nonce)
  /// rather than XChaCha20 (24-byte) so the field fits the frame as drawn.
  static const int nonceSize = 12;

  /// Current protocol version (4-bit field, 0..15).
  static const int currentVersion = 2;

  // --- flag bits (low nibble of byte 0) ---
  /// Payload is encrypted; tag + nonce trail the payload.
  static const int flagEncrypted = 0x1;

  /// This frame is an FEC parity frame (not original media data).
  static const int flagParity = 0x2;

  final int version;
  final int flags;
  final int codecId;
  final int streamId;
  final int sequenceNumber;
  final int presentationTsUs;
  final int fecGroupId;
  final int fecIndex;

  /// Payload bytes. Plaintext when [isEncrypted] is false, ciphertext otherwise.
  final Uint8List payload;

  /// 16-byte AEAD tag (only present when [isEncrypted]).
  final Uint8List? tag;

  /// 12-byte AEAD nonce (only present when [isEncrypted]).
  final Uint8List? nonce;

  Asp2Frame({
    this.version = currentVersion,
    this.flags = 0,
    required this.codecId,
    this.streamId = 0,
    required this.sequenceNumber,
    required this.presentationTsUs,
    this.fecGroupId = 0,
    this.fecIndex = 0,
    required this.payload,
    this.tag,
    this.nonce,
  });

  bool get isEncrypted => (flags & flagEncrypted) != 0;
  bool get isParity => (flags & flagParity) != 0;

  /// Serialize just the 20-byte header. This is also the AEAD AAD.
  Uint8List encodeHeader() {
    final header = Uint8List(headerSize);
    final bd = ByteData.view(header.buffer);
    bd.setUint8(0, ((version & 0x0F) << 4) | (flags & 0x0F));
    bd.setUint8(1, codecId & 0xFF);
    bd.setUint16(2, streamId & 0xFFFF, Endian.little);
    bd.setUint32(4, sequenceNumber & 0xFFFFFFFF, Endian.little);
    bd.setUint64(8, presentationTsUs, Endian.little);
    bd.setUint16(16, payload.length & 0xFFFF, Endian.little);
    bd.setUint8(18, fecGroupId & 0xFF);
    bd.setUint8(19, fecIndex & 0xFF);
    return header;
  }

  /// Serialize the full frame: header + payload (+ tag + nonce when encrypted).
  Uint8List encode() {
    final header = encodeHeader();
    final encrypted = isEncrypted;
    if (encrypted && (tag == null || nonce == null)) {
      throw StateError('Encrypted frame requires both tag and nonce');
    }
    final trailer = encrypted ? tagSize + nonceSize : 0;
    final out = Uint8List(headerSize + payload.length + trailer);
    out.setRange(0, headerSize, header);
    out.setRange(headerSize, headerSize + payload.length, payload);
    if (encrypted) {
      final tagStart = headerSize + payload.length;
      out.setRange(tagStart, tagStart + tagSize, tag!);
      out.setRange(tagStart + tagSize, tagStart + tagSize + nonceSize, nonce!);
    }
    return out;
  }

  /// Parse a frame from [bytes]. Throws [FormatException] on a malformed or
  /// truncated buffer so the transport can drop it (mirrors v1's silent drop).
  factory Asp2Frame.decode(Uint8List bytes) {
    if (bytes.length < headerSize) {
      throw const FormatException('ASP-2 frame shorter than header');
    }
    final bd = ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.length);
    final b0 = bd.getUint8(0);
    final version = (b0 >> 4) & 0x0F;
    final flags = b0 & 0x0F;
    final codecId = bd.getUint8(1);
    final streamId = bd.getUint16(2, Endian.little);
    final sequenceNumber = bd.getUint32(4, Endian.little);
    final presentationTsUs = bd.getUint64(8, Endian.little);
    final payloadLength = bd.getUint16(16, Endian.little);
    final fecGroupId = bd.getUint8(18);
    final fecIndex = bd.getUint8(19);

    final encrypted = (flags & flagEncrypted) != 0;
    final trailer = encrypted ? tagSize + nonceSize : 0;
    final needed = headerSize + payloadLength + trailer;
    if (bytes.length < needed) {
      throw FormatException(
          'ASP-2 frame truncated: need $needed bytes, have ${bytes.length}');
    }

    const payloadStart = headerSize;
    final payload = Uint8List.sublistView(
        bytes, payloadStart, payloadStart + payloadLength);

    Uint8List? tag;
    Uint8List? nonce;
    if (encrypted) {
      final tagStart = payloadStart + payloadLength;
      tag = Uint8List.sublistView(bytes, tagStart, tagStart + tagSize);
      nonce = Uint8List.sublistView(
          bytes, tagStart + tagSize, tagStart + tagSize + nonceSize);
    }

    return Asp2Frame(
      version: version,
      flags: flags,
      codecId: codecId,
      streamId: streamId,
      sequenceNumber: sequenceNumber,
      presentationTsUs: presentationTsUs,
      fecGroupId: fecGroupId,
      fecIndex: fecIndex,
      payload: Uint8List.fromList(payload),
      tag: tag == null ? null : Uint8List.fromList(tag),
      nonce: nonce == null ? null : Uint8List.fromList(nonce),
    );
  }

  Asp2Frame copyWith({
    int? version,
    int? flags,
    int? codecId,
    int? streamId,
    int? sequenceNumber,
    int? presentationTsUs,
    int? fecGroupId,
    int? fecIndex,
    Uint8List? payload,
    Uint8List? tag,
    Uint8List? nonce,
  }) {
    return Asp2Frame(
      version: version ?? this.version,
      flags: flags ?? this.flags,
      codecId: codecId ?? this.codecId,
      streamId: streamId ?? this.streamId,
      sequenceNumber: sequenceNumber ?? this.sequenceNumber,
      presentationTsUs: presentationTsUs ?? this.presentationTsUs,
      fecGroupId: fecGroupId ?? this.fecGroupId,
      fecIndex: fecIndex ?? this.fecIndex,
      payload: payload ?? this.payload,
      tag: tag ?? this.tag,
      nonce: nonce ?? this.nonce,
    );
  }

  @override
  String toString() => 'Asp2Frame(v$version, codec=$codecId, stream=$streamId, '
      'seq=$sequenceNumber, pts=${presentationTsUs}us, '
      '${payload.length}B${isEncrypted ? ', enc' : ''})';
}
