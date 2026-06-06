import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Long-term device identity (Ed25519).
///
/// Each device holds one Ed25519 keypair whose public half is its stable
/// identity (persist via secure storage in the app layer). It signs the
/// ephemeral X25519 public key during a handshake so a peer can verify the
/// session key really came from this device — preventing a man-in-the-middle
/// from swapping in their own ephemeral key.
class DeviceIdentity {
  static final Ed25519 _ed = Ed25519();

  final SimpleKeyPair _keyPair;
  DeviceIdentity._(this._keyPair);

  /// Generate a fresh identity (first run).
  static Future<DeviceIdentity> generate() async {
    return DeviceIdentity._(await _ed.newKeyPair());
  }

  /// Reconstruct an identity from a previously persisted 32-byte Ed25519 seed
  /// (the private-key bytes from [seedBytes]).
  static Future<DeviceIdentity> fromSeed(List<int> seed) async {
    if (seed.length != 32) {
      throw ArgumentError('Ed25519 seed must be 32 bytes');
    }
    return DeviceIdentity._(await _ed.newKeyPairFromSeed(List<int>.from(seed)));
  }

  /// The 32-byte private seed, for persistence (store securely).
  Future<Uint8List> seedBytes() async =>
      Uint8List.fromList(await _keyPair.extractPrivateKeyBytes());

  /// The 32-byte Ed25519 public key — this device's advertised identity.
  Future<Uint8List> publicKeyBytes() async {
    final pub = await _keyPair.extractPublicKey();
    return Uint8List.fromList(pub.bytes);
  }

  /// Sign [message] (e.g. an ephemeral X25519 public key) with this identity.
  Future<Uint8List> sign(List<int> message) async {
    final sig = await _ed.sign(message, keyPair: _keyPair);
    return Uint8List.fromList(sig.bytes);
  }

  /// Verify that [signature] over [message] was produced by the holder of
  /// [publicKey] (a 32-byte Ed25519 public key).
  static Future<bool> verify(
    List<int> message,
    List<int> signature,
    List<int> publicKey,
  ) async {
    final sig = Signature(
      signature,
      publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519),
    );
    return _ed.verify(message, signature: sig);
  }
}

/// One side of an X25519 ECDH session handshake.
///
/// Each party generates an ephemeral keypair, exchanges (signed) public keys,
/// and derives the same 32-byte session key via X25519 + HKDF-SHA256. The
/// ephemeral keys are discarded after the session, giving forward secrecy; the
/// app rotates the session every 5 minutes by running a fresh exchange.
class SessionHandshake {
  static final X25519 _x = X25519();

  /// Domain-separation string mixed into HKDF so this key can't collide with a
  /// key derived for any other purpose from the same shared secret.
  static const List<int> _hkdfInfo = [
    0x41, 0x53, 0x50, 0x32, // "ASP2"
    0x2d, 0x73, 0x65, 0x73, 0x73, 0x69, 0x6f, 0x6e, // "-session"
  ];

  final SimpleKeyPair _ephemeral;
  SessionHandshake._(this._ephemeral);

  /// Generate this side's ephemeral keypair.
  static Future<SessionHandshake> generate() async {
    return SessionHandshake._(await _x.newKeyPair());
  }

  /// Our ephemeral X25519 public key, to send to the peer (sign it with the
  /// [DeviceIdentity] before sending).
  Future<Uint8List> ephemeralPublicKey() async {
    final pub = await _ephemeral.extractPublicKey();
    return Uint8List.fromList(pub.bytes);
  }

  /// Derive the shared 32-byte session key from the peer's ephemeral public key.
  /// Both sides arrive at the identical key. Run the result into
  /// [Asp2AeadBox.setKey].
  Future<Uint8List> deriveSessionKey(List<int> peerPublicKey) async {
    final shared = await _x.sharedSecretKey(
      keyPair: _ephemeral,
      remotePublicKey: SimplePublicKey(peerPublicKey, type: KeyPairType.x25519),
    );
    // HKDF-SHA256 the raw ECDH output into a clean 32-byte AEAD key.
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    final derived = await hkdf.deriveKey(
      secretKey: shared,
      info: _hkdfInfo,
      nonce: const [], // no salt; domain separation via info is sufficient here
    );
    return Uint8List.fromList(await derived.extractBytes());
  }
}
