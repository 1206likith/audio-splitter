import 'dart:typed_data';

import 'package:audio_splitter_app/asp2/crypto/aead_box.dart';
import 'package:audio_splitter_app/asp2/crypto/key_exchange.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List bytes(List<int> b) => Uint8List.fromList(b);

void main() {
  group('NonceSequencer', () {
    test('produces unique, monotonic 12-byte nonces', () {
      final seq = NonceSequencer.fromSalt([1, 2, 3, 4]);
      final seen = <String>{};
      Uint8List? prev;
      for (int i = 0; i < 1000; i++) {
        final n = seq.next();
        expect(n.length, 12);
        expect(n.sublist(0, 4), [1, 2, 3, 4]); // salt preserved
        final key = n.join(',');
        expect(seen.add(key), isTrue, reason: 'nonce repeated at $i');
        prev = n;
      }
      expect(prev, isNotNull);
      expect(seq.counter, 1000);
    });
  });

  group('Asp2AeadBox', () {
    final key32 = bytes(List.generate(32, (i) => (i * 7) & 0xFF));
    final aad = bytes(List.generate(20, (i) => i)); // a 20-byte frame header

    test('seal then open round-trips the plaintext', () async {
      final box = Asp2AeadBox()..setKey(key32);
      final nonce = NonceSequencer.fromSalt([9, 9, 9, 9]).next();
      final plain = bytes(List.generate(120, (i) => (i * 3) & 0xFF));

      final sealed = await box.seal(plaintext: plain, aad: aad, nonce: nonce);
      expect(sealed, isNotNull);
      expect(sealed!.mac.length, Asp2AeadBox.macLength);
      expect(sealed.ciphertext.length, plain.length); // stream cipher
      expect(sealed.ciphertext, isNot(plain)); // actually encrypted

      final opened = await box.open(
        ciphertext: sealed.ciphertext,
        mac: sealed.mac,
        aad: aad,
        nonce: nonce,
      );
      expect(opened, plain);
    });

    test('returns null when no key is installed', () async {
      final box = Asp2AeadBox();
      final nonce = NonceSequencer.fromSalt([0, 0, 0, 0]).next();
      expect(
        await box.seal(plaintext: bytes([1, 2, 3]), aad: aad, nonce: nonce),
        isNull,
      );
      expect(
        await box.open(
          ciphertext: bytes([1, 2, 3]),
          mac: bytes(List.filled(16, 0)),
          aad: aad,
          nonce: nonce,
        ),
        isNull,
      );
    });

    test('rejects a tampered ciphertext (does NOT fail open)', () async {
      final box = Asp2AeadBox()..setKey(key32);
      final nonce = NonceSequencer.fromSalt([5, 6, 7, 8]).next();
      final plain = bytes(List.generate(64, (i) => i));
      final sealed = await box.seal(plaintext: plain, aad: aad, nonce: nonce);

      final tampered = Uint8List.fromList(sealed!.ciphertext);
      tampered[0] ^= 0xFF; // flip a bit

      final opened = await box.open(
        ciphertext: tampered,
        mac: sealed.mac,
        aad: aad,
        nonce: nonce,
      );
      expect(opened, isNull, reason: 'tampered frame must be dropped');
    });

    test('rejects a tampered AAD/header', () async {
      final box = Asp2AeadBox()..setKey(key32);
      final nonce = NonceSequencer.fromSalt([1, 1, 1, 1]).next();
      final plain = bytes(List.generate(32, (i) => i));
      final sealed = await box.seal(plaintext: plain, aad: aad, nonce: nonce);

      final badAad = Uint8List.fromList(aad);
      badAad[1] ^= 0x01; // pretend codec_id changed

      final opened = await box.open(
        ciphertext: sealed!.ciphertext,
        mac: sealed.mac,
        aad: badAad,
        nonce: nonce,
      );
      expect(opened, isNull, reason: 'header tampering must be detected');
    });

    test('rejects the wrong key', () async {
      final sender = Asp2AeadBox()..setKey(key32);
      final nonce = NonceSequencer.fromSalt([2, 2, 2, 2]).next();
      final plain = bytes(List.generate(48, (i) => i));
      final sealed =
          await sender.seal(plaintext: plain, aad: aad, nonce: nonce);

      final wrong = Asp2AeadBox()
        ..setKey(bytes(List.generate(32, (i) => (i + 1) & 0xFF)));
      final opened = await wrong.open(
        ciphertext: sealed!.ciphertext,
        mac: sealed.mac,
        aad: aad,
        nonce: nonce,
      );
      expect(opened, isNull);
    });
  });

  group('DeviceIdentity (Ed25519)', () {
    test('sign and verify round-trip', () async {
      final id = await DeviceIdentity.generate();
      final pub = await id.publicKeyBytes();
      expect(pub.length, 32);
      final msg = bytes(List.generate(40, (i) => i));
      final sig = await id.sign(msg);
      expect(await DeviceIdentity.verify(msg, sig, pub), isTrue);
    });

    test('verify fails on a tampered message', () async {
      final id = await DeviceIdentity.generate();
      final pub = await id.publicKeyBytes();
      final msg = bytes(List.generate(40, (i) => i));
      final sig = await id.sign(msg);
      final badMsg = Uint8List.fromList(msg)..[0] ^= 0xFF;
      expect(await DeviceIdentity.verify(badMsg, sig, pub), isFalse);
    });

    test('restores from a persisted seed to the same public key', () async {
      final id = await DeviceIdentity.generate();
      final seed = await id.seedBytes();
      final restored = await DeviceIdentity.fromSeed(seed);
      expect(await restored.publicKeyBytes(), await id.publicKeyBytes());
    });
  });

  group('SessionHandshake (X25519) end-to-end', () {
    test('both sides derive the same key and exchange real ciphertext',
        () async {
      // Each side has an identity + an ephemeral keypair.
      final aliceId = await DeviceIdentity.generate();
      final bobId = await DeviceIdentity.generate();
      final alice = await SessionHandshake.generate();
      final bob = await SessionHandshake.generate();

      final aliceEph = await alice.ephemeralPublicKey();
      final bobEph = await bob.ephemeralPublicKey();

      // Each signs its ephemeral key; the peer verifies before trusting it.
      final aliceSig = await aliceId.sign(aliceEph);
      final bobSig = await bobId.sign(bobEph);
      expect(
        await DeviceIdentity.verify(
            aliceEph, aliceSig, await aliceId.publicKeyBytes()),
        isTrue,
      );
      expect(
        await DeviceIdentity.verify(
            bobEph, bobSig, await bobId.publicKeyBytes()),
        isTrue,
      );

      // Derive the session key on both sides — they must match.
      final aliceKey = await alice.deriveSessionKey(bobEph);
      final bobKey = await bob.deriveSessionKey(aliceEph);
      expect(aliceKey, bobKey);
      expect(aliceKey.length, 32);

      // Use the derived key for a real AEAD round-trip across the "wire".
      final aliceBox = Asp2AeadBox()..setKey(aliceKey);
      final bobBox = Asp2AeadBox()..setKey(bobKey);
      final aad = bytes(List.generate(20, (i) => i));
      final nonce = NonceSequencer.fromSalt([7, 7, 7, 7]).next();
      final plain = bytes(List.generate(200, (i) => (i * 5) & 0xFF));

      final sealed =
          await aliceBox.seal(plaintext: plain, aad: aad, nonce: nonce);
      final opened = await bobBox.open(
        ciphertext: sealed!.ciphertext,
        mac: sealed.mac,
        aad: aad,
        nonce: nonce,
      );
      expect(opened, plain);
    });
  });
}
