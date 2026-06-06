import 'dart:typed_data';

import 'package:audio_splitter_app/asp2/frame/asp2_frame.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Uint8List bytes(List<int> v) => Uint8List.fromList(v);

  group('Asp2Frame plaintext', () {
    test('header is exactly 20 bytes with correct field layout', () {
      final frame = Asp2Frame(
        codecId: 1,
        streamId: 0x0102,
        sequenceNumber: 0x0A0B0C0D,
        presentationTsUs: 0x0102030405060708,
        fecGroupId: 7,
        fecIndex: 3,
        payload: bytes([1, 2, 3, 4]),
      );
      final header = frame.encodeHeader();
      expect(header.length, Asp2Frame.headerSize);

      final bd = ByteData.view(header.buffer);
      // version 2 in high nibble, flags 0 in low nibble.
      expect(bd.getUint8(0), 0x20);
      expect(bd.getUint8(1), 1); // codec_id
      expect(bd.getUint16(2, Endian.little), 0x0102); // stream_id
      expect(bd.getUint32(4, Endian.little), 0x0A0B0C0D); // seq
      expect(bd.getUint64(8, Endian.little), 0x0102030405060708); // pts_us
      expect(bd.getUint16(16, Endian.little), 4); // payload_len
      expect(bd.getUint8(18), 7); // fec_group_id
      expect(bd.getUint8(19), 3); // fec_index
    });

    test('round-trips through encode/decode', () {
      final frame = Asp2Frame(
        codecId: 0,
        streamId: 42,
        sequenceNumber: 99,
        presentationTsUs: 1234567890123,
        payload: bytes(List<int>.generate(256, (i) => i & 0xFF)),
      );
      final decoded = Asp2Frame.decode(frame.encode());
      expect(decoded.version, frame.version);
      expect(decoded.codecId, frame.codecId);
      expect(decoded.streamId, frame.streamId);
      expect(decoded.sequenceNumber, frame.sequenceNumber);
      expect(decoded.presentationTsUs, frame.presentationTsUs);
      expect(decoded.payload, frame.payload);
      expect(decoded.isEncrypted, isFalse);
    });

    test('handles empty and max-length payloads', () {
      for (final len in [0, 1, 1500, 0xFFFF]) {
        final frame = Asp2Frame(
          codecId: 0,
          sequenceNumber: len,
          presentationTsUs: len * 1000,
          payload: Uint8List(len),
        );
        final decoded = Asp2Frame.decode(frame.encode());
        expect(decoded.payload.length, len);
        expect(decoded.sequenceNumber, len);
      }
    });
  });

  group('Asp2Frame encrypted', () {
    test('round-trips with tag + nonce trailer', () {
      final frame = Asp2Frame(
        flags: Asp2Frame.flagEncrypted,
        codecId: 1,
        sequenceNumber: 7,
        presentationTsUs: 555,
        payload: bytes(List<int>.generate(64, (i) => 255 - i)),
        tag: Uint8List.fromList(List<int>.filled(Asp2Frame.tagSize, 0xAB)),
        nonce: Uint8List.fromList(List<int>.filled(Asp2Frame.nonceSize, 0xCD)),
      );
      final wire = frame.encode();
      expect(
        wire.length,
        Asp2Frame.headerSize + 64 + Asp2Frame.tagSize + Asp2Frame.nonceSize,
      );
      final decoded = Asp2Frame.decode(wire);
      expect(decoded.isEncrypted, isTrue);
      expect(decoded.payload, frame.payload);
      expect(decoded.tag, frame.tag);
      expect(decoded.nonce, frame.nonce);
    });

    test('encrypted frame without tag/nonce throws on encode', () {
      final frame = Asp2Frame(
        flags: Asp2Frame.flagEncrypted,
        codecId: 1,
        sequenceNumber: 1,
        presentationTsUs: 1,
        payload: bytes([1, 2, 3]),
      );
      expect(frame.encode, throwsStateError);
    });
  });

  group('Asp2Frame error handling', () {
    test('throws on buffer shorter than header', () {
      expect(() => Asp2Frame.decode(Uint8List(10)), throwsFormatException);
    });

    test('throws when payload_len exceeds available bytes', () {
      final frame = Asp2Frame(
        codecId: 0,
        sequenceNumber: 1,
        presentationTsUs: 1,
        payload: bytes([1, 2, 3, 4, 5, 6, 7, 8]),
      );
      final wire = frame.encode();
      // Truncate one payload byte → decode must reject.
      final truncated = Uint8List.sublistView(wire, 0, wire.length - 1);
      expect(() => Asp2Frame.decode(truncated), throwsFormatException);
    });
  });
}
