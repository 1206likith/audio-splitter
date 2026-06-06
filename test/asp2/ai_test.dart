import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audio_splitter_app/asp2/ai/ducking.dart';
import 'package:audio_splitter_app/asp2/ai/highlight.dart';
import 'package:audio_splitter_app/asp2/ai/stt.dart';
import 'package:audio_splitter_app/asp2/ai/track_id.dart';
import 'package:audio_splitter_app/asp2/ai/translate.dart';
import 'package:audio_splitter_app/asp2/ai/vad.dart';
import 'package:audio_splitter_app/asp2/control/control_plane.dart';
import 'package:audio_splitter_app/asp2/party/karaoke.dart';
import 'package:audio_splitter_app/asp2/spatial/positioning.dart';
import 'package:audio_splitter_app/core/contracts/audio_format.dart';
import 'package:audio_splitter_app/core/pipeline/audio_chunk.dart';
import 'package:flutter_test/flutter_test.dart';

/// Constant-amplitude chunk in the given format.
PcmChunk constChunk(double amp, int frames,
    {AudioFormat format = AudioFormat.cdStereo, int tsUs = 0}) {
  final pcm = Uint8List(frames * format.frameBytes);
  final bd = ByteData.view(pcm.buffer);
  final s = (amp * 32000).round();
  for (var f = 0; f < frames; f++) {
    for (var c = 0; c < format.channels; c++) {
      bd.setInt16((f * format.channels + c) * 2, s, Endian.little);
    }
  }
  return PcmChunk(pcm: pcm, presentationTsUs: tsUs, format: format);
}

/// Mono sine chunk (for chroma fingerprinting).
PcmChunk sineMono(double freqHz, double amp, int frames, {int tsUs = 0}) {
  const format = AudioFormat.voiceMono;
  final pcm = Uint8List(frames * format.frameBytes);
  final bd = ByteData.view(pcm.buffer);
  for (var f = 0; f < frames; f++) {
    final v =
        (amp * math.sin(2 * math.pi * freqHz * f / format.sampleRate) * 32000)
            .round();
    bd.setInt16(f * 2, v, Endian.little);
  }
  return PcmChunk(pcm: pcm, presentationTsUs: tsUs, format: format);
}

double rms(PcmChunk c) => EnergyVad.rmsOf(c);

