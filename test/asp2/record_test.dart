import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_splitter_app/asp2/ai/highlight.dart';
import 'package:audio_splitter_app/asp2/record/audio_encoder.dart';
import 'package:audio_splitter_app/asp2/record/daw/ableton_als.dart';
import 'package:audio_splitter_app/asp2/record/daw/reaper_rpp.dart';
import 'package:audio_splitter_app/asp2/record/flac_writer.dart';
import 'package:audio_splitter_app/asp2/record/session_bundle.dart';
import 'package:audio_splitter_app/asp2/record/stem_recorder.dart';
import 'package:audio_splitter_app/asp2/record/wav_writer.dart';
import 'package:audio_splitter_app/asp2/record/zip_writer.dart';
import 'package:audio_splitter_app/core/contracts/audio_format.dart';
import 'package:audio_splitter_app/core/pipeline/audio_chunk.dart';
import 'package:flutter_test/flutter_test.dart';

/// A constant-value interleaved chunk in [format].
PcmChunk constChunk(int value, int frames,
    {AudioFormat format = AudioFormat.cdStereo, int tsUs = 0}) {
  final pcm = Uint8List(frames * format.frameBytes);
  final bd = ByteData.view(pcm.buffer);
  for (var f = 0; f < frames; f++) {
    for (var c = 0; c < format.channels; c++) {
      bd.setInt16((f * format.channels + c) * 2, value, Endian.little);
    }
  }
  return PcmChunk(pcm: pcm, presentationTsUs: tsUs, format: format);
}

/// A ramp chunk (distinct sample values, so FLAC must use VERBATIM).
PcmChunk rampChunk(int frames,
    {AudioFormat format = AudioFormat.cdStereo, int tsUs = 0}) {
  final pcm = Uint8List(frames * format.frameBytes);
  final bd = ByteData.view(pcm.buffer);
  for (var f = 0; f < frames; f++) {
    for (var c = 0; c < format.channels; c++) {
      bd.setInt16(
          (f * format.channels + c) * 2, (f % 1000) - 500, Endian.little);
    }
  }
  return PcmChunk(pcm: pcm, presentationTsUs: tsUs, format: format);
}

/// Read STREAMINFO {sampleRate, channels, bps, totalSamples} from a FLAC buffer.
Map<String, int> readFlacStreamInfo(Uint8List flac) {
  expect(String.fromCharCodes(flac.sublist(0, 4)), 'fLaC');
  final blockType = flac[4] & 0x7f;
  expect(blockType, 0); // STREAMINFO
  final len = (flac[5] << 16) | (flac[6] << 8) | flac[7];
  expect(len, 34);
  final minBlock = (flac[8] << 8) | flac[9];
  final maxBlock = (flac[10] << 8) | flac[11];
  // 64-bit packed field at offset 18: sr(20) ch(3) bps(5) totalSamples(36).
  var packed = 0;
  for (var i = 18; i < 26; i++) {
    packed = (packed << 8) | flac[i];
  }
  final sampleRate = (packed >> 44) & 0xFFFFF;
  final channels = ((packed >> 41) & 0x7) + 1;
  final bps = ((packed >> 36) & 0x1F) + 1;
  final totalSamples = packed & 0xFFFFFFFFF;
  return {
    'minBlock': minBlock,
    'maxBlock': maxBlock,
    'sampleRate': sampleRate,
    'channels': channels,
    'bps': bps,
    'totalSamples': totalSamples,
  };
}

