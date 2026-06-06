import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// The ciphertext + authentication tag produced by [Asp2AeadBox.seal].
///
/// These map directly onto the ASP-2 frame trailer: [ciphertext] replaces the
/// plaintext payload, [mac] is the 16-byte Poly1305 tag, and the 12-byte nonce
/// is carried separately (it is an input to seal/open, not secret).
class SealedPayload {
  final Uint8List ciphertext;
  final Uint8List mac;
  const SealedPayload(this.ciphertext, this.mac);
}

/// Monotonic 96-bit nonce generator for one key epoch.
///
/// Nonce = 4-byte random session salt ++ 8-byte little-endian counter. The salt
/// makes nonces distinct across devices/epochs that happen to share a counter
/// origin; the counter guarantees uniqueness within an epoch (the cardinal AEAD
/// rule: never reuse a (key, nonce) pair). At 50 frames/s a 64-bit counter lasts
/// ~11 billion years, and the key rotates every 5 minutes regardless.
class NonceSequencer {
  final Uint8List _salt; // 4 bytes
  int _counter = 0;

  NonceSequencer(List<int> salt)
      : _salt = Uint8List.fromList(salt.sublist(0, 4));

  /// Build a sequencer from 4 bytes of randomness (caller supplies, so this
  /// stays testable / Math.random-free).
  factory NonceSequencer.fromSalt(List<int> saltBytes) =>
      NonceSequencer(saltBytes);

  /// Produce the next unique 12-byte nonce.
  Uint8List next() {
    final nonce = Uint8List(12);
    nonce.setRange(0, 4, _salt);
    ByteData.view(nonce.buffer).setUint64(4, _counter, Endian.little);
    _counter++;
    return nonce;
  }

  /// The counter value the next [next] call will use (for tests / telemetry).
  int get counter => _counter;
}

/// ASP-2 AEAD sealing with ChaCha20-Poly1305-IETF (12-byte nonce).
///
/// Replaces v1's unauthenticated AES-CTR for the native ASP-2 wire. The 20-byte
/// frame header is bound in as associated data (AAD), so any tampering with
/// codec_id / stream_id / seq / pts is detected and the frame rejected.
///
/// Unlike the legacy [CryptoBox], [open] **does not fail open**: an
/// authentication failure means corruption or tampering, so the frame is dropped
/// (returns null) rather than passed through as plaintext. That is the whole
/// point of authenticated encryption.
///
/// Backend is pure-Dart `package:cryptography`; the `encrypt`/`decrypt` calls are
/// async by that package's contract. For the real-time path a native sync
/// backend can replace this behind the same method shapes without caller change.
class Asp2AeadBox {
  final Chacha20 _algorithm = Chacha20.poly1305Aead();
  SecretKey? _key;

  /// 32-byte key length required by ChaCha20.
  static const int keyLength = 32;

  /// 12-byte IETF nonce length.
  static const int nonceLength = 12;

  /// 16-byte Poly1305 tag length.
  static const int macLength = 16;

  bool get hasKey => _key != null;

  /// Install the 32-byte session key (from the X25519+HKDF handshake).
  void setKey(List<int> keyBytes) {
    if (keyBytes.length != keyLength) {
      throw ArgumentError('ChaCha20 key must be $keyLength bytes');
    }
    _key = SecretKey(List<int>.from(keyBytes));
  }

  /// Forget the session key (e.g. on disconnect or before a rotation swap).
  void clearKey() => _key = null;

  /// Encrypt [plaintext] under [nonce], binding [aad] (the frame header).
  /// Returns null when no key is installed.
  Future<SealedPayload?> seal({
    required Uint8List plaintext,
    required Uint8List aad,
    required Uint8List nonce,
  }) async {
    final key = _key;
    if (key == null) return null;
    if (nonce.length != nonceLength) {
      throw ArgumentError('nonce must be $nonceLength bytes');
    }
    final box = await _algorithm.encrypt(
      plaintext,
      secretKey: key,
      nonce: nonce,
      aad: aad,
    );
    return SealedPayload(
      Uint8List.fromList(box.cipherText),
      Uint8List.fromList(box.mac.bytes),
    );
  }

  /// Decrypt + verify. Returns the plaintext, or null when no key is installed
  /// **or authentication fails** (tampered/corrupt frame → drop, never trust).
  Future<Uint8List?> open({
    required Uint8List ciphertext,
    required Uint8List mac,
    required Uint8List aad,
    required Uint8List nonce,
  }) async {
    final key = _key;
    if (key == null) return null;
    try {
      final clear = await _algorithm.decrypt(
        SecretBox(ciphertext, nonce: nonce, mac: Mac(mac)),
        secretKey: key,
        aad: aad,
      );
      return Uint8List.fromList(clear);
    } catch (_) {
      // SecretBoxAuthenticationError or any failure → reject the frame.
      return null;
    }
  }
}
