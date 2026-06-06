/// A crowd track request — a listener asks the DJ to play something. Requests
/// are upvoted by the crowd and approved by the host; ranking is by upvotes then
/// submission order, so the queue is a deterministic function of its events (no
/// clock, no random — important for the same reasons as the rest of ASP-2).
class TrackRequest {
  /// Stable request id (caller-supplied; e.g. a uuid minted on the client).
  final String id;

  /// What's being requested — a track id, or free text ("play some Daft Punk").
  final String query;

  /// Client id of the requester.
  final String requestedBy;

  /// Monotonic submission sequence, assigned by [RequestQueue] on submit. Used
  /// as the deterministic tie-break so equal-upvote requests keep FIFO order.
  final int seq;

  /// Client ids that have upvoted (a set, so a client can't double-vote).
  final Set<String> upvoters;

  /// Host has approved this request for play.
  final bool approved;

  /// Host has played/dismissed it (kept for history, hidden from the live list).
  final bool done;

  const TrackRequest({
    required this.id,
    required this.query,
    required this.requestedBy,
    required this.seq,
    this.upvoters = const {},
    this.approved = false,
    this.done = false,
  });

  /// Upvote count. The requester implicitly counts as one vote.
  int get votes => ({requestedBy, ...upvoters}).length;

  TrackRequest copyWith({
    Set<String>? upvoters,
    bool? approved,
    bool? done,
  }) =>
      TrackRequest(
        id: id,
        query: query,
        requestedBy: requestedBy,
        seq: seq,
        upvoters: upvoters ?? this.upvoters,
        approved: approved ?? this.approved,
        done: done ?? this.done,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'query': query,
        'requestedBy': requestedBy,
        'seq': seq,
        'upvoters': upvoters.toList(),
        'approved': approved,
        'done': done,
      };

  factory TrackRequest.fromJson(Map<String, dynamic> json) => TrackRequest(
        id: json['id'] as String,
        query: json['query'] as String,
        requestedBy: json['requestedBy'] as String,
        seq: (json['seq'] as num).toInt(),
        upvoters: {
          for (final u in (json['upvoters'] as List? ?? const [])) u as String,
        },
        approved: json['approved'] as bool? ?? false,
        done: json['done'] as bool? ?? false,
      );

  @override
  String toString() =>
      'TrackRequest($id "$query", ${votes}v, approved=$approved, done=$done)';
}

/// The host-side crowd request queue. Listeners [submit] requests, the crowd
/// [upvote]s, the host [approve]s and [markDone]s. [ranked] is the live ordering
/// the DJ sees: most-upvoted first, ties broken by submission order.
class RequestQueue {
  final Map<String, TrackRequest> _byId = {};
  int _nextSeq = 0;

  /// Submit a new request (or, if [id] already exists, return the existing one
  /// unchanged — submission is idempotent on id). Returns the stored request.
  TrackRequest submit({
    required String id,
    required String query,
    required String requestedBy,
  }) {
    final existing = _byId[id];
    if (existing != null) return existing;
    final req = TrackRequest(
      id: id,
      query: query,
      requestedBy: requestedBy,
      seq: _nextSeq++,
    );
    _byId[id] = req;
    return req;
  }

  /// Add [clientId]'s upvote to [requestId]. No-op if the request is unknown or
  /// the client already voted. Returns the updated request (or null if unknown).
  TrackRequest? upvote(String requestId, String clientId) {
    final req = _byId[requestId];
    if (req == null) return null;
    if (req.upvoters.contains(clientId) || req.requestedBy == clientId) {
      return req;
    }
    final updated = req.copyWith(upvoters: {...req.upvoters, clientId});
    _byId[requestId] = updated;
    return updated;
  }

  TrackRequest? approve(String requestId) => _set(requestId, approved: true);
  TrackRequest? reject(String requestId) => _set(requestId, done: true);
  TrackRequest? markDone(String requestId) => _set(requestId, done: true);

  TrackRequest? _set(String requestId, {bool? approved, bool? done}) {
    final req = _byId[requestId];
    if (req == null) return null;
    final updated = req.copyWith(approved: approved, done: done);
    _byId[requestId] = updated;
    return updated;
  }

  /// All live (not-done) requests, most-upvoted first; equal votes keep FIFO
  /// (submission) order. Deterministic.
  List<TrackRequest> ranked() {
    final live = _byId.values.where((r) => !r.done).toList();
    live.sort((a, b) {
      final byVotes = b.votes.compareTo(a.votes);
      if (byVotes != 0) return byVotes;
      return a.seq.compareTo(b.seq);
    });
    return live;
  }

  /// Approved-and-not-done requests in rank order (the DJ's "up next" list).
  List<TrackRequest> approvedQueue() =>
      ranked().where((r) => r.approved).toList();

  /// The current top pick the host would likely play next (highest-ranked
  /// approved request), or null if none approved.
  TrackRequest? get nextUp {
    final q = approvedQueue();
    return q.isEmpty ? null : q.first;
  }

  int get length => _byId.values.where((r) => !r.done).length;

  TrackRequest? byId(String id) => _byId[id];
}
