/// One timestamped line of text that overlays on screen at a moment in the
/// stream — a karaoke lyric line now, and the same envelope Phase 6 reuses for
/// live STT captions/translations. Carried on the control plane as a `caption`
/// [ControlMessage].
class CaptionLine {
  /// When the line should appear, host-clock microseconds.
  final int tsUs;

  /// The text to show.
  final String text;

  /// How long to keep it up (ms); 0 ⇒ until the next line.
  final int durationMs;

  const CaptionLine({
    required this.tsUs,
    required this.text,
    this.durationMs = 0,
  });

  Map<String, dynamic> toJson() =>
      {'tsUs': tsUs, 'text': text, 'durationMs': durationMs};

  factory CaptionLine.fromJson(Map<String, dynamic> json) => CaptionLine(
        tsUs: (json['tsUs'] as num).toInt(),
        text: json['text'] as String,
        durationMs: (json['durationMs'] as num?)?.toInt() ?? 0,
      );

  @override
  bool operator ==(Object other) =>
      other is CaptionLine &&
      other.tsUs == tsUs &&
      other.text == text &&
      other.durationMs == durationMs;

  @override
  int get hashCode => Object.hash(tsUs, text, durationMs);

  @override
  String toString() => 'CaptionLine(${tsUs}us "$text")';
}

/// A set of synced lyrics for a track — the parsed result of an LRC file, ready
/// to drive a karaoke overlay. Lines are kept sorted by timestamp so the active
/// line at a given playhead is a binary search.
class SyncedLyrics {
  /// Lyric lines, sorted ascending by [CaptionLine.tsUs].
  final List<CaptionLine> lines;

  SyncedLyrics(List<CaptionLine> lines)
      : lines = (List<CaptionLine>.from(lines)
          ..sort((a, b) => a.tsUs.compareTo(b.tsUs)));

  bool get isEmpty => lines.isEmpty;

  /// Index of the line active at [tsUs] (the last line whose timestamp is ≤
  /// tsUs), or -1 before the first line. Binary search.
  int activeIndexAt(int tsUs) {
    var lo = 0, hi = lines.length - 1, ans = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (lines[mid].tsUs <= tsUs) {
        ans = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return ans;
  }

  /// The line active at [tsUs], or null before the first line.
  CaptionLine? activeLineAt(int tsUs) {
    final i = activeIndexAt(tsUs);
    return i < 0 ? null : lines[i];
  }

  /// The next upcoming line after [tsUs] (for a "preview next line" overlay), or
  /// null at the end.
  CaptionLine? nextLineAfter(int tsUs) {
    final i = activeIndexAt(tsUs);
    final next = i + 1;
    return next < lines.length ? lines[next] : null;
  }
}

/// Parser for **LRC** lyric files — the format LRCLIB (the plan's free lyrics
/// source) returns. Handles `[mm:ss.xx]` and `[mm:ss.xxx]` tags, multiple tags
/// on one line (a repeated line), and ignores `[id:...]` metadata tags. Pure and
/// deterministic; the LRCLIB *fetch* is the [needs-service] half ([LyricsProvider]).
class LrcParser {
  LrcParser._();

  /// Matches one `[mm:ss.xx]` time tag, capturing minutes, seconds, fraction.
  static final RegExp _timeTag =
      RegExp(r'\[(\d{1,2}):(\d{2})(?:[.:](\d{1,3}))?\]');

  /// Parse [lrc] into [SyncedLyrics]. Lines with no time tag (pure metadata) are
  /// dropped; a line with multiple tags is emitted once per tag.
  static SyncedLyrics parse(String lrc, {int defaultDurationMs = 0}) {
    final out = <CaptionLine>[];
    for (final rawLine in lrc.split(RegExp(r'\r?\n'))) {
      final matches = _timeTag.allMatches(rawLine).toList();
      if (matches.isEmpty) continue;
      final text = rawLine.replaceAll(_timeTag, '').trim();
      for (final m in matches) {
        final min = int.parse(m.group(1)!);
        final sec = int.parse(m.group(2)!);
        final fracStr = m.group(3);
        var fracUs = 0;
        if (fracStr != null) {
          // Normalize 2- or 3-digit fractions to microseconds.
          final padded = fracStr.padRight(3, '0').substring(0, 3);
          fracUs = int.parse(padded) * 1000;
        }
        final tsUs = (min * 60 + sec) * 1000000 + fracUs;
        out.add(CaptionLine(
          tsUs: tsUs,
          text: text,
          durationMs: defaultDurationMs,
        ));
      }
    }
    return SyncedLyrics(out);
  }
}

/// **[needs-service]** scaffold for fetching lyrics from LRCLIB (lrclib.net, a
/// free, no-key synced-lyrics API). Network I/O is deferred to the device path;
/// the parsing + sync ([LrcParser]/[SyncedLyrics]) is fully tested. Wire a real
/// HTTP client into [fetchLrc] on the device build.
abstract class LyricsProvider {
  /// Resolve raw LRC text for a track, or null if not found / offline.
  Future<String?> fetchLrc({
    required String artist,
    required String title,
    Duration? duration,
  });
}

/// The offline default: never finds lyrics. Keeps the karaoke path constructible
/// and testable with no network, same spirit as the simulated sinks/transports.
class UnavailableLyricsProvider implements LyricsProvider {
  const UnavailableLyricsProvider();

  static bool get isAvailable => false;

  @override
  Future<String?> fetchLrc({
    required String artist,
    required String title,
    Duration? duration,
  }) async =>
      null;
}
