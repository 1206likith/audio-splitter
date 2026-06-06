import 'dart:async';
import 'dart:typed_data';

import 'package:audio_splitter_app/plugin_sdk/plugin_sdk.dart';
import 'package:audio_splitter_app/plugin_sdk/sample_plugin.dart';
import 'package:flutter_test/flutter_test.dart';

/// Peak absolute int16 sample in a chunk.
int peak(PcmChunk c) {
  final bd = ByteData.view(c.pcm.buffer, c.pcm.offsetInBytes, c.pcm.length);
  var m = 0;
  for (var i = 0; i < c.pcm.length ~/ 2; i++) {
    final v = bd.getInt16(i * 2, Endian.little).abs();
    if (v > m) m = v;
  }
  return m;
}

/// A plugin built against an incompatible SDK major — must be rejected.
class _FuturePlugin extends AudioPlugin {
  const _FuturePlugin();
  @override
  PluginManifest get manifest => const PluginManifest(
        id: 'com.example.future',
        name: 'Future',
        version: '9.0.0',
        author: 'tomorrow',
        capabilities: {PluginCapability.effect},
        sdkVersion: 99,
      );
}

void main() {
  group('Plugin registry', () {
    test('registers a compatible plugin and exposes it by capability', () {
      final reg = PluginRegistry();
      expect(reg.register(const SampleTonePlugin()), isTrue);
      expect(reg.byId('com.audiosplitter.sample.tone'), isNotNull);
      expect(reg.providing(PluginCapability.source), isNotEmpty);
      expect(reg.providing(PluginCapability.effect), isNotEmpty);
      expect(reg.providing(PluginCapability.sink), isEmpty);
    });

    test('rejects an incompatible-SDK plugin (not a silent load)', () {
      final reg = PluginRegistry();
      expect(reg.register(const _FuturePlugin()), isFalse);
      expect(reg.byId('com.example.future'), isNull);
      expect(reg.rejected.single, contains('targets SDK 99'));
    });

    test('rejects a duplicate id', () {
      final reg = PluginRegistry();
      expect(reg.register(const SampleTonePlugin()), isTrue);
      expect(reg.register(const SampleTonePlugin()), isFalse);
      expect(reg.rejected.single, contains('duplicate'));
    });
  });

  group('Sample plugin', () {
    test('tone source produces the requested chunks', () async {
      const plugin = SampleTonePlugin();
      final source = plugin.createSource('tone', {
        'frequencyHz': 440.0,
        'amplitude': 0.5,
        'chunks': 3,
        'framesPerChunk': 480,
      });
      final got = <PcmChunk>[];
      final done = Completer<void>();
      source.chunks.listen(got.add, onDone: done.complete);
      expect(await source.start(), isTrue);
      await source.stop();
      await done.future;

      expect(got, hasLength(3));
      expect(got.first.format, AudioFormat.voiceMono);
      expect(peak(got.first), greaterThan(0)); // it actually makes sound
    });

    test('gain effect scales by dB and passes identity at 0 dB', () {
      const plugin = SampleTonePlugin();
      final loud = constMono(1000, 256);

      final attenuate = plugin.createEffect('g', {'gainDb': -6.0});
      final out = attenuate.process(loud);
      expect(peak(out), closeTo(501, 3)); // 10^(-6/20) ≈ 0.501

      final identity = plugin.createEffect('g0', {'gainDb': 0.0});
      expect(identical(identity.process(loud), loud), isTrue);
    });

    test('SDK gate — sample plugin source → effect runs through the pipeline',
        () async {
      final reg = PluginRegistry();
      reg.register(const SampleTonePlugin());
      final plugin = reg.byId('com.audiosplitter.sample.tone')!;

      final source = plugin.createSource('tone', {
        'amplitude': 0.8,
        'chunks': 1,
        'framesPerChunk': 480,
      })!;
      final gain = plugin.createEffect('trim', {'gainDb': -12.0})!;

      final got = <PcmChunk>[];
      final done = Completer<void>();
      source.chunks.listen(got.add, onDone: done.complete);
      await source.start();
      await source.stop();
      await done.future;

      final raw = got.single;
      final processed = gain.process(raw);
      expect(peak(processed), lessThan(peak(raw)));

      // ignore: avoid_print
      print('Phase 7 gate (plugin SDK): sample plugin registered (SDK v'
          '$kPluginSdkVersion); ToneSource → GainEffect(-12dB) ran through the '
          'pipeline, peak ${peak(raw)} → ${peak(processed)}.');
    });
  });
}

/// Constant mono chunk helper.
PcmChunk constMono(int value, int frames) {
  const format = AudioFormat.voiceMono;
  final pcm = Uint8List(frames * format.frameBytes);
  final bd = ByteData.view(pcm.buffer);
  for (var f = 0; f < frames; f++) {
    bd.setInt16(f * 2, value, Endian.little);
  }
  return PcmChunk(pcm: pcm, presentationTsUs: 0, format: format);
}
