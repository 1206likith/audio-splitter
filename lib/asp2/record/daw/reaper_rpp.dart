import '../stem_recorder.dart';

/// Generates a **Reaper** `.rpp` project that references the recorded stems,
/// each on its own track and **pre-placed at the timeline offset it was captured
/// at**. The `.rpp` format is plain, well-documented text, so this exporter is
/// fully deterministic and unit-testable (no DAW required to verify structure).
///
/// [stemPathFor] maps a stem to the path the project should reference (relative
/// to the `.rpp`, e.g. `stems/source_mic.wav`); the session bundle uses this to
/// point at the WAVs it packs alongside the project.
class ReaperProject {
  ReaperProject._();

  /// Build the `.rpp` text for [session]. Each stem becomes one track with one
  /// media item at `POSITION = startSeconds`, `LENGTH = durationSeconds`.
  static String build(
    RecordedSession session, {
    required String Function(RecordedStem stem) stemPathFor,
  }) {
    final sr = session.sampleRate;
    final b = StringBuffer();
    b.writeln('<REAPER_PROJECT 0.1 "7.0/audio_splitter" 0');
    b.writeln('  SAMPLERATE $sr 0 0');
    b.writeln('  TEMPO 120 4 4');

    for (final stem in session.stems) {
      final pos = _num(stem.startSeconds);
      final len = _num(stem.durationSeconds);
      b.writeln('  <TRACK');
      b.writeln('    NAME ${_quote(stem.spec.name)}');
      b.writeln('    <ITEM');
      b.writeln('      POSITION $pos');
      b.writeln('      LENGTH $len');
      b.writeln('      NAME ${_quote(stem.spec.name)}');
      b.writeln('      <SOURCE WAVE');
      b.writeln('        FILE ${_quote(stemPathFor(stem))}');
      b.writeln('      >');
      b.writeln('    >');
      b.writeln('  >');
    }

    b.writeln('>');
    return b.toString();
  }

  /// Reaper quotes strings with `"`; values containing a quote fall back to `'`.
  static String _quote(String s) {
    if (!s.contains('"')) return '"$s"';
    if (!s.contains("'")) return "'$s'";
    return '"${s.replaceAll('"', '')}"';
  }

  /// Fixed 6-dp decimal so output is stable across platforms/locales.
  static String _num(double v) => v.toStringAsFixed(6);
}
