import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_splitter_app/asp2/frame/asp2_frame.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _hexToBytes(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String _bytesToHex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  group('Cross-stack ASP-2 parity (Dart side of the web golden vector)', () {
    test('Asp2Frame.encode() matches web/asp2-client golden_frame.json', () {
      // The same fixture the web vitest (frame.parity.test.ts) asserts against.
      final file = File('web/asp2-client/test/golden_frame.json');
      expect(file.existsSync(), isTrue,
          reason: 'shared golden vector must exist for both stacks');
      final golden =
          jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      final f = (golden['fields'] as Map).cast<String, dynamic>();

      final frame = Asp2Frame(
        version: f['version'] as int,
        flags: f['flags'] as int,
        codecId: f['codecId'] as int,
        streamId: f['streamId'] as int,
        sequenceNumber: f['sequenceNumber'] as int,
        presentationTsUs: f['presentationTsUs'] as int,
        fecGroupId: f['fecGroupId'] as int,
        fecIndex: f['fecIndex'] as int,
        payload: _hexToBytes(f['payloadHex'] as String),
      );

      // The Dart encoder defines the canonical wire; this proves the fixture
      // (which the TypeScript encoder is tested against) is correct.
      expect(_bytesToHex(frame.encode()), golden['encodedHex'] as String);

      // And the canonical bytes decode back to the same fields.
      final back =
          Asp2Frame.decode(_hexToBytes(golden['encodedHex'] as String));
      expect(back.codecId, frame.codecId);
      expect(back.streamId, frame.streamId);
      expect(back.sequenceNumber, frame.sequenceNumber);
      expect(back.presentationTsUs, frame.presentationTsUs);
      expect(_bytesToHex(back.payload), f['payloadHex'] as String);
    });
  });
}
