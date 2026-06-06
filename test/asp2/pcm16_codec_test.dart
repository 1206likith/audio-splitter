import 'dart:typed_data';

import 'package:audio_splitter_app/asp2/codec/pcm16_codec.dart';
import 'package:audio_splitter_app/core/contracts/i_codec.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Pcm16Codec advertises codec_id 0', () {
    expect(Pcm16Codec().codecId, CodecId.pcm16);
    expect(CodecId.pcm16, 0);
  });

  test('Pcm16Codec encode/decode are identity and round-trip', () {
    final codec = Pcm16Codec();
    final pcm =
        Uint8List.fromList(List<int>.generate(960 * 2 * 2, (i) => i & 0xFF));
    final encoded = codec.encode(pcm);
    expect(encoded, same(pcm)); // identity, no copy
    expect(codec.decode(encoded), pcm);
    codec.dispose();
  });
}
