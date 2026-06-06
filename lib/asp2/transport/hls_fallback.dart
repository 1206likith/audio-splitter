import 'dart:typed_data';

/// HLS fallback — Phase 4 of the v2 plan.
///
/// The real-time transports (WebSocket/QUIC/WebRTC/mesh) are for participants.
/// But the doc also wants the stream to reach **>1000 listeners and late
/// joiners** — an audience that doesn't need sub-second latency and is far
/// cheaper to serve from a CDN than from the host. The standard tool for that is
/// **HLS**: chop the stream into a rolling window of media segments (~6 s each),
/// publish a sliding-window `.m3u8` playlist pointing at them, and let any CDN +
/// any `<video>`/`hls.js` player pull it.
///
/// This file is the **segmenter**: it turns the live frame stream into segments
/// and the playlist text. The actual upload to a CDN/object store (Cloudflare
/// R2, S3, …) is **[needs-service]** and is modelled as the [onSegment] callback
/// seam — wire it to a real uploader on the device/server path; the segmentation
/// itself is pure, deterministic, and unit-tested here.
class HlsSegmenter {
  /// Target segment duration. HLS `#EXT-X-TARGETDURATION` rounds up from this;
  /// a segment closes once its accumulated media meets or exceeds it.
  final Duration targetDuration;

  /// How many recent segments the live playlist advertises (the sliding window).
  /// Older segments fall off the playlist (and would be evicted from the CDN).
  final int windowSize;

  /// Base name for segment uris, e.g. `seg` → `seg0.ts`, `seg1.ts`, …
  final String segmentPrefix;

  /// File extension for segment uris (HLS commonly uses `.ts` or `.aac`).
  final String segmentExtension;

  /// Invoked when a segment closes — the [needs-service] CDN-upload seam.
  final void Function(HlsSegment segment)? onSegment;

  final List<HlsSegment> _window = [];
  final List<Uint8List> _pending = [];
  int _pendingBytes = 0;
  int _pendingDurationMs = 0;
  int _nextSequence = 0;

  HlsSegmenter({
    this.targetDuration = const Duration(seconds: 6),
    this.windowSize = 6,
    this.segmentPrefix = 'seg',
    this.segmentExtension = '.ts',
    this.onSegment,
  })  : assert(windowSize > 0, 'windowSize must be positive'),
        assert(targetDuration > Duration.zero, 'targetDuration must be > 0');

  /// Media sequence number the next closed segment will receive.
  int get nextSequence => _nextSequence;

  /// The segments currently in the live window, oldest first.
  List<HlsSegment> get segments => List.unmodifiable(_window);

  /// Bytes buffered toward the not-yet-closed segment.
  int get pendingBytes => _pendingBytes;

  /// Append one encoded media frame of [durationMs] to the open segment. When
  /// the open segment reaches [targetDuration] it is closed, sequenced, pushed
  /// into the window (evicting the oldest beyond [windowSize]), and handed to
  /// [onSegment].
  void addFrame(Uint8List frame, {required int durationMs}) {
    assert(durationMs >= 0, 'durationMs must be non-negative');
    _pending.add(frame);
    _pendingBytes += frame.length;
    _pendingDurationMs += durationMs;
    if (_pendingDurationMs >= targetDuration.inMilliseconds) {
      _closeSegment();
    }
  }

  /// Force the open segment to close even if short of [targetDuration] (e.g. at
  /// end-of-stream so the tail isn't lost). No-op when nothing is buffered.
  HlsSegment? flush() => _pending.isEmpty ? null : _closeSegment();

  HlsSegment _closeSegment() {
    final bytes = _concat(_pending, _pendingBytes);
    final seq = _nextSequence++;
    final segment = HlsSegment(
      sequence: seq,
      uri: '$segmentPrefix$seq$segmentExtension',
      durationMs: _pendingDurationMs,
      bytes: bytes,
    );
    _pending.clear();
    _pendingBytes = 0;
    _pendingDurationMs = 0;

    _window.add(segment);
    while (_window.length > windowSize) {
      _window.removeAt(0);
    }
    onSegment?.call(segment);
    return segment;
  }

  static Uint8List _concat(List<Uint8List> parts, int totalLen) {
    final out = Uint8List(totalLen);
    var offset = 0;
    for (final p in parts) {
      out.setRange(offset, offset + p.length, p);
      offset += p.length;
    }
    return out;
  }

  /// Render the live media playlist (`.m3u8`) for the current window.
  ///
  /// `#EXT-X-TARGETDURATION` is the rounded-up ceiling of the longest segment;
  /// `#EXT-X-MEDIA-SEQUENCE` is the sequence number of the first segment still in
  /// the window (so players track the sliding window correctly). A VOD/end tag is
  /// added only when [endList] is set (stream finished).
  String playlist({bool endList = false}) {
    final maxSegSeconds = _window.isEmpty
        ? targetDuration.inSeconds
        : (_window.map((s) => s.durationMs).reduce((a, b) => a > b ? a : b) +
                999) ~/
            1000;
    final firstSeq = _window.isEmpty ? _nextSequence : _window.first.sequence;

    final b = StringBuffer()
      ..writeln('#EXTM3U')
      ..writeln('#EXT-X-VERSION:3')
      ..writeln('#EXT-X-TARGETDURATION:$maxSegSeconds')
      ..writeln('#EXT-X-MEDIA-SEQUENCE:$firstSeq');
    for (final s in _window) {
      b
        ..writeln('#EXTINF:${(s.durationMs / 1000).toStringAsFixed(3)},')
        ..writeln(s.uri);
    }
    if (endList) b.writeln('#EXT-X-ENDLIST');
    return b.toString();
  }
}

/// One closed HLS media segment.
class HlsSegment {
  /// Monotonic media-sequence number.
  final int sequence;

  /// Relative uri a player/CDN fetches (e.g. `seg3.ts`).
  final String uri;

  /// Total media duration of the segment in milliseconds.
  final int durationMs;

  /// The concatenated encoded media bytes.
  final Uint8List bytes;

  const HlsSegment({
    required this.sequence,
    required this.uri,
    required this.durationMs,
    required this.bytes,
  });

  @override
  String toString() =>
      'HlsSegment(#$sequence, $uri, ${durationMs}ms, ${bytes.length}B)';
}
