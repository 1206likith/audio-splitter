import 'dart:typed_data';

import '../crypto/aead_box.dart';
import 'asp2_frame.dart';

/// Ties the frame layer to the crypto layer: seals an [Asp2Frame]'s payload with
/// ChaCha20-Poly1305 (binding the 20-byte header as AAD) and reverses it.
///
/// This is the seam where "a frame" becomes "an encrypted-on-the-wire frame".
/// Encryption is in-place on the payload: ChaCha20 is a stream cipher so the
/// ciphertext is the same length as the plaintext, which keeps the header's
/// payload_len — and therefore the AAD — identical on both sides.
class FrameCodec {
  final Asp2AeadBox _aead;

  FrameCodec(this._aead);

  bool get canEncrypt => _aead.hasKey;

  /// Encrypt [frame]'s plaintext payload, returning a new frame with the
  /// encrypted flag set and the tag + nonce attached. The [nonce] must be unique
  /// per key (use a [NonceSequencer]). Returns null when no key is installed.
  ///
  /// AAD is the header *as it will appear on the wire* (encrypted flag set,
  /// payload_len = ciphertext length = plaintext length), so the receiver
  /// recomputes the identical AAD from the bytes it parses.
  Future<Asp2Frame?> seal(Asp2Frame frame, Uint8List nonce) async {
    final encryptedHeaderFrame = frame.copyWith(
      flags: frame.flags | Asp2Frame.flagEncrypted,
    );
    final aad = encryptedHeaderFrame.encodeHeader();
    final sealed = await _aead.seal(
      plaintext: frame.payload,
      aad: aad,
      nonce: nonce,
    );
    if (sealed == null) return null;
    return Asp2Frame(
      version: frame.version,
      flags: frame.flags | Asp2Frame.flagEncrypted,
      codecId: frame.codecId,
      streamId: frame.streamId,
      sequenceNumber: frame.sequenceNumber,
      presentationTsUs: frame.presentationTsUs,
      fecGroupId: frame.fecGroupId,
      fecIndex: frame.fecIndex,
      payload: sealed.ciphertext,
      tag: sealed.mac,
      nonce: nonce,
    );
  }

  /// Decrypt + authenticate [frame]. A plaintext frame passes through unchanged.
  /// Returns null when authentication fails (tampered/corrupt → drop) or no key
  /// is installed — the frame layer then drops the packet, never trusting it.
  Future<Asp2Frame?> open(Asp2Frame frame) async {
    if (!frame.isEncrypted) return frame;
    final tag = frame.tag;
    final nonce = frame.nonce;
    if (tag == null || nonce == null) return null;
    final aad = frame.encodeHeader();
    final plain = await _aead.open(
      ciphertext: frame.payload,
      mac: tag,
      aad: aad,
      nonce: nonce,
    );
    if (plain == null) return null;
    return Asp2Frame(
      version: frame.version,
      flags: frame.flags & ~Asp2Frame.flagEncrypted,
      codecId: frame.codecId,
      streamId: frame.streamId,
      sequenceNumber: frame.sequenceNumber,
      presentationTsUs: frame.presentationTsUs,
      fecGroupId: frame.fecGroupId,
      fecIndex: frame.fecIndex,
      payload: plain,
    );
  }
}
