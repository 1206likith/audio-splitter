import 'dart:convert';
import 'dart:typed_data';

import '../ai/highlight.dart';
import 'audio_encoder.dart';
import 'daw/ableton_als.dart';
import 'daw/reaper_rpp.dart';
import 'stem_recorder.dart';
import 'zip_writer.dart';

/// Packages a [RecordedSession] into a single downloadable archive (the plan's
/// "multitrack zip"): every stem encoded to the chosen lossless format under
/// `stems/`, ready-to-open Reaper and Ableton projects with the stems
/// **pre-placed** at their captured offsets, a JSON manifest, and any detected
/// highlight clips (reusing the Phase 6 [HighlightClip]). Fully deterministic
/// and in-memory, so it is unit-testable without touching disk.
class SessionBundle {
  SessionBundle._();

  /// Archive-relative path the DAW projects use to reference [stem].
  static String stemPath(RecordedStem stem, AudioEncoder encoder) =>
      'stems/${stem.baseFileName}.${encoder.extension}';

  /// JSON manifest describing the session (also embedded in the zip). Times are
  /// seconds on the session timeline.
  static Map<String, dynamic> manifest(
    RecordedSession session, {
    AudioEncoder encoder = const WavEncoder(),
    List<HighlightClip> highlights = const [],
  }) {
    return {
      'name': session.name,
      'sampleRate': session.sampleRate,
      'durationSeconds': session.durationSeconds,
      'stemFormat': encoder.name,
      'stems': [
        for (final s in session.stems)
          {
            'id': s.spec.id,
            'name': s.spec.name,
            'kind': s.spec.kind.name,
            'file': stemPath(s, encoder),
            'channels': s.format.channels,
            'startSeconds': s.startSeconds,
            'durationSeconds': s.durationSeconds,
          },
      ],
      'highlights': [
        for (final h in highlights)
          {
            'startSeconds': h.startTsUs / 1000000.0,
            'endSeconds': h.endTsUs / 1000000.0,
            'peakEnergy': h.peakEnergy,
          },
      ],
    };
  }

  /// Build the `.zip` bytes. [stemEncoder] is the per-stem format (WAV by
  /// default; FLAC for lossless compression). Unavailable lossy encoders fall
  /// back to WAV inside [RecordedStem.encode], never a silent skip.
  static Uint8List build(
    RecordedSession session, {
    AudioEncoder stemEncoder = const WavEncoder(),
    bool includeReaper = true,
    bool includeAbleton = true,
    List<HighlightClip> highlights = const [],
  }) {
    final encoder = stemEncoder.isAvailable ? stemEncoder : const WavEncoder();
    final entries = <ZipEntry>[];

    for (final stem in session.stems) {
      entries.add(ZipEntry(stemPath(stem, encoder), stem.encode(encoder)));
    }

    String pathFor(RecordedStem s) => stemPath(s, encoder);

    if (includeReaper) {
      entries.add(ZipEntry.text(
        '${_safe(session.name)}.rpp',
        ReaperProject.build(session, stemPathFor: pathFor),
      ));
    }
    if (includeAbleton) {
      entries.add(ZipEntry(
        '${_safe(session.name)}.als',
        AbletonProject.encode(session, stemPathFor: pathFor),
      ));
    }

    entries.add(ZipEntry.text(
      'manifest.json',
      const JsonEncoder.withIndent('  ').convert(
        manifest(session, encoder: encoder, highlights: highlights),
      ),
    ));

    return ZipWriter.build(entries);
  }

  static String _safe(String name) {
    final s = name.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return s.isEmpty ? 'session' : s;
  }
}
