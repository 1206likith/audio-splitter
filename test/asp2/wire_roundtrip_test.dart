// Full-path ASP-2 wire round-trip: the headless proof that the encrypted,
// framed, coded wire survives a complete send -> receive cycle WITHOUT needing
// two physical devices.
//
// The individual layers (codec, AEAD, frame, X25519 handshake) each have their
// own unit tests. This test is the one that chains ALL of them exactly the way
// a real host->client session does, so that flipping `Asp2Config.useAsp2Wire`
// on a real 2-device pair is backed by an automated end-to-end proof rather
// than a leap of faith.
//
// Sender path:  PCM16 -> ICodec.encode -> AeadBox.seal(aad = frame header)
//               -> Asp2Frame(payload = ciphertext, tag = mac, nonce).encode()
//               -> wire bytes
// Receiver path: wire bytes -> Asp2Frame.decode -> AeadBox.open(aad = header)
//               -> ICodec.decode -> PCM16
//
// The key crosses via a real two-party X25519 ECDH + HKDF handshake (both sides
// derive the same 32-byte session key), so this also proves the handshake feeds
// the AEAD correctly.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audio_splitter_app/asp2/codec/pcm16_codec.dart';
import 'package:audio_splitter_app/asp2/codec/opus_codec.dart';
import 'package:audio_splitter_app/asp2/crypto/aead_box.dart';
import 'package:audio_splitter_app/asp2/crypto/key_exchange.dart';
import 'package:audio_splitter_app/asp2/frame/asp2_frame.dart';
import 'package:audio_splitter_app/core/contracts/i_codec.dart';
import 'package:flutter_test/flutter_test.dart';

/// 20 ms of stereo 440 Hz sine as PCM16 @ 48 kHz — one Opus frame worth.
Uint8List sineFrame({int channels = 2, double freq = 440}) {
  const n = OpusCodec.samplesPerChannel;
  final out = Uint8List(n * channels * 2);
  final bd = ByteData.view(out.buffer);
  for (int i = 0; i < n; i++) {
    final s =
        (math.sin(2 * math.pi * freq * i / OpusCodec.sampleRate) * 20000)
            .round();
    for (int c = 0; c < channels; c++) {
      bd.setInt16((i * channels + c) * 2, s, Endian.little);
    }
  }
  return out;
}

/// Normalised cross-correlation of two PCM16 buffers (1.0 == identical shape).
double correlation(Uint8List a, Uint8List b) {
  final n = math.min(a.length, b.length) ~/ 2;
  final va = ByteData.view(a.buffer, a.offsetInBytes);
  final vb = ByteData.view(b.buffer, b.offsetInBytes);
  double sa = 0, sb = 0, saa = 0, sbb = 0, sab = 0;
  for (int i = 0; i < n; i++) {
    final x = va.getInt16(i * 2, Endian.little).toDouble();
    final y = vb.getInt16(i * 2, Endian.little).toDouble();
    sa += x;
    sb += y;
    saa += x * x;
    sbb += y * y;
    sab += x * y;
  }
  final cov = sab - sa * sb / n;
  final da = math.sqrt(saa - sa * sa / n);
  final db = math.sqrt(sbb - sb * sb / n);
  if (da == 0 || db == 0) return 0;
  return cov / (da * db);
}

/// Establish a shared 32-byte session key via a real two-party X25519 + HKDF
/// handshake and install it into a sender box and a receiver box.
Future<(Asp2AeadBox, Asp2AeadBox)> handshakeBoxes() async {
  final host = await SessionHandshake.generate();
  final client = await SessionHandshake.generate();
  final hostKey = await host.deriveSessionKey(await client.ephemeralPublicKey());
  final clientKey =
      await client.deriveSessionKey(await host.ephemeralPublicKey());
  // Both sides MUST derive the identical key or the wire cannot work.
  expect(hostKey, clientKey, reason: 'handshake must converge on one key');
  return (Asp2AeadBox()..setKey(hostKey), Asp2AeadBox()..setKey(clientKey));
}

