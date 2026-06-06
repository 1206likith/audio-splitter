import 'dart:typed_data';

import 'package:audio_splitter_app/asp2/crypto/crypto_box.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Uint8List sample() =>
      Uint8List.fromList(List<int>.generate(200, (i) => (i * 7) & 0xFF));

  test('disabled box seals as identity (byte-identical plaintext on the wire)',
      () {
    final box = CryptoBox();
    final plain = sample();
    final sealed = box.seal(plain);
    expect(box.enabled, isFalse);
    expect(sealed, plain); // unchanged bytes when encryption is off
    expect(box.keyHex, isNull);
  });

  test('enable() exposes a keyHex:ivHex string of two 32-hex halves', () {
    final box = CryptoBox();
    box.enable();
    expect(box.enabled, isTrue);
    final hex = box.keyHex!;
    final parts = hex.split(':');
    expect(parts, hasLength(2));
    expect(parts[0], hasLength(32)); // 16-byte key
    expect(parts[1], hasLength(32)); // 16-byte IV
    expect(RegExp(r'^[0-9a-f]+$').hasMatch(parts[0]), isTrue);
  });

  test('seal -> open round-trips when receiver shares the host keyHex', () {
    final host = CryptoBox()..enable();
    final plain = sample();
    final sealed = host.seal(plain);
    expect(sealed, isNot(equals(plain))); // actually encrypted

    final client = CryptoBox()..configureReceiver(host.keyHex!);
    expect(client.hasReceiver, isTrue);
    expect(client.open(sealed), plain);
  });

  test('open with no receiver passes bytes through unchanged (fail-open)', () {
    final box = CryptoBox();
    final data = sample();
    expect(box.hasReceiver, isFalse);
    expect(box.open(data), data);
  });

  test('configureReceiver ignores a malformed key string', () {
    final box = CryptoBox();
    box.configureReceiver('not-a-valid-key');
    expect(box.hasReceiver, isFalse);
    final data = sample();
    expect(box.open(data), data);
  });

  test('disable() clears the key and reverts to identity sealing', () {
    final box = CryptoBox()..enable();
    box.disable();
    expect(box.enabled, isFalse);
    expect(box.keyHex, isNull);
    final plain = sample();
    expect(box.seal(plain), plain);
  });

  test('clearReceiver() drops the configured key', () {
    final host = CryptoBox()..enable();
    final box = CryptoBox()..configureReceiver(host.keyHex!);
    expect(box.hasReceiver, isTrue);
    box.clearReceiver();
    expect(box.hasReceiver, isFalse);
  });
}
