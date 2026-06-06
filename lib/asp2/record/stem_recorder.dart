import 'dart:typed_data';

import '../../core/contracts/audio_format.dart';
import '../../core/pipeline/audio_chunk.dart';
import 'audio_encoder.dart';
import 'wav_writer.dart';

/// What a recorded stem captures.
enum StemKind {
  /// A raw input source (mic, system audio, a DJ deck, a podcast guest).
  source,

  /// A post-mix zone bus (a room, a stage monitor) — every Phase 3 zone.
  zoneMix,

  /// The final program mix.
  master,
}

/// Declares one stem to record: a stable [id] (the source/zone node id in the
/// router DAG), a human [name] used as the DAW track name, its [kind], and the
/// PCM [format] it is captured at.
class StemSpec {
  final String id;
  final String name;
  final StemKind kind;
  final AudioFormat format;

  const StemSpec({
    required this.id,
    required this.name,
    required this.kind,
    this.format = AudioFormat.cdStereo,
  });
}

/// Append-only byte target for one stem. The default is in-memory
/// ([_MemoryStemSink]); a file-backed implementation that flushes each append
/// to disk makes recording **crash-safe** (a crash loses at most the last chunk,
/// and a WAV header is reconstructable from the byte count — the same finalize
/// trick [WavWriter] supports). Recording is independent of playback: a stem
/// keeps accumulating even if its sink is never drained.
abstract class StemSink {
  void append(Uint8List bytes);
  int get length;
  Uint8List takeBytes();
}

class _MemoryStemSink implements StemSink {
  final BytesBuilder _b = BytesBuilder();
  @override
  void append(Uint8List bytes) => _b.add(bytes);
  @override
  int get length => _b.length;
  @override
  Uint8List takeBytes() => _b.toBytes();
}

/// A finished stem: its spec, the captured PCM, and where it sits on the session
/// timeline ([startOffsetUs] = first-chunk timestamp relative to session start).
/// Late-joining sources get a positive offset, so a DAW lays each clip at the
/// moment it actually began — the "stems pre-placed" behaviour the gate checks.
class RecordedStem {
  final StemSpec spec;
  final Uint8List pcm;
  final int startOffsetUs;

  const RecordedStem({
    required this.spec,
    required this.pcm,
    required this.startOffsetUs,
  });

  AudioFormat get format => spec.format;

  int get frames =>
      format.frameBytes == 0 ? 0 : pcm.length ~/ format.frameBytes;

  /// Audio duration of the captured samples, in seconds.
  double get durationSeconds =>
      format.sampleRate == 0 ? 0 : frames / format.sampleRate;

  /// Timeline start, in seconds (offset from session start).
  double get startSeconds => startOffsetUs / 1000000.0;

  /// Timeline end, in seconds.
  double get endSeconds => startSeconds + durationSeconds;

  /// A safe file stem (no extension): `kind_id`, sanitized.
  String get baseFileName {
    final raw = '${spec.kind.name}_${spec.id}';
    return raw.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
  }

  /// Encode this stem to a `.wav`.
  Uint8List toWav() => WavWriter.encode(format, pcm);

  /// Encode this stem with [encoder] (falls back to WAV if it is unavailable).
  Uint8List encode(AudioEncoder encoder) =>
      encoder.isAvailable ? encoder.encode(format, pcm) : toWav();
}

/// A captured multi-stem session.
class RecordedSession {
  final String name;
  final int startTsUs;
  final List<RecordedStem> stems;

  const RecordedSession({
    required this.name,
    required this.startTsUs,
    required this.stems,
  });

  /// Longest stem end on the timeline, in seconds (the session length).
  double get durationSeconds {
    var end = 0.0;
    for (final s in stems) {
      if (s.endSeconds > end) end = s.endSeconds;
    }
    return end;
  }

  /// Sample rate to stamp on a DAW project (first stem's; stems share it in
  /// practice).
  int get sampleRate => stems.isEmpty ? 48000 : stems.first.format.sampleRate;
}

/// **Multi-stem session recorder** — the host-side capture engine. Register one
/// [StemSpec] per source and per zone mix, then [write] each layer's chunks as
/// they flow; each stem accumulates independently into its own [StemSink]. On
/// [stop] it returns a [RecordedSession] with every stem time-aligned to the
/// session start, ready for per-stem export or DAW project packaging.
///
/// Deterministic and time-driven: every stem's placement comes from the chunk
/// timestamps you feed it, never a wall clock.
class SessionRecorder {
  final String sessionName;
  final int sessionStartTsUs;

  /// Factory for each stem's append target. Defaults to in-memory; inject a
  /// file-backed sink for crash-safe disk recording.
  final StemSink Function(StemSpec spec) _sinkFactory;

  final Map<String, StemSpec> _specs = {};
  final Map<String, StemSink> _sinks = {};
  final Map<String, int> _startUs = {};
  bool _recording = true;

  SessionRecorder({
    required this.sessionName,
    required this.sessionStartTsUs,
    StemSink Function(StemSpec spec)? sinkFactory,
  }) : _sinkFactory = sinkFactory ?? ((_) => _MemoryStemSink());

  bool get isRecording => _recording;

  /// Registered stem ids, in registration order.
  Iterable<String> get stemIds => _specs.keys;

  /// Declare a stem to capture. Re-registering the same id replaces its spec.
  void register(StemSpec spec) {
    _specs[spec.id] = spec;
    _sinks[spec.id] = _sinkFactory(spec);
  }

  /// Convenience: register a source stem.
  void registerSource(String id, String name,
          {AudioFormat format = AudioFormat.cdStereo}) =>
      register(
          StemSpec(id: id, name: name, kind: StemKind.source, format: format));

  /// Convenience: register a zone-mix stem.
  void registerZone(String zoneId, String name,
          {AudioFormat format = AudioFormat.cdStereo}) =>
      register(StemSpec(
          id: zoneId, name: name, kind: StemKind.zoneMix, format: format));

  /// Append one chunk to stem [stemId]. The first chunk fixes the stem's
  /// timeline offset. Chunks for unregistered ids are ignored (so a transient
  /// source can't corrupt the session). No-op after [stop].
  void write(String stemId, PcmChunk chunk) {
    if (!_recording) return;
    final sink = _sinks[stemId];
    if (sink == null) return;
    _startUs.putIfAbsent(stemId, () {
      final off = chunk.presentationTsUs - sessionStartTsUs;
      return off < 0 ? 0 : off;
    });
    sink.append(chunk.pcm);
  }

  /// Finish recording and collect the stems (registration order). Stems that
  /// never received a chunk are emitted empty at offset 0.
  RecordedSession stop() {
    _recording = false;
    final stems = <RecordedStem>[];
    for (final entry in _specs.entries) {
      final sink = _sinks[entry.key]!;
      stems.add(RecordedStem(
        spec: entry.value,
        pcm: sink.takeBytes(),
        startOffsetUs: _startUs[entry.key] ?? 0,
      ));
    }
    return RecordedSession(
      name: sessionName,
      startTsUs: sessionStartTsUs,
      stems: stems,
    );
  }
}
