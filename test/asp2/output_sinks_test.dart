// Output-sink contract tests for the two Bluetooth output paths (v2 Phase 4):
// classic A2DP (one paired device) and LE Audio / Auracast broadcast (one
// stream, many receivers — the v2 differentiator).
//
// The real hardware routes are deferred behind [needs-hardware] seams, so these
// tests exercise the pure contract logic in simulate mode plus the graceful
// unavailable path when a real route is requested without hardware. This closes
// the audit gap that BtA2dpSink shipped with no test at all.

import 'dart:typed_data';

import 'package:audio_splitter_app/asp2/sinks/bt_a2dp_sink.dart';
import 'package:audio_splitter_app/asp2/sinks/le_audio_broadcast_sink.dart';
import 'package:audio_splitter_app/core/contracts/audio_format.dart';
import 'package:audio_splitter_app/core/pipeline/audio_chunk.dart';
import 'package:flutter_test/flutter_test.dart';

PcmChunk chunk(int tsUs, {int bytes = 3840}) => PcmChunk(
      pcm: Uint8List(bytes),
      presentationTsUs: tsUs,
      format: AudioFormat.cdStereo,
    );

void main() {
  group('BtA2dpSink (A2DP, one device)', () {
    test('simulate mode opens, accounts for writes, and closes', () async {
      final sink = BtA2dpSink(deviceId: 'JBL-Flip', simulate: true);
      expect(await sink.open(AudioFormat.cdStereo), isTrue);
      expect(sink.isOpen, isTrue);
      sink.write(chunk(0));
      sink.write(chunk(20000));
      expect(sink.chunksWritten, 2);
      expect(sink.bytesWritten, 3840 * 2);
      expect(sink.lastTsUs, 20000);
      await sink.close();
      expect(sink.isOpen, isFalse);
    });

    test('writes before open are tolerated (no throw, no accounting)', () {
      final sink = BtA2dpSink(deviceId: 'x', simulate: true);
      sink.write(chunk(0)); // not open yet
      expect(sink.chunksWritten, 0);
    });

    test('real route unavailable without hardware: open false + reason',
        () async {
      final sink = BtA2dpSink(deviceId: 'JBL-Flip', simulate: false);
      expect(await sink.open(AudioFormat.cdStereo), isFalse);
      expect(sink.isOpen, isFalse);
      expect(sink.unavailableReason, isNotNull);
      expect(sink.unavailableReason, contains('JBL-Flip'));
      // Writing after a failed open is still safe.
      sink.write(chunk(0));
      expect(sink.chunksWritten, 0);
    });
  });

  group('LeAudioBroadcastSink (Auracast, one stream → many receivers)', () {
    test('simulate mode opens, accounts for broadcasts, and closes', () async {
      final sink =
          LeAudioBroadcastSink(broadcastName: 'MyParty', simulate: true);
      expect(await sink.open(AudioFormat.cdStereo), isTrue);
      expect(sink.isOpen, isTrue);
      sink.write(chunk(0));
      sink.write(chunk(20000));
      sink.write(chunk(40000));
      expect(sink.chunksBroadcast, 3);
      expect(sink.bytesBroadcast, 3840 * 3);
      expect(sink.lastTsUs, 40000);
      await sink.close();
      expect(sink.isOpen, isFalse);
    });

    test('writes before open are tolerated', () {
      final sink = LeAudioBroadcastSink(simulate: true);
      sink.write(chunk(0));
      expect(sink.chunksBroadcast, 0);
    });

    test('real broadcast unavailable without hardware: open false + reason',
        () async {
      final sink =
          LeAudioBroadcastSink(broadcastName: 'MyParty', simulate: false);
      expect(await sink.open(AudioFormat.cdStereo), isFalse);
      expect(sink.isOpen, isFalse);
      expect(sink.unavailableReason, isNotNull);
      expect(sink.unavailableReason, contains('MyParty'));
      expect(sink.unavailableReason, contains('LC3'));
    });

    test('default broadcast name and id are sensible', () {
      final sink = LeAudioBroadcastSink();
      expect(sink.broadcastName, 'AudioSplitter');
      expect(sink.id, 'le-audio-broadcast');
    });
  });
}
