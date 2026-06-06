import 'dart:typed_data';

import 'package:audio_splitter_app/asp2/sources/wav_file_source.dart';
import 'package:flutter_test/flutter_test.dart';

/// Build a minimal PCM16 WAV in memory: 44-byte canonical header + [dataBytes]
/// of ramp data. Mirrors RecordingService's header layout.
Uint8List buildWav({
  int sampleRate = 48000,
  int channels = 2,
  required int dataBytes,
}) {
  final h = ByteData(44);
  // "RIFF"
  h.setUint8(0, 0x52);
  h.setUint8(1, 0x49);
  h.setUint8(2, 0x46);
  h.setUint8(3, 0x46);
  h.setUint32(4, 36 + dataBytes, Endian.little);
  // "WAVE"
  h.setUint8(8, 0x57);
  h.setUint8(9, 0x41);
  h.setUint8(10, 0x56);
  h.setUint8(11, 0x45);
  // "fmt "
  h.setUint8(12, 0x66);
  h.setUint8(13, 0x6D);
  h.setUint8(14, 0x74);
  h.setUint8(15, 0x20);
  h.setUint32(16, 16, Endian.little);
  h.setUint16(20, 1, Endian.little); // PCM
  h.setUint16(22, channels, Endian.little);
  h.setUint32(24, sampleRate, Endian.little);
  h.setUint32(28, sampleRate * channels * 2, Endian.little);
  h.setUint16(32, channels * 2, Endian.little);
  h.setUint16(34, 16, Endian.little); // bits per sample
  // "data"
  h.setUint8(36, 0x64);
  h.setUint8(37, 0x61);
  h.setUint8(38, 0x74);
  h.setUint8(39, 0x61);
  h.setUint32(40, dataBytes, Endian.little);

  final out = Uint8List(44 + dataBytes);
  out.setRange(0, 44, h.buffer.asUint8List());
  for (int i = 0; i < dataBytes; i++) {
    out[44 + i] = i & 0xFF;
  }
  return out;
}

void main() {
  group('WavPcmData.parse', () {
    test('rejects buffers shorter than a header', () {
      expect(WavPcmData.parse(Uint8List(10)), isNull);
    });

    test('rejects a non-RIFF buffer', () {
      final wav = buildWav(dataBytes: 100);
      wav[0] = 0x00; // corrupt the RIFF magic
      expect(WavPcmData.parse(wav), isNull);
    });

    test('rejects non-16-bit PCM', () {
      final wav = buildWav(dataBytes: 100);
      ByteData.view(wav.buffer).setUint16(34, 8, Endian.little); // 8-bit
      expect(WavPcmData.parse(wav), isNull);
    });

    test('reads format and locates the data chunk', () {
      final wav = buildWav(sampleRate: 44100, channels: 1, dataBytes: 100);
      final parsed = WavPcmData.parse(wav)!;
      expect(parsed.format.sampleRate, 44100);
      expect(parsed.format.channels, 1);
      expect(parsed.format.bitDepth, 16);
      expect(parsed.dataOffset, 44);
    });
  });

  group('WavPcmData.sliceChunks', () {
    test('splits on v1 100ms boundaries with a final remainder', () {
      // 48k stereo: bytesPerMs = 48000*2*2/1000 = 192; chunkSize = 19200.
      const dataBytes = 19200 * 2 + 100; // two full chunks + 100-byte tail
      final wav = buildWav(dataBytes: dataBytes);
      final chunks = WavPcmData.parse(wav)!.sliceChunks(chunkMs: 100);
      expect(chunks.map((c) => c.length).toList(), [19200, 19200, 100]);
    });

    test('concatenated chunks equal the original PCM payload', () {
      const dataBytes = 5000;
      final wav = buildWav(dataBytes: dataBytes);
      final parsed = WavPcmData.parse(wav)!;
      final chunks = parsed.sliceChunks(chunkMs: 100);
      final joined = <int>[];
      for (final c in chunks) {
        joined.addAll(c);
      }
      expect(joined, wav.sublist(parsed.dataOffset));
    });
  });

  group('WavFileSource', () {
    test('start() returns false for an invalid WAV', () async {
      final source = WavFileSource.fromBytes(Uint8List(10));
      expect(source.isValid, isFalse);
      expect(await source.start(), isFalse);
      expect(source.isActive, isFalse);
      await source.dispose();
    });

    test('streams PcmChunks while active, then stops', () async {
      final wav = buildWav(dataBytes: 4000);
      final source = WavFileSource.fromBytes(wav, chunkMs: 10);
      expect(source.isValid, isTrue);
      expect(source.format.channels, 2);

      final first = source.chunks.first;
      expect(await source.start(), isTrue);
      expect(source.isActive, isTrue);

      final chunk = await first.timeout(const Duration(seconds: 2));
      expect(chunk.pcm, isNotEmpty);
      expect(chunk.format.sampleRate, 48000);

      await source.stop();
      expect(source.isActive, isFalse);
      await source.dispose();
    });
  });
}
