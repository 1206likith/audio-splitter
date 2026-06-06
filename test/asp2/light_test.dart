import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audio_splitter_app/core/contracts/audio_format.dart';
import 'package:audio_splitter_app/core/pipeline/audio_chunk.dart';
import 'package:audio_splitter_app/asp2/light/ambient.dart';
import 'package:audio_splitter_app/asp2/light/dmx.dart';
import 'package:audio_splitter_app/asp2/light/hue.dart';
import 'package:audio_splitter_app/asp2/light/lifx.dart';
import 'package:audio_splitter_app/asp2/light/light_controller.dart';
import 'package:audio_splitter_app/asp2/sinks/haptic_sink.dart';
import 'package:flutter_test/flutter_test.dart';

PcmChunk sineChunk({
  required double freqHz,
  required double amp,
  required int frames,
  int tsUs = 0,
  AudioFormat format = AudioFormat.cdStereo,
}) {
  final pcm = Uint8List(frames * format.frameBytes);
  final bd = ByteData.view(pcm.buffer);
  for (var f = 0; f < frames; f++) {
    final t = f / format.sampleRate;
    final s = (amp * math.sin(2 * math.pi * freqHz * t) * 32000).round();
    for (var c = 0; c < format.channels; c++) {
      bd.setInt16((f * format.channels + c) * 2, s, Endian.little);
    }
  }
  return PcmChunk(pcm: pcm, presentationTsUs: tsUs, format: format);
}

