import '../dsp/parametric_eq.dart';

/// Which of the two DJ decks. The party host runs deck A and deck B side by
/// side; the crossfader blends between them.
enum DeckId { a, b }

/// The three classic DJ EQ "kill" bands. A kill fully cuts that band so a DJ can
/// drop the bass out of one track while the other's bass carries the mix.
enum EqKill { low, mid, high }

/// A cue point a DJ can jump the playhead to instantly.
class HotCue {
  /// Slot index on the controller (0-based).
  final int index;

  /// Position in the track, microseconds from its start.
  final int positionUs;

  /// Optional human label.
  final String label;

  const HotCue({
    required this.index,
    required this.positionUs,
    this.label = '',
  });

  Map<String, dynamic> toJson() =>
      {'index': index, 'positionUs': positionUs, 'label': label};

  factory HotCue.fromJson(Map<String, dynamic> json) => HotCue(
        index: (json['index'] as num).toInt(),
        positionUs: (json['positionUs'] as num).toInt(),
        label: json['label'] as String? ?? '',
      );

  @override
  bool operator ==(Object other) =>
      other is HotCue &&
      other.index == index &&
      other.positionUs == positionUs &&
      other.label == label;

  @override
  int get hashCode => Object.hash(index, positionUs, label);
}

/// Immutable snapshot of one deck. The [DjDeck] controller produces new
/// snapshots; the snapshot is JSON-serializable so the host can mirror deck
/// state to clients (for a synced "now playing" view) over the control plane.
class DeckState {
  final DeckId deckId;

  /// Loaded track id, or null when the deck is empty.
  final String? trackId;

  /// Original track tempo, if known (drives beat-matching).
  final double? bpm;

  /// Playhead position in microseconds from track start.
  final int positionUs;

  final bool isPlaying;

  /// Playback speed multiplier (1.0 = original). Beat-matching nudges this.
  final double tempoRatio;

  /// Channel fader gain, linear `[0, 1]`.
  final double gain;

  /// Currently engaged EQ kills.
  final Set<EqKill> kills;

  final List<HotCue> cues;

  const DeckState({
    required this.deckId,
    this.trackId,
    this.bpm,
    this.positionUs = 0,
    this.isPlaying = false,
    this.tempoRatio = 1.0,
    this.gain = 1.0,
    this.kills = const {},
    this.cues = const [],
  });

  /// Effective tempo after the deck's [tempoRatio] is applied — the BPM the
  /// crossfader and beat grid see.
  double? get effectiveBpm => bpm == null ? null : bpm! * tempoRatio;

  DeckState copyWith({
    String? trackId,
    bool clearTrack = false,
    double? bpm,
    bool clearBpm = false,
    int? positionUs,
    bool? isPlaying,
    double? tempoRatio,
    double? gain,
    Set<EqKill>? kills,
    List<HotCue>? cues,
  }) {
    return DeckState(
      deckId: deckId,
      trackId: clearTrack ? null : (trackId ?? this.trackId),
      bpm: clearBpm ? null : (bpm ?? this.bpm),
      positionUs: positionUs ?? this.positionUs,
      isPlaying: isPlaying ?? this.isPlaying,
      tempoRatio: tempoRatio ?? this.tempoRatio,
      gain: gain ?? this.gain,
      kills: kills ?? this.kills,
      cues: cues ?? this.cues,
    );
  }

  Map<String, dynamic> toJson() => {
        'deckId': deckId.name,
        if (trackId != null) 'trackId': trackId,
        if (bpm != null) 'bpm': bpm,
        'positionUs': positionUs,
        'isPlaying': isPlaying,
        'tempoRatio': tempoRatio,
        'gain': gain,
        'kills': [for (final k in kills) k.name],
        'cues': [for (final c in cues) c.toJson()],
      };

  factory DeckState.fromJson(Map<String, dynamic> json) => DeckState(
        deckId: DeckId.values.byName(json['deckId'] as String),
        trackId: json['trackId'] as String?,
        bpm: (json['bpm'] as num?)?.toDouble(),
        positionUs: (json['positionUs'] as num?)?.toInt() ?? 0,
        isPlaying: json['isPlaying'] as bool? ?? false,
        tempoRatio: (json['tempoRatio'] as num?)?.toDouble() ?? 1.0,
        gain: (json['gain'] as num?)?.toDouble() ?? 1.0,
        kills: {
          for (final k in (json['kills'] as List? ?? const []))
            EqKill.values.byName(k as String),
        },
        cues: [
          for (final c in (json['cues'] as List? ?? const []))
            HotCue.fromJson((c as Map).cast<String, dynamic>()),
        ],
      );

  @override
  String toString() =>
      'DeckState(${deckId.name}, ${trackId ?? "—"}, ${positionUs}us, '
      'play=$isPlaying, tempo=${tempoRatio.toStringAsFixed(3)}, '
      'kills=${kills.map((k) => k.name).join("+")})';
}

