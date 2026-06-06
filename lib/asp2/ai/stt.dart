import '../../core/pipeline/audio_chunk.dart';
import '../party/karaoke.dart';

/// One recognized span of speech: text plus the audio-time window it covers and
/// a confidence. Converts to the Phase 5 [CaptionLine] envelope — the same
/// on-screen line karaoke uses — so live captions ride the existing `caption`
/// control message unchanged (the seam Phase 5 left for exactly this).
class SttSegment {
  final String text;

  /// Audio-clock microseconds where the utterance begins (when the caption
  /// should *appear*, time-aligned to the speech).
  final int startTsUs;

  /// Audio-clock microseconds where the utterance ends.
  final int endTsUs;

  /// Recognizer confidence in `[0,1]`.
  final double confidence;

  /// False for an interim (still-changing) hypothesis, true once stable.
  final bool isFinal;

  const SttSegment({
    required this.text,
    required this.startTsUs,
    required this.endTsUs,
    this.confidence = 1.0,
    this.isFinal = true,
  });

  int get durationUs => endTsUs - startTsUs;

  /// As an on-screen caption line (the karaoke/STT shared envelope).
  CaptionLine toCaptionLine() => CaptionLine(
        tsUs: startTsUs,
        text: text,
        durationMs: (durationUs ~/ 1000).clamp(0, 1 << 30),
      );

  @override
  String toString() =>
      'SttSegment("$text" $startTsUs–${endTsUs}us${isFinal ? "" : " ~"})';
}

/// On-device speech-to-text. The live implementation here is [ScriptedStt]
/// (deterministic, for the pipeline + latency gate); the real recognizer is
/// `whisper.cpp` via FFI ([WhisperStt], [needs-FFI]). Both push: feed audio
/// chunks, get back captions that have *finalized* as of each chunk's timestamp.
abstract class SpeechToText {
  bool get isAvailable;

  /// The recognizer's target language tag (BCP-47, e.g. `en`).
  String get language;

  /// Feed one audio chunk; return any captions that became available at or
  /// before [PcmChunk.presentationTsUs]. Returns empty when nothing finalized.
  List<CaptionLine> ingest(PcmChunk chunk);
}

/// A scripted utterance for [ScriptedStt]: known text over a known audio-time
/// window. The simulator emits it only once the audio clock has passed its end
/// (a recognizer can't finalize a phrase before it has heard all of it).
class ScriptedUtterance {
  final String text;
  final int startTsUs;
  final int endTsUs;

  const ScriptedUtterance({
    required this.text,
    required this.startTsUs,
    required this.endTsUs,
  });
}

/// **Deterministic STT simulator** — the live, no-binary captioner used for
/// development and the latency gate. Given a script of utterances and a fixed
/// [processingLatencyUs] (the model of "how long after the words finish does the
/// caption appear"), it emits each utterance's [CaptionLine] the first time an
/// ingested chunk's timestamp reaches `endTsUs + processingLatencyUs`.
///
/// The emitted caption is time-stamped at the utterance *start* (so it aligns to
/// the speech on screen), while the emission *moment* models real latency — the
/// gap the Phase 6 gate bounds to under two seconds.
class ScriptedStt implements SpeechToText {
  final List<ScriptedUtterance> script;

  /// Modelled end-of-utterance → caption-visible delay.
  final int processingLatencyUs;

  @override
  final String language;

  final List<bool> _emitted;

  ScriptedStt(
    this.script, {
    this.processingLatencyUs = 600000, // 0.6 s — comfortably under the 2 s gate
    this.language = 'en',
  }) : _emitted = List<bool>.filled(script.length, false);

  @override
  bool get isAvailable => true;

  /// The audio-time at which utterance [i]'s caption becomes visible.
  int availableAtUs(int i) => script[i].endTsUs + processingLatencyUs;

  @override
  List<CaptionLine> ingest(PcmChunk chunk) {
    final nowUs = chunk.presentationTsUs;
    final out = <CaptionLine>[];
    for (var i = 0; i < script.length; i++) {
      if (_emitted[i]) continue;
      if (nowUs >= availableAtUs(i)) {
        _emitted[i] = true;
        out.add(SttSegment(
          text: script[i].text,
          startTsUs: script[i].startTsUs,
          endTsUs: script[i].endTsUs,
        ).toCaptionLine());
      }
    }
    return out;
  }

  void reset() {
    for (var i = 0; i < _emitted.length; i++) {
      _emitted[i] = false;
    }
  }
}

/// **[needs-FFI]** `whisper.cpp` recognizer scaffold. Real on-device STT needs
/// the whisper native lib + a model file (tiny/base) vendored per platform, so
/// it is deferred behind the load-probe contract (Opus/RNNoise pattern); the
/// scripted recognizer is the live path. Reports unavailable and recognizes
/// nothing until the binary + model land.
class WhisperStt implements SpeechToText {
  @override
  final String language;

  /// Model size tag a device build would load (`tiny`, `base`, …).
  final String model;

  WhisperStt({this.language = 'en', this.model = 'base'});

  @override
  bool get isAvailable => false;

  String get unavailableReason =>
      'whisper.cpp native lib + "$model" model not vendored on this build; '
      'use ScriptedStt or wire the FFI binding on the device path.';

  @override
  List<CaptionLine> ingest(PcmChunk chunk) => const [];
}
