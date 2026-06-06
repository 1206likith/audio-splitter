/// Recording-consent gate (Phase 8 security + privacy).
///
/// Recording a live, multi-party audio session implicates wiretap / two-party
/// consent law (e.g. GDPR, US all-party-consent states). The plan lists a
/// "recording consent UI"; this is the enforceable core that UI drives.
///
/// The rule modelled here is **all-party consent**: a recording may only run
/// while every currently-present participant has explicitly granted consent. A
/// new participant joins in the [ConsentState.unknown] state (recording gates
/// off until they answer), a denial gates it off immediately, and a participant
/// leaving drops their vote from the tally. The host calls [canStartRecording]
/// before arming the [SessionRecorder] and watches it during a recording —
/// if it flips false (someone joined or revoked), recording must stop.
///
/// Pure state, no I/O and no clock — fully unit-testable; the consent prompts,
/// persistence, and the on-air indicator live in the (deferred) UI layer.
library;

/// One participant's answer to "may this session be recorded?".
enum ConsentState {
  /// Present but has not yet answered — blocks recording.
  unknown,

  /// Explicitly agreed to be recorded.
  granted,

  /// Explicitly refused — blocks recording.
  denied,
}

/// Tracks per-participant recording consent and answers the all-party gate.
class RecordingConsent {
  final Map<String, ConsentState> _byClient = {};

  /// Register a participant as present. Idempotent; an existing answer is kept
  /// (re-joining after a network blip doesn't silently reset consent).
  void join(String clientId) =>
      _byClient.putIfAbsent(clientId, () => ConsentState.unknown);

  /// Record a participant's explicit answer (joining them if new).
  void setConsent(String clientId, bool granted) {
    _byClient[clientId] = granted ? ConsentState.granted : ConsentState.denied;
  }

  /// A participant left the session; their consent no longer counts.
  void leave(String clientId) => _byClient.remove(clientId);

  /// The current answer for [clientId] (or null if not present).
  ConsentState? stateOf(String clientId) => _byClient[clientId];

  /// All present participant ids.
  Iterable<String> get participants => _byClient.keys;

  /// Participants who have not (yet) granted — i.e. the reason recording is
  /// blocked. Empty iff [canStartRecording] is true.
  List<String> get blockers => [
        for (final e in _byClient.entries)
          if (e.value != ConsentState.granted) e.key,
      ];

  /// True only when at least one participant is present and **every** present
  /// participant has granted consent. With nobody present there is nothing to
  /// record and nobody to consent, so it is false.
  bool get canStartRecording =>
      _byClient.isNotEmpty &&
      _byClient.values.every((s) => s == ConsentState.granted);
}