void main() {
  group('RgbColor', () {
    test('hsv primaries and dim/lerp', () {
      expect(RgbColor.fromHsv(0, 1, 1), const RgbColor(255, 0, 0));
      expect(RgbColor.fromHsv(120, 1, 1), const RgbColor(0, 255, 0));
      expect(RgbColor.fromHsv(240, 1, 1), const RgbColor(0, 0, 255));
      expect(
          const RgbColor(200, 100, 50).dim(0.5), const RgbColor(100, 50, 25));
      expect(RgbColor.black.lerp(RgbColor.white, 0.5),
          const RgbColor(128, 128, 128));
    });

    test('json round-trip', () {
      const c = RgbColor(12, 34, 56);
      expect(RgbColor.fromJson(c.toJson()), c);
    });
  });

  group('SimulatedLightController', () {
    test('records frames after open', () async {
      final c = SimulatedLightController();
      expect(c.isOpen, isFalse);
      await c.open();
      c.send(LightFrame.solid(const RgbColor(10, 20, 30), fixtureCount: 2));
      expect(c.frameCount, 1);
      expect(c.lastFrame!.colorOf(1), const RgbColor(10, 20, 30));
    });
  });

  group('Art-Net (DMX) golden bytes', () {
    test('ArtDmx header + data layout', () {
      final u = DmxUniverse(universe: 0)
        ..setRgb(0, const RgbColor(255, 128, 64));
      final pkt = ArtNetPacket.buildArtDmx(u, sequence: 7);
      // "Art-Net\0"
      expect(pkt.sublist(0, 8),
          equals([0x41, 0x72, 0x74, 0x2D, 0x4E, 0x65, 0x74, 0x00]));
      expect([pkt[8], pkt[9]], equals([0x00, 0x50])); // opcode LE = 0x5000
      expect([pkt[10], pkt[11]], equals([0x00, 0x0E])); // protver 14 BE
      expect(pkt[12], 7); // sequence
      expect(pkt[13], 0); // physical
      expect(pkt[14], 0); // sub-uni
      expect(pkt[15], 0); // net
      expect([pkt[16], pkt[17]], equals([0x02, 0x00])); // length 512 BE
      expect([pkt[18], pkt[19], pkt[20]], equals([255, 128, 64])); // RGB
      expect(pkt.length, 18 + 512);
    });

    test('DmxUniverse.applyFrame folds in the master dimmer', () {
      final u = DmxUniverse();
      u.applyFrame(const LightFrame(
        fixtures: [FixtureColor(0, RgbColor(200, 100, 50))],
        masterDimmer: 0.5,
      ));
      expect(
          [u.channels[0], u.channels[1], u.channels[2]], equals([100, 50, 25]));
    });

    test('ArtNetSender is a deferred scaffold but builds packets', () async {
      expect(ArtNetSender.isAvailable, isFalse);
      final s = ArtNetSender();
      expect(await s.open(), isFalse);
      s.send(LightFrame.solid(const RgbColor(1, 2, 3)));
      expect(s.lastPacket, isNotNull);
      expect(s.lastPacket!.sublist(0, 7), equals('Art-Net'.codeUnits));
    });
  });

  group('Hue Entertainment frame', () {
    test('builds a HueStream message with 16-bit colour', () {
      final pkt = HueEntertainmentFrame.build(
        LightFrame.solid(const RgbColor(255, 0, 0)),
        configId: '0123456789abcdef0123456789abcdef0123', // 36 chars
        sequence: 3,
      );
      expect(String.fromCharCodes(pkt.sublist(0, 9)), 'HueStream');
      expect([pkt[9], pkt[10]], equals([0x02, 0x00])); // version
      expect(pkt[11], 3); // sequence
      // After 16-byte header + 36-byte config id: channel id then RGB16.
      const off = 16 + 36;
      expect(pkt[off], 0); // fixture id 0
      expect([pkt[off + 1], pkt[off + 2]], equals([0xFF, 0xFF])); // R = 65535
      expect([pkt[off + 3], pkt[off + 4]], equals([0x00, 0x00])); // G = 0
    });

    test('HueBridge deferred', () {
      expect(HueBridge.isAvailable, isFalse);
    });
  });

  group('LIFX LAN packet', () {
    test('SetColor header size and message type', () {
      final pkt = LifxPacket.buildSetColor(const RgbColor(255, 255, 255),
          sequence: 5, durationMs: 200);
      final bd = ByteData.view(pkt.buffer);
      expect(pkt.length, 49); // 36 header + 13 payload
      expect(bd.getUint16(0, Endian.little), 49); // size field
      expect(bd.getUint16(32, Endian.little), 102); // type = SetColor
      expect(pkt[23], 5); // sequence
      // White ⇒ saturation 0, brightness full.
      expect(bd.getUint16(39, Endian.little), 0); // saturation
      expect(bd.getUint16(41, Endian.little), 65535); // brightness
    });

    test('LifxLight deferred but builds packets', () async {
      expect(LifxLight.isAvailable, isFalse);
      final l = LifxLight();
      expect(await l.open(), isFalse);
      l.send(LightFrame.solid(const RgbColor(0, 255, 0)));
      expect(l.lastPacket, isNotNull);
      expect(l.lastPacket!.length, 49);
    });
  });

  group('Ambient screen colour', () {
    test('warmer and brighter as energy rises', () {
      final calm = AmbientColor.forEnergy(0.0);
      final peak = AmbientColor.forEnergy(1.0);
      // Calm leans blue, peak leans red.
      expect(calm.b, greaterThan(calm.r));
      expect(peak.r, greaterThan(peak.b));
      // Peak is brighter overall.
      expect(peak.r + peak.g + peak.b, greaterThan(calm.r + calm.g + calm.b));
    });
  });

  group('HapticSink (bass → vibration)', () {
    test('emits a pulse on a bass onset (simulate)', () async {
      final sink = HapticSink();
      expect(await sink.open(AudioFormat.cdStereo), isTrue);
      // Silence first (sets the energy floor), then a loud sub-bass tone.
      sink.write(sineChunk(freqHz: 50, amp: 0.0, frames: 4800, tsUs: 0));
      sink.write(sineChunk(freqHz: 50, amp: 0.8, frames: 4800, tsUs: 100000));
      expect(sink.pulses, isNotEmpty);
      expect(sink.pulses.first.intensity, greaterThan(0.0));
    });

    test('real mode is unavailable and names the reason', () async {
      final sink = HapticSink(simulate: false);
      expect(HapticSink.isAvailable, isFalse);
      expect(await sink.open(AudioFormat.cdStereo), isFalse);
      expect(sink.unavailableReason, isNotNull);
    });
  });
}
