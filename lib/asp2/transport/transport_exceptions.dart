/// Thrown when a transport cannot be brought up because the platform support it
/// needs is absent: a native plugin not linked, a cloud SFU not configured, or a
/// protocol the OS does not expose. Carries [transport] (the failed transport's
/// name) and [reason] (a human-readable, deferral-aware explanation) so the
/// facade can fall back to another [ITransport] cleanly instead of crashing.
///
/// Used by the Phase 4 service/native-bound transports (WebRTC SFU, QUIC) that
/// build against the interface but defer their real backend — the same
/// "scaffold + capability probe + documented deferral" discipline the prior
/// phases used for native codec/DSP binaries.
class TransportUnavailableException implements Exception {
  final String transport;
  final String reason;

  const TransportUnavailableException(this.transport, this.reason);

  @override
  String toString() => 'TransportUnavailableException($transport): $reason';
}