void main() {
  group('WAV writer', () {
    test('header describes the PCM and round-trips length', () {
      const fmt = AudioFormat.cdStereo;
      final h = WavWriter.header(format: fmt, dataBytes: 8000);
      expect(String.fromCharCodes(h.sublist(0, 4)), 'RIFF');
      expect(String.fromCharCodes(h.sublist(8, 12)), 'WAVE');
      final bd = ByteData.view(h.buffer);
      expect(bd.getUint32(4, Endian.little), 36 + 8000);
      expect(bd.getUint16(22, Endian.little), 2); // channels
      expect(bd.getUint32(24, Endian.little), 48000);
      expect(bd.getUint32(40, Endian.little), 8000); // data length
    });

    test('encode = 44-byte header + payload', () {
      final pcm = Uint8List.fromList(List.filled(400, 7));
      final wav = WavWriter.encode(AudioFormat.cdStereo, pcm);
      expect(wav.length, WavWriter.headerBytes + 400);
      expect(wav.sublist(44), pcm);
    });
  });

  group('FLAC writer', () {
    test('emits a valid FLAC stream with correct STREAMINFO', () {
      const fmt = AudioFormat.cdStereo;
      final pcm = rampChunk(10000, format: fmt).pcm;
      final flac = FlacWriter.encode(fmt, pcm);
      final info = readFlacStreamInfo(flac);
      expect(info['sampleRate'], 48000);
      expect(info['channels'], 2);
      expect(info['bps'], 16);
      expect(info['totalSamples'], 10000);
    });

    test('digital silence collapses to CONSTANT subframes (smaller than WAV)',
        () {
      const fmt = AudioFormat.cdStereo;
      final pcm = constChunk(0, 48000, format: fmt).pcm; // 1s of silence
      final flac = FlacWriter.encode(fmt, pcm);
      final wav = WavWriter.encode(fmt, pcm);
      expect(readFlacStreamInfo(flac)['totalSamples'], 48000);
      // CONSTANT subframes store one sample per frame, not 4096.
      expect(flac.length, lessThan(wav.length ~/ 10));
    });
  });

  group('ZIP writer', () {
    test('produces a structurally valid store-mode archive', () {
      final zip = ZipWriter.build([
        ZipEntry.text('a.txt', 'hello'),
        ZipEntry('b.bin', Uint8List.fromList([1, 2, 3, 4])),
      ]);
      final bd = ByteData.view(zip.buffer);
      expect(bd.getUint32(0, Endian.little), 0x04034b50); // local header sig
      // End-of-central-directory: last 22 bytes, total entries == 2.
      final eocd = zip.length - 22;
      expect(bd.getUint32(eocd, Endian.little), 0x06054b50);
      expect(bd.getUint16(eocd + 10, Endian.little), 2);
    });

    test('is deterministic (no wall clock)', () {
      final a = ZipWriter.build([ZipEntry.text('x', 'y')]);
      final b = ZipWriter.build([ZipEntry.text('x', 'y')]);
      expect(a, b);
    });
  });

  group('Encoder registry', () {
    test('lossless encoders are live; lossy ones are deferred scaffolds', () {
      expect(const WavEncoder().isAvailable, isTrue);
      expect(const FlacEncoder().isAvailable, isTrue);
      expect(const Mp3Encoder().isAvailable, isFalse);
      expect(const OggOpusEncoder().isAvailable, isFalse);
      // An unavailable name resolves to the WAV fallback, never a silent skip.
      expect(EncoderRegistry.resolveOrFallback('mp3').name, 'wav');
      expect(EncoderRegistry.resolveOrFallback('flac').name, 'flac');
      expect(EncoderRegistry.available.map((e) => e.name),
          containsAll(<String>['wav', 'flac']));
    });
  });

  group('Session recorder', () {
    test('captures stems independently and time-aligns late joiners', () {
      final rec = SessionRecorder(sessionName: 'set', sessionStartTsUs: 0);
      rec.registerSource('mic', 'Mic');
      rec.registerZone('patio', 'Patio');

      // Mic from t=0 for 1000 frames.
      rec.write('mic', constChunk(100, 1000, tsUs: 0));
      // Patio zone joins late at t=2s.
      rec.write('patio', constChunk(50, 500, tsUs: 2000000));
      rec.write('mic', constChunk(100, 1000, tsUs: 20833));

      final session = rec.stop();
      expect(rec.isRecording, isFalse);
      expect(session.stems, hasLength(2));

      final mic = session.stems.firstWhere((s) => s.spec.id == 'mic');
      final patio = session.stems.firstWhere((s) => s.spec.id == 'patio');
      expect(mic.frames, 2000);
      expect(mic.startOffsetUs, 0);
      expect(patio.frames, 500);
      expect(patio.startOffsetUs, 2000000); // pre-placed 2s in
      expect(patio.startSeconds, closeTo(2.0, 1e-9));
    });
  });

  group('DAW export', () {
    RecordedSession buildSession() {
      final rec = SessionRecorder(sessionName: 'gig', sessionStartTsUs: 0);
      rec.registerSource('mic', 'Lead Vocal');
      rec.registerZone('main', 'Main Mix');
      rec.write('mic', constChunk(200, 48000, tsUs: 0)); // 1s @ t=0
      rec.write('main', constChunk(80, 24000, tsUs: 1000000)); // 0.5s @ t=1s
      return rec.stop();
    }

    test('Reaper .rpp places each stem at its captured offset', () {
      final session = buildSession();
      final rpp = ReaperProject.build(session,
          stemPathFor: (s) => 'stems/${s.baseFileName}.wav');
      expect(rpp, contains('<REAPER_PROJECT'));
      expect(rpp, contains('"Lead Vocal"'));
      expect(rpp, contains('"Main Mix"'));
      expect(rpp, contains('stems/source_mic.wav'));
      expect(rpp, contains('POSITION 1.000000')); // main joined at t=1s
      expect(rpp, contains('LENGTH 1.000000')); // mic is 1s long
    });

    test('Ableton .als XML has one pre-placed AudioTrack per stem', () {
      final session = buildSession();
      final xml = AbletonProject.buildXml(session,
          stemPathFor: (s) => 'stems/${s.baseFileName}.wav', tempo: 120);
      expect('<AudioTrack'.allMatches(xml).length, 2);
      expect(xml, contains('stems/source_mic.wav'));
      expect(xml, contains('stems/zoneMix_main.wav'));
      // Main mix at 1s @120bpm = 2 beats.
      expect(xml, contains('<CurrentStart Value="2.000000"/>'));
    });

    test('Ableton .als gzips and round-trips', () {
      final session = buildSession();
      final als = AbletonProject.encode(session,
          stemPathFor: (s) => 'stems/${s.baseFileName}.wav');
      expect(als[0], 0x1f); // gzip magic
      expect(als[1], 0x8b);
      final xml = utf8.decode(gzip.decode(als));
      expect(xml, contains('<Ableton'));
    });
  });

  group('Phase 7 gate — recording (session opens with stems pre-placed)', () {
    test('multitrack session bundles stems + DAW projects, pre-placed', () {
      // Record a 3-stem session: two sources + one zone mix, with a late joiner.
      final rec = SessionRecorder(sessionName: 'Live Set', sessionStartTsUs: 0);
      rec.registerSource('dj', 'DJ Deck');
      rec.registerSource('mic', 'Host Mic');
      rec.registerZone('floor', 'Dance Floor');

      rec.write('dj', constChunk(300, 96000, tsUs: 0)); // 2s from start
      rec.write('floor', constChunk(120, 96000, tsUs: 0)); // 2s from start
      rec.write('mic', constChunk(200, 48000, tsUs: 1000000)); // joins at 1s

      final session = rec.stop();
      const highlights = [
        HighlightClip(startTsUs: 500000, endTsUs: 1500000, peakEnergy: 0.95),
      ];

      // Stems are pre-placed on the timeline.
      final manifest = SessionBundle.manifest(session, highlights: highlights);
      final stems = (manifest['stems'] as List).cast<Map<String, dynamic>>();
      expect(stems, hasLength(3));
      final mic = stems.firstWhere((s) => s['id'] == 'mic');
      expect(mic['startSeconds'], closeTo(1.0, 1e-9)); // placed 1s in
      expect((manifest['highlights'] as List), hasLength(1));

      // The DAW projects agree on that placement.
      final rpp = ReaperProject.build(session,
          stemPathFor: (s) => SessionBundle.stemPath(s, const WavEncoder()));
      expect(rpp, contains('POSITION 1.000000'));
      final xml = AbletonProject.buildXml(session,
          stemPathFor: (s) => SessionBundle.stemPath(s, const WavEncoder()));
      expect(xml, contains('<CurrentStart Value="2.000000"/>')); // 1s @120bpm

      // The full bundle is a valid archive containing every stem + projects.
      final zip = SessionBundle.build(session,
          stemEncoder: const FlacEncoder(), highlights: highlights);
      final bd = ByteData.view(zip.buffer);
      expect(bd.getUint32(0, Endian.little), 0x04034b50);
      final eocd = zip.length - 22;
      expect(bd.getUint32(eocd, Endian.little), 0x06054b50);
      // 3 stems + .rpp + .als + manifest.json = 6 entries.
      expect(bd.getUint16(eocd + 10, Endian.little), 6);

      // ignore: avoid_print
      print('Phase 7 gate (recording): 3-stem session bundled — '
          'DJ/floor at 0.0s, mic pre-placed at 1.0s; Reaper POSITION + Ableton '
          'CurrentStart agree; ${zip.length}B zip with 6 entries '
          '(FLAC stems + .rpp + .als + manifest).');
    });
  });
}