/// Send one PCM frame across the full ASP-2 wire and return what the receiver
/// decodes back. `sender`/`receiver` use the same codec_id on the wire.
Future<Uint8List> sendReceive(
  Uint8List pcm,
  ICodec sender,
  ICodec receiver,
  Asp2AeadBox sendBox,
  Asp2AeadBox recvBox, {
  required int seq,
}) async {
  // ---- SENDER ----
  final payload = sender.encode(pcm);
  final ptsUs = seq * 20000; // 20 ms per frame
  // The header authenticates the ciphertext (used as AEAD AAD), so build the
  // plaintext frame first to obtain its exact header bytes.
  final headerFrame = Asp2Frame(
    flags: Asp2Frame.flagEncrypted,
    codecId: sender.codecId,
    sequenceNumber: seq,
    presentationTsUs: ptsUs,
    payload: payload,
    tag: Uint8List(Asp2Frame.tagSize),
    nonce: Uint8List(Asp2Frame.nonceSize),
  );
  final aad = headerFrame.encodeHeader();
  final nonce = Uint8List(Asp2Frame.nonceSize);
  // Fold the sequence number into the nonce so it is unique per frame.
  ByteData.view(nonce.buffer).setUint32(0, seq, Endian.little);

  final sealed = await sendBox.seal(plaintext: payload, aad: aad, nonce: nonce);
  expect(sealed, isNotNull, reason: 'seal must succeed when a key is installed');

  final wire = Asp2Frame(
    flags: Asp2Frame.flagEncrypted,
    codecId: sender.codecId,
    sequenceNumber: seq,
    presentationTsUs: ptsUs,
    payload: sealed!.ciphertext,
    tag: sealed.mac,
    nonce: nonce,
  ).encode();

  // ---- WIRE (opaque bytes, as if sent over the transport) ----
  final received = Uint8List.fromList(wire);

  // ---- RECEIVER ----
  final frame = Asp2Frame.decode(received);
  expect(frame.codecId, sender.codecId);
  // Reconstruct the AAD the receiver must verify against: the header with the
  // payload-length of the (known-length) plaintext, tag/nonce zeroed — exactly
  // how the sender built the AAD.
  final recvHeaderAad = Asp2Frame(
    flags: Asp2Frame.flagEncrypted,
    codecId: frame.codecId,
    sequenceNumber: frame.sequenceNumber,
    presentationTsUs: frame.presentationTsUs,
    payload: Uint8List(payload.length),
    tag: Uint8List(Asp2Frame.tagSize),
    nonce: Uint8List(Asp2Frame.nonceSize),
  ).encodeHeader();

  final opened = await recvBox.open(
    ciphertext: frame.payload,
    mac: frame.tag!,
    aad: recvHeaderAad,
    nonce: frame.nonce!,
  );
  expect(opened, isNotNull, reason: 'open must succeed on an untampered frame');
  return receiver.decode(opened!);
}

void main() {
  group('ASP-2 full wire round-trip (PCM16 codec)', () {
    test('one frame survives encode -> encrypt -> frame -> decrypt -> decode',
        () async {
      final (sendBox, recvBox) = await handshakeBoxes();
      final pcm = sineFrame();
      final out = await sendReceive(
        pcm,
        Pcm16Codec(),
        Pcm16Codec(),
        sendBox,
        recvBox,
        seq: 0,
      );
      // PCM16 is lossless through the wire: bytes must match exactly.
      expect(out, pcm);
    });

    test('a stream of frames all round-trip with advancing sequence numbers',
        () async {
      final (sendBox, recvBox) = await handshakeBoxes();
      for (int seq = 0; seq < 8; seq++) {
        final pcm = sineFrame(freq: 220.0 + seq * 55);
        final out = await sendReceive(
          pcm,
          Pcm16Codec(),
          Pcm16Codec(),
          sendBox,
          recvBox,
          seq: seq,
        );
        expect(out, pcm, reason: 'frame $seq must survive the wire');
      }
    });

    test('a tampered ciphertext is rejected (wire does NOT fail open)',
        () async {
      final (sendBox, recvBox) = await handshakeBoxes();
      final pcm = sineFrame();
      final payload = Pcm16Codec().encode(pcm);
      final aad = Asp2Frame(
        flags: Asp2Frame.flagEncrypted,
        codecId: CodecId.pcm16,
        sequenceNumber: 3,
        presentationTsUs: 60000,
        payload: payload,
        tag: Uint8List(Asp2Frame.tagSize),
        nonce: Uint8List(Asp2Frame.nonceSize),
      ).encodeHeader();
      final nonce = Uint8List(Asp2Frame.nonceSize)..[0] = 3;
      final sealed =
          await sendBox.seal(plaintext: payload, aad: aad, nonce: nonce);
      final tampered = Uint8List.fromList(sealed!.ciphertext);
      tampered[0] ^= 0xFF; // flip a bit on the wire

      final opened = await recvBox.open(
        ciphertext: tampered,
        mac: sealed.mac,
        aad: aad,
        nonce: nonce,
      );
      expect(opened, isNull, reason: 'AEAD must reject a tampered frame');
    });
  });

  group('ASP-2 full wire round-trip (Opus codec, when libopus present)', () {
    test('Opus leg round-trips with high audio correlation, or skips cleanly',
        () async {
      final send = OpusCodec.tryCreate();
      final recv = OpusCodec.tryCreate();
      if (send == null || recv == null) {
        // No native libopus in this environment: the codec degrades to PCM16
        // by design (see third_party/README.md). The PCM16 group above already
        // proves the wire; skip the Opus-specific leg rather than fail.
        markTestSkipped('libopus not available; Opus leg skipped by design');
        return;
      }
      final (sendBox, recvBox) = await handshakeBoxes();
      final pcm = sineFrame();
      final out = await sendReceive(
        pcm,
        send,
        recv,
        sendBox,
        recvBox,
        seq: 0,
      );
      // Opus is lossy: assert the recovered waveform strongly correlates with
      // the original rather than being byte-identical.
      expect(correlation(out, pcm), greaterThan(0.7));
      send.dispose();
      recv.dispose();
    });
  });
}
