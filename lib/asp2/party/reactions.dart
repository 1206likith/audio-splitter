/// A crowd reaction kind. Each maps to an emoji the UI floats up the screen and
/// contributes to the live energy meter.
enum ReactionType {
  fire,
  heart,
  clap,
  star,
  wave,
  raiseHands;

  /// The emoji a client renders for this reaction.
  String get emoji {
    switch (this) {
      case ReactionType.fire:
        return '🔥';
      case ReactionType.heart:
        return '❤️';
      case ReactionType.clap:
        return '👏';
      case ReactionType.star:
        return '⭐';
      case ReactionType.wave:
        return '👋';
      case ReactionType.raiseHands:
        return '🙌';
    }
  }
}

/// One reaction event from one client at one host-clock timestamp.
class Reaction {
  final ReactionType type;
  final String clientId;
  final int tsUs;

  const Reaction({
    required this.type,
    required this.clientId,
    required this.tsUs,
  });

  Map<String, dynamic> toJson() =>
      {'type': type.name, 'clientId': clientId, 'tsUs': tsUs};

  factory Reaction.fromJson(Map<String, dynamic> json) => Reaction(
        type: ReactionType.values.byName(json['type'] as String),
        clientId: json['clientId'] as String,
        tsUs: (json['tsUs'] as num).toInt(),
      );

  @override
  String toString() => 'Reaction(${type.emoji} ${type.name}, $clientId)';
}

/// Aggregates the reaction stream into a live **energy meter**: how lit the
/// crowd is right now, plus per-type tallies for the host's dashboard.
///
/// Energy is a sliding-window reaction *rate* normalized against a saturation
/// count, so it rises as reactions pour in and decays as the window moves past
/// them. Everything is driven by the timestamps passed in (no wall clock), so a
/// replay of the same events yields the same curve.
class EnergyMeter {
  /// Sliding window width in microseconds (default 5 s).
  final int windowUs;

  /// Reactions-in-window that map to full energy (1.0).
  final int saturationCount;

  final List<Reaction> _events = [];

  EnergyMeter({
    this.windowUs = 5000000,
    this.saturationCount = 30,
  }) : assert(saturationCount > 0, 'saturationCount must be positive');

  void add(Reaction r) => _events.add(r);

  /// Drop events older than the window ending at [nowUs] (call periodically to
  /// bound memory; energy queries already ignore them).
  void prune(int nowUs) {
    final cutoff = nowUs - windowUs;
    _events.removeWhere((e) => e.tsUs < cutoff);
  }

  int _countInWindow(int nowUs) {
    final cutoff = nowUs - windowUs;
    var n = 0;
    for (final e in _events) {
      if (e.tsUs > cutoff && e.tsUs <= nowUs) n++;
    }
    return n;
  }

  /// Crowd energy in `[0.0, 1.0]` at [nowUs].
  double energyAt(int nowUs) =>
      (_countInWindow(nowUs) / saturationCount).clamp(0.0, 1.0);

  /// Per-type counts within the window ending at [nowUs].
  Map<ReactionType, int> tallyAt(int nowUs) {
    final cutoff = nowUs - windowUs;
    final out = <ReactionType, int>{};
    for (final e in _events) {
      if (e.tsUs > cutoff && e.tsUs <= nowUs) {
        out[e.type] = (out[e.type] ?? 0) + 1;
      }
    }
    return out;
  }

  /// Distinct clients reacting within the window ending at [nowUs] — a rough
  /// "how many people are actively engaged" gauge.
  int activeClientsAt(int nowUs) {
    final cutoff = nowUs - windowUs;
    final ids = <String>{};
    for (final e in _events) {
      if (e.tsUs > cutoff && e.tsUs <= nowUs) ids.add(e.clientId);
    }
    return ids.length;
  }

  int get totalReceived => _events.length;
}

/// A simple host-run crowd **poll/vote** (e.g. "next genre?"). Each client gets
/// one vote; recasting moves the vote. Deterministic tally.
class Poll {
  final String id;
  final String question;
  final List<String> options;
  final Map<String, int> _votes = {}; // clientId -> option index

  Poll({
    required this.id,
    required this.question,
    required this.options,
  }) : assert(options.length >= 2, 'a poll needs at least two options');

  /// Cast (or recast) [clientId]'s vote for [optionIndex]. Returns false if the
  /// option index is out of range.
  bool vote(String clientId, int optionIndex) {
    if (optionIndex < 0 || optionIndex >= options.length) return false;
    _votes[clientId] = optionIndex;
    return true;
  }

  /// Votes per option, indexed parallel to [options].
  List<int> tally() {
    final counts = List<int>.filled(options.length, 0);
    for (final idx in _votes.values) {
      counts[idx]++;
    }
    return counts;
  }

  int get totalVotes => _votes.length;

  /// Winning option index (lowest index wins ties — deterministic), or null when
  /// no votes are in.
  int? get winner {
    if (_votes.isEmpty) return null;
    final counts = tally();
    var best = 0;
    for (var i = 1; i < counts.length; i++) {
      if (counts[i] > counts[best]) best = i;
    }
    return best;
  }
}
