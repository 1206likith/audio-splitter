import 'dart:typed_data';

import 'package:audio_splitter_app/asp2/crypto/aead_box.dart';
import 'package:audio_splitter_app/asp2/frame/asp2_frame.dart';
import 'package:audio_splitter_app/asp2/frame/frame_codec.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List bytes(List<int> b) => Uint8List.fromList(b);

Asp2Frame sampleFrame({Uint8List? payload}) => Asp2Frame(
      codecId: 1,
      streamId: 7,
      sequenceNumber: 42,
      presentationTsUs: 123456,
      payload: payload ?? bytes(List.generate(80, (i) => (i * 3) & 0xFF)),
    );

void main() {
  final key = bytes(List.generate(32, (i) => (i * 5 + 1) & 0xFF));

  FrameCodec codecWithKey() => FrameCodec(Asp2AeadBox()..setKey(key));

  group('FrameCodec', () {
    test('seal → encode → decode → open round-trips and preserves header',
        () async {
      final codec = codecWithKey();
      final nonce = NonceSequencer.fromSalt([1, 2, 3, 4]).next();
      final plain = sampleFrame();

      final sealed = await codec.seal(plain, nonce);
      expect(sealed, isNotNull);
      expect(sealed!.isEncrypted, isTrue);
      expect(sealed.tag!.length, 16);
      expect(sealed.nonce!.length, 12);
      // Header fields survive sealing.
      expect(sealed.codecId, plain.codecId);
      expect(sealed.streamId, plain.streamId);
      expect(sealed.sequenceNumber, plain.sequenceNumber);
      expect(sealed.presentationTsUs, plain.presentationTsUs);

      // Round-trip through the actual wire bytes.
      final wire = sealed.encode();
      final parsed = Asp2Frame.decode(wire);
      final opened = await codec.open(parsed);

      expect(opened, isNotNull);
      expect(opened!.isEncrypted, isFalse);
      expect(opened.payload, plain.payload);
      expect(opened.codecId, plain.codecId);
      expect(opened.presentationTsUs, plain.presentationTsUs);
    });

    test('plaintext frame passes through open unchanged', () async {
      final codec = codecWithKey();
      final plain = sampleFrame();
      final opened = await codec.open(plain);
      expect(identical(opened, plain), isTrue);
    });

    test('seal returns null without a key', () async {
      final codec = FrameCodec(Asp2AeadBox());
      final nonce = NonceSequencer.fromSalt([0, 0, 0, 0]).next();
      expect(await codec.seal(sampleFrame(), nonce), isNull);
    });

    test('tampered ciphertext is rejected (frame dropped)', () async {
      final codec = codecWithKey();
      final nonce = NonceSequencer.fromSalt([9, 8, 7, 6]).next();
      final sealed = await codec.seal(sampleFrame(), nonce);
      final tampered = sealed!.copyWith(
        payload: Uint8List.fromList(sealed.payload)..[0] ^= 0xFF,
      );
      expect(await codec.open(tampered), isNull);
    });

    test('tampered header (seq) is rejected via AAD', () async {
      final codec = codecWithKey();
      final nonce = NonceSequencer.fromSalt([4, 4, 4, 4]).next();
      final sealed = await codec.seal(sampleFrame(), nonce);
      // Flip a header field — re-encode keeps a valid frame but breaks the AAD.
      final tampered = sealed!.copyWith(sequenceNumber: 99);
      expect(await codec.open(tampered), isNull,
          reason: 'header is authenticated as AAD');
    });

    test('wrong key cannot open', () async {
      final sender = codecWithKey();
      final nonce = NonceSequencer.fromSalt([2, 2, 2, 2]).next();
      final sealed = await sender.seal(sampleFrame(), nonce);

      final receiver = FrameCodec(
        Asp2AeadBox()..setKey(bytes(List.generate(32, (i) => i))),
      );
      expect(await receiver.open(sealed!), isNull);
    });
  });
}
