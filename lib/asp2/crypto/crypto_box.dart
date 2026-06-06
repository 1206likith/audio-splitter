import 'dart:math' show Random;
import 'dart:typed_data';

import 'package:encrypt/encrypt.dart' as enc;

/// CryptoBox — the ASP-2 frame-encryption seam.
///
/// Phase 0 wraps v1's exact AES-CTR-128 scheme (no padding) behind a single
/// object so the rest of the stack talks to one interface. The wire format and
/// the `keyHex:ivHex` key-exchange string are **byte-identical to v1**, so the
/// embedded browser client (which does AES-CTR via Web Crypto) keeps decrypting
/// unchanged. Phase 1 swaps the internals for ChaCha20-Poly1305-IETF AEAD
/// without touching callers.
///
/// A CryptoBox plays two independent roles because [StreamingService] is a
/// singleton acting as both host and client:
///   * **sender** — owns this device's session key ([enable]); [seal] encrypts.
///   * **receiver** — configured with a peer's key ([configureReceiver]);
///     [open] decrypts.
///
/// Both [seal] and [open] **fail open**: on any crypto error they return the
/// input bytes unchanged, exactly reproducing v1's "try encrypted, fall back to
/// plaintext" behaviour so a key mishap never silences audio.
class CryptoBox {
  // --- sender role ---
  enc.Key? _senderKey;
  enc.IV? _senderIV;
  enc.Encrypter? _senderEncrypter;
  bool _enabled = false;

  // --- receiver role ---
  enc.IV? _receiverIV;
  enc.Encrypter? _receiverDecrypter;

  /// Whether this box will encrypt outbound frames.
  bool get enabled => _enabled;

  /// Generate a fresh random 128-bit session key + IV and begin encrypting.
  void enable() {
    final rng = Random.secure();
    final keyBytes = List<int>.generate(16, (_) => rng.nextInt(256));
    final ivBytes = List<int>.generate(16, (_) => rng.nextInt(256));
    _senderKey = enc.Key(Uint8List.fromList(keyBytes));
    _senderIV = enc.IV(Uint8List.fromList(ivBytes));
    _senderEncrypter = enc.Encrypter(
      enc.AES(_senderKey!, mode: enc.AESMode.ctr, padding: null),
    );
    _enabled = true;
  }

  /// Stop encrypting and forget the session key.
  void disable() {
    _enabled = false;
    _senderKey = null;
    _senderIV = null;
    _senderEncrypter = null;
  }

  /// The session key+IV as `"keyHex:ivHex"` for sharing with clients, or null
  /// when encryption is off. This is the exact string v1 put in the `welcome`
  /// message's `encryptionKey` field.
  String? get keyHex {
    final key = _senderKey;
    final iv = _senderIV;
    if (key == null || iv == null) return null;
    final k = key.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final i = iv.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '$k:$i';
  }

  /// Encrypt [plain] with the sender key. Returns [plain] unchanged when
  /// disabled or on any error (fail-open, matching v1).
  Uint8List seal(Uint8List plain) {
    final encrypter = _senderEncrypter;
    final iv = _senderIV;
    if (!_enabled || encrypter == null || iv == null) return plain;
    try {
      return Uint8List.fromList(encrypter.encryptBytes(plain, iv: iv).bytes);
    } catch (_) {
      return plain;
    }
  }

  /// Configure the receiver role from a `"keyHex:ivHex"` string (as received in
  /// a host `welcome` message). Silently ignores a malformed string, leaving
  /// the receiver unconfigured so [open] passes frames through untouched.
  void configureReceiver(String keyAndIvHex) {
    try {
      final parts = keyAndIvHex.split(':');
      if (parts.length != 2) return;
      final keyBytes = Uint8List.fromList(
        List.generate(
          16,
          (i) => int.parse(parts[0].substring(i * 2, i * 2 + 2), radix: 16),
        ),
      );
      final ivBytes = Uint8List.fromList(
        List.generate(
          16,
          (i) => int.parse(parts[1].substring(i * 2, i * 2 + 2), radix: 16),
        ),
      );
      _receiverIV = enc.IV(ivBytes);
      _receiverDecrypter = enc.Encrypter(
        enc.AES(enc.Key(keyBytes), mode: enc.AESMode.ctr, padding: null),
      );
    } catch (_) {
      // Leave receiver unconfigured; open() will pass through.
    }
  }

  /// Clear any configured receiver key (e.g. on client disconnect).
  void clearReceiver() {
    _receiverIV = null;
    _receiverDecrypter = null;
  }

  /// Whether a receiver key has been configured.
  bool get hasReceiver => _receiverDecrypter != null && _receiverIV != null;

  /// Decrypt [data] with the configured receiver key. Returns [data] unchanged
  /// when no receiver is configured or on any error (fail-open, matching v1).
  Uint8List open(Uint8List data) {
    final decrypter = _receiverDecrypter;
    final iv = _receiverIV;
    if (decrypter == null || iv == null) return data;
    try {
      return Uint8List.fromList(
        decrypter.decryptBytes(enc.Encrypted(data), iv: iv),
      );
    } catch (_) {
      return data;
    }
  }
}