/// A DJ deck **controller** — a pure state machine over [DeckState]. It owns the
/// transport (load/play/pause/seek), the pitch fader ([setTempoRatio]), the EQ
/// kills, and hot cues. It deliberately holds **no audio I/O**: the actual
/// rendering reuses the tested DSP — [killEqBands] feeds the existing
/// [ParametricEq], and the level blend is the crossfader's job.
///
/// All state transitions are deterministic and clock-free; the host advances the
/// playhead with [advance] using the chunk durations it already has, so the deck
/// never reads a wall clock.
class DjDeck {
  DeckState _state;

  DjDeck(DeckId id) : _state = DeckState(deckId: id);

  DjDeck.from(this._state);

  DeckState get state => _state;
  DeckId get id => _state.deckId;

  /// Centre frequencies for the three kill bands (Hz). Public so a UI meter can
  /// label them.
  static const double lowKillHz = 100;
  static const double midKillHz = 1000;
  static const double highKillHz = 8000;

  /// Attenuation applied by an engaged kill (a deep peaking-EQ cut). −48 dB is
  /// effectively silent for that band while staying numerically well-behaved.
  static const double killGainDb = -48.0;

  void load(String trackId, {double? bpm}) {
    _state = _state.copyWith(
      trackId: trackId,
      bpm: bpm,
      clearBpm: bpm == null,
      positionUs: 0,
      isPlaying: false,
    );
  }

  void eject() {
    _state = DeckState(deckId: _state.deckId);
  }

  void play() {
    if (_state.trackId != null) _state = _state.copyWith(isPlaying: true);
  }

  void pause() => _state = _state.copyWith(isPlaying: false);

  void seek(int positionUs) =>
      _state = _state.copyWith(positionUs: positionUs < 0 ? 0 : positionUs);

  /// Advance the playhead by [elapsedUs] of wall time, scaled by [tempoRatio]
  /// (faster tempo ⇒ more track consumed). No-op while paused.
  void advance(int elapsedUs) {
    if (!_state.isPlaying) return;
    final advanced = (elapsedUs * _state.tempoRatio).round();
    _state = _state.copyWith(positionUs: _state.positionUs + advanced);
  }

  /// Set the pitch fader. [ratio] is clamped to a sane DJ range (±8% is the
  /// classic Technics window, but BPM-match can need more, so allow 0.5–2.0).
  void setTempoRatio(double ratio) =>
      _state = _state.copyWith(tempoRatio: ratio.clamp(0.5, 2.0));

  /// Tempo-match this deck to [targetBpm] (requires the track's [bpm] known).
  /// Returns the new ratio, or null if there's nothing to match.
  double? matchTempo(double targetBpm) {
    final base = _state.bpm;
    if (base == null || base <= 0) return null;
    final ratio = (targetBpm / base).clamp(0.5, 2.0);
    _state = _state.copyWith(tempoRatio: ratio);
    return ratio;
  }

  void setGain(double gain) =>
      _state = _state.copyWith(gain: gain.clamp(0.0, 1.0));

  void toggleKill(EqKill band) {
    final next = Set<EqKill>.from(_state.kills);
    if (!next.remove(band)) next.add(band);
    _state = _state.copyWith(kills: next);
  }

  void setKill(EqKill band, bool engaged) {
    final next = Set<EqKill>.from(_state.kills);
    if (engaged) {
      next.add(band);
    } else {
      next.remove(band);
    }
    _state = _state.copyWith(kills: next);
  }

  void addCue(HotCue cue) {
    final next = [
      for (final c in _state.cues)
        if (c.index != cue.index) c,
      cue
    ]..sort((a, b) => a.index.compareTo(b.index));
    _state = _state.copyWith(cues: next);
  }

  /// Jump the playhead to the cue in [slot], if it exists. Returns true on hit.
  bool jumpToCue(int slot) {
    for (final c in _state.cues) {
      if (c.index == slot) {
        seek(c.positionUs);
        return true;
      }
    }
    return false;
  }

  /// The [EqBand] list realizing the deck's currently engaged kills, ready to
  /// hand to a [ParametricEq] in the deck's render path. An empty result means
  /// "no kills" → callers can skip the EQ stage entirely.
  List<EqBand> killEqBands() => bandsForKills(_state.kills);

  /// Pure helper: the EQ cut bands for an arbitrary kill set (also used by the
  /// crossfader/tests without a deck instance).
  static List<EqBand> bandsForKills(Set<EqKill> kills) => [
        if (kills.contains(EqKill.low))
          const EqBand(
              type: EqBandType.lowShelf, freqHz: lowKillHz, gainDb: killGainDb),
        if (kills.contains(EqKill.mid))
          const EqBand(
              type: EqBandType.peaking,
              freqHz: midKillHz,
              q: 0.9,
              gainDb: killGainDb),
        if (kills.contains(EqKill.high))
          const EqBand(
              type: EqBandType.highShelf,
              freqHz: highKillHz,
              gainDb: killGainDb),
      ];
}
