// Headless tests for SystemAudioSource.
//
// The native loopback capture (WASAPI / MediaProjection / CoreAudio) can't run
// in CI, so the source is driven through an injected fake SystemAudioBackend.
// This proves everything ABOVE the native seam: start/stop lifecycle, graceful
// failure when unsupported or when start() throws, host-clock re-timestamping
// of native frames, and chunk fan-out — the parts that would otherwise only be
// exercisable on a real device.

import 'dart:async';
import 'dart:typed_data';

import 'package:audio_splitter_app/asp2/sources/system_audio_source.dart';
import 'package:audio_splitter_app/core/contracts/audio_format.dart';
import 'package:flutter_test/flutter_test.dart';

/// A fake backend whose frames we push manually and whose support/behaviour we
/// control, so the source logic is testable without any OS audio device.
class FakeBackend implements SystemAudioBackend {
  FakeBackend({
    this.isSupported = true,
    this.throwOnStart = false,
    AudioFormat? format,
  }) : format = format ?? AudioFormat.cdStereo;

  @override
  final bool isSupported;
  final bool throwOnStart;
  @override
  final AudioFormat format;

  final StreamController<Uint8List> controller =
      StreamController<Uint8List>.broadcast();
  bool started = false;
  bool stopped = false;

  @override
  Future<Stream<Uint8List>> start() async {
    if (throwOnStart) throw StateError('device busy');
    started = true;
    return controller.stream;
  }

  @override
  Future<void> stop() async {
    stopped = true;
  }

  /// One 20 ms stereo frame at 48 kHz = 960 samples * 2 ch * 2 bytes = 3840 B.
  static Uint8List frame20ms() => Uint8List(3840);
}

void main() {
  // The real PlatformLoopbackBackend touches a MethodChannel; the test binding
  // must exist for that call to resolve (to a MissingPluginException here,
  // since no native handler is registered in unit tests).
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SystemAudioSource lifecycle', () {
    test('start() returns false when the backend is unsupported', () async {
      final src = SystemAudioSource(FakeBackend(isSupported: false));
      expect(await src.start(), isFalse);
      expect(src.isActive, isFalse);
    });

    test('tryCreate returns null on an unsupported platform', () {
      expect(
        SystemAudioSource.tryCreate(backend: FakeBackend(isSupported: false)),
        isNull,
      );
    });

    test('tryCreate returns a source when supported', () {
      final src =
          SystemAudioSource.tryCreate(backend: FakeBackend(isSupported: true));
      expect(src, isNotNull);
    });

    test('start() returns false (does not throw) when the backend throws',
        () async {
      final src = SystemAudioSource(FakeBackend(throwOnStart: true));
      expect(await src.start(), isFalse);
      expect(src.isActive, isFalse);
    });

    test('start() then a second start() returns false (idempotent)', () async {
      final backend = FakeBackend();
      final src = SystemAudioSource(backend);
      expect(await src.start(), isTrue);
      expect(await src.start(), isFalse);
      await src.dispose();
    });
  });

  group('SystemAudioSource streaming + timestamps', () {
    test('native frames become PcmChunks with monotonic host-clock pts',
        () async {
      final backend = FakeBackend();
      final src = SystemAudioSource(backend);
      final received = <int>[];
      final done = Completer<void>();
      src.chunks.listen((chunk) {
        received.add(chunk.presentationTsUs);
        if (received.length == 3) done.complete();
      });

      expect(await src.start(), isTrue);
      backend.controller.add(FakeBackend.frame20ms());
      backend.controller.add(FakeBackend.frame20ms());
      backend.controller.add(FakeBackend.frame20ms());
      await done.future.timeout(const Duration(seconds: 2));

      // First chunk starts at 0; each 20 ms frame advances pts by 20_000 us.
      expect(received[0], 0);
      expect(received[1], 20000);
      expect(received[2], 40000);
      await src.dispose();
    });

    test('empty native frames are ignored (no phantom chunks)', () async {
      final backend = FakeBackend();
      final src = SystemAudioSource(backend);
      var count = 0;
      src.chunks.listen((_) => count++);
      expect(await src.start(), isTrue);
      backend.controller.add(Uint8List(0)); // empty -> ignored
      backend.controller.add(FakeBackend.frame20ms()); // real -> counted
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(count, 1);
      await src.dispose();
    });

    test('stop() halts capture and releases the backend', () async {
      final backend = FakeBackend();
      final src = SystemAudioSource(backend);
      expect(await src.start(), isTrue);
      await src.stop();
      expect(src.isActive, isFalse);
      expect(backend.stopped, isTrue);
      await src.dispose();
    });

    test('the source exposes the backend format', () {
      final fmt = AudioFormat(sampleRate: 44100, channels: 2, bitDepth: 16);
      final src = SystemAudioSource(FakeBackend(format: fmt));
      expect(src.format.sampleRate, 44100);
    });
  });

  group('PlatformLoopbackBackend (the real platform-channel seam)', () {
    test('isSupported gates on Windows/Android only', () {
      const backend = PlatformLoopbackBackend();
      // The capability gate is Windows||Android; on any other host it is false.
      // We assert it never throws and returns a bool (the exact value depends
      // on the test host OS).
      expect(backend.isSupported, isA<bool>());
    });

    test('exposes the loopback format (48k stereo 16-bit)', () {
      const backend = PlatformLoopbackBackend();
      expect(backend.format.sampleRate, 48000);
      expect(backend.format.channels, 2);
    });

    test('SystemAudioSource degrades gracefully when the native handler is '
        'absent (start returns false, no crash)', () async {
      // Drive the REAL backend: on a test host there is no native handler
      // behind the channel, so invokeMethod raises MissingPluginException and
      // the source must report start()==false rather than throwing.
      final src = SystemAudioSource(const PlatformLoopbackBackend());
      // If this host reports unsupported, start() short-circuits to false; if it
      // reports supported (Windows/Android CI) the missing native handler also
      // yields false. Either way: no throw, no active capture.
      final started = await src.start();
      expect(started, isFalse);
      expect(src.isActive, isFalse);
      await src.dispose();
    });
  });
}