void main() {
  group('Energy VAD', () {
    test('silence is not speech, a loud tone is', () {
      final vad = EnergyVad();
      expect(
          vad
              .process(constChunk(0.0, 480, format: AudioFormat.voiceMono))
              .isSpeech,
          isFalse);
      expect(
          vad
              .process(constChunk(0.5, 480, format: AudioFormat.voiceMono))
              .isSpeech,
          isTrue);
    });

    test('hangover latches speech across a short gap', () {
      final vad = EnergyVad(hangoverUs: 300000);
      vad.process(constChunk(0.5, 480, format: AudioFormat.voiceMono, tsUs: 0));
      // 100 ms later, silence — still within the 300 ms hangover.
      final r = vad.process(
          constChunk(0.0, 480, format: AudioFormat.voiceMono, tsUs: 100000));
      expect(r.isSpeech, isTrue);
      // 1 s later, silence — hangover expired.
      final r2 = vad.process(
          constChunk(0.0, 480, format: AudioFormat.voiceMono, tsUs: 1000000));
      expect(r2.isSpeech, isFalse);
    });
  });

  group('STT → captions', () {
    test('scripted STT emits a CaptionLine aligned to speech start', () {
      final stt = ScriptedStt([
        const ScriptedUtterance(
            text: 'welcome everyone', startTsUs: 1000000, endTsUs: 2000000),
      ], processingLatencyUs: 500000);

      // Before end+latency: nothing yet.
      expect(stt.ingest(constChunk(0.0, 1, tsUs: 2400000)), isEmpty);
      // At/after 2.0s + 0.5s: the caption finalizes.
      final out = stt.ingest(constChunk(0.0, 1, tsUs: 2500000));
      expect(out, hasLength(1));
      expect(out.first.text, 'welcome everyone');
      expect(out.first.tsUs, 1000000); // aligned to when it was spoken
      expect(out.first.durationMs, 1000);
    });

    test('WhisperStt scaffold is deferred', () {
      final w = WhisperStt();
      expect(w.isAvailable, isFalse);
      expect(w.ingest(constChunk(0.5, 480)), isEmpty);
      expect(w.unavailableReason, contains('whisper'));
    });
  });

  group('Translation', () {
    test('dictionary translate en→es preserves caption timing', () {
      final t = DictionaryTranslator.demo();
      const line = CaptionLine(
          tsUs: 5000000, text: 'Welcome everyone', durationMs: 1500);
      final es = t.translateCaption(line, from: 'en', to: 'es');
      expect(es.text, 'Bienvenidos todos');
      expect(es.tsUs, 5000000);
      expect(es.durationMs, 1500);
    });

    test('identity translator is a no-op; cloud is deferred', () {
      expect(const IdentityTranslator().translate('hi', from: 'en', to: 'en'),
          'hi');
      expect(const CloudTranslator().isAvailable, isFalse);
    });
  });

  group('Track ID (chroma fingerprint)', () {
    test('a C tone peaks in the C chroma bin', () {
      // C5 = 523.25 Hz; all octaves of C fold into bin 0.
      final chroma =
          ChromaFingerprint.chromaVector(sineMono(523.25, 0.9, 9600));
      var argmax = 0;
      for (var i = 1; i < 12; i++) {
        if (chroma[i] > chroma[argmax]) argmax = i;
      }
      expect(argmax, 0); // C
    });

    test('fingerprint is deterministic and self-similar', () {
      final a = sineMono(440, 0.8, 4800);
      final fpA1 = ChromaFingerprint.fingerprint([a]);
      final fpA2 = ChromaFingerprint.fingerprint([a]);
      expect(fpA1, fpA2); // deterministic
      expect(ChromaFingerprint.similarity(fpA1, fpA2), 1.0);
      expect(AcoustIdLookup.isAvailable, isFalse);
    });
  });

  group('Highlight auto-clip', () {
    test('fires on a sustained energy spike with pre/post roll', () {
      final det = HighlightDetector(
        enterThreshold: 0.8,
        exitThreshold: 0.5,
        minDurationUs: 2000000,
        preRollUs: 3000000,
        postRollUs: 2000000,
      );
      HighlightClip? clip;
      // Energy curve sampled once per second (µs timestamps).
      final curve = <int, double>{
        0: 0.2,
        1: 0.3,
        2: 0.9, // spike opens at t=2s
        3: 0.95,
        4: 0.9,
        5: 0.85, // sustained ~3s
        6: 0.2, // drop closes the window
      };
      for (final e in curve.entries) {
        final c = det.observe(e.key * 1000000, e.value);
        if (c != null) clip = c;
      }
      expect(clip, isNotNull);
      expect(clip!.startTsUs, 2000000 - 3000000); // open(2s) − preroll(3s)
      expect(clip.endTsUs, 5000000 + 2000000); // lastAbove(5s) + postroll(2s)
      expect(clip.peakEnergy, closeTo(0.95, 1e-9));
    });

    test('ignores a short blip below the minimum duration', () {
      final det = HighlightDetector(minDurationUs: 2000000);
      expect(det.observe(0, 0.9), isNull); // opens
      expect(det.observe(500000, 0.2), isNull); // closes after 0.5 s ⇒ no clip
    });
  });

  group('Control plane — listener pose (Phase 6)', () {
    test('round-trips through the control message envelope', () {
      const pose = ListenerPose(position: Vec2(3.5, 7.25), headingDeg: 120);
      final wire = ControlMessage.listenerPose(pose).encode();
      final back = ControlMessage.decode(wire);
      expect(back.type, ControlMessageType.listenerPose);
      expect(back.asListenerPose(), pose);
    });
  });

  group('Phase 6 gate — AI (captions <2s, ducking fires)', () {
    test('live captions finalize under 2s and auto-ducking attenuates music',
        () {
      // --- Live captions latency ---
      const spokenStartUs = 10000000;
      const spokenEndUs = 12000000;
      final stt = ScriptedStt([
        const ScriptedUtterance(
            text: 'the drop is coming',
            startTsUs: spokenStartUs,
            endTsUs: spokenEndUs),
      ], processingLatencyUs: 600000);

      CaptionLine? caption;
      var emittedAtUs = 0;
      // Stream 100 ms chunks of audio time past the utterance.
      for (var t = spokenEndUs; t <= spokenEndUs + 2000000; t += 100000) {
        final out = stt.ingest(constChunk(0.0, 1, tsUs: t));
        if (out.isNotEmpty) {
          caption = out.first;
          emittedAtUs = t;
          break;
        }
      }
      expect(caption, isNotNull);
      final captionLatencyUs = emittedAtUs - spokenEndUs;
      expect(captionLatencyUs, lessThan(2000000)); // <2 s after speech ends
      // And it can ride the existing caption control message unchanged.
      final cm = ControlMessage.caption(caption!);
      expect(cm.asCaption().text, 'the drop is coming');

      // --- VAD auto-ducking on the music bus ---
      final ducker = SidechainDucker(
        vad: EnergyVad(),
        ducker: AutoDucker(duckDepthDb: -14),
      );
      const music = AudioFormat.cdStereo;
      const voice = AudioFormat.voiceMono;

      // Voice present ⇒ music ducks down.
      PcmChunk ducked = constChunk(0.5, 480, format: music);
      for (var i = 0; i < 6; i++) {
        ducked = ducker.process(
          constChunk(0.5, 4800, format: music, tsUs: i * 100000),
          constChunk(0.6, 4800, format: voice, tsUs: i * 100000),
        );
      }
      expect(ducker.ducker.isDucked, isTrue);
      final duckTroughGain = ducker.ducker.currentGain;
      expect(duckTroughGain, lessThan(0.5));
      final duckedRms = rms(ducked);

      // Voice stops ⇒ music recovers (allowing for the VAD hangover tail before
      // the release envelope can climb back).
      PcmChunk recovered = ducked;
      for (var i = 6; i < 30; i++) {
        recovered = ducker.process(
          constChunk(0.5, 4800, format: music, tsUs: i * 100000),
          constChunk(0.0, 4800, format: voice, tsUs: i * 100000),
        );
      }
      expect(ducker.ducker.currentGain, greaterThan(0.9));
      final recoveredRms = rms(recovered);
      expect(recoveredRms, greaterThan(duckedRms));

      // ignore: avoid_print
      print('Phase 6 gate (AI): caption finalized '
          '${(captionLatencyUs / 1000).round()}ms after speech (<2000ms); '
          'auto-ducker pulled music to ${duckTroughGain.toStringAsFixed(2)}× '
          '(rms ${duckedRms.toStringAsFixed(3)}) under voice, recovered to '
          '${ducker.ducker.currentGain.toStringAsFixed(2)}× '
          '(rms ${recoveredRms.toStringAsFixed(3)}) in silence.');
    });
  });
}
