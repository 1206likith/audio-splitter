/// Process-wide ASP-2 feature flags.
///
/// Phase 1 lands the real codec/crypto/FEC machinery but keeps the on-wire
/// default as v1's legacy PCM16 + AES-CTR frame so nothing regresses before a
/// real two-device verification. Flip [useAsp2Wire] to true to send the new
/// ASP-2 frame (Opus + ChaCha20-Poly1305 + FEC) between native peers; the web
/// client always stays on the legacy room until the Phase 7 WASM rewrite.
class Asp2Config {
  Asp2Config._();

  /// When true, native↔native sessions negotiate and use the ASP-2 frame.
  /// Default false: gated on the Phase 1 two-physical-device smoke test
  /// (Windows host ↔ Android client) which can't run in this dev/CI sandbox.
  static bool useAsp2Wire = false;

  /// Default FEC parameters (doc: k=8 data, m=2 parity → survives ~20% loss).
  static const int fecDataShards = 8;
  static const int fecParityShards = 2;

  /// Session key rotation interval (doc: 5 minutes).
  static const Duration keyRotationInterval = Duration(minutes: 5);
}
