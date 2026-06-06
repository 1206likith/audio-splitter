# Security Audit — Audio Splitter v2 (Phase 8)

Scope: the ASP-2 protocol stack (`lib/asp2/**`) — frame codec, FEC, crypto
envelope, control plane, and the new access-control / recording-consent
primitives. This is the Phase 8 hardening audit: a threat model, the findings
and their remediations, a crypto review, and the residual risk register. It is a
white-box review of the pure-Dart engine; live transport wiring and the native
FFI codecs are scaffolds and are noted where relevant.

---

## 1. Threat model

**Assets:** session audio confidentiality + integrity, host availability, device
identity, and recording-consent integrity.

**Adversaries:**

* **A1 — On-path network attacker.** Can read, drop, reorder, replay, and inject
  arbitrary bytes on the media + control channels.
* **A2 — Malicious participant.** A connected client sending well-formed but
  unauthorized or hostile messages (privilege escalation, resource exhaustion).
* **A3 — Malicious/compromised peer in a mesh relay.** Forwards corrupt FEC
  shards or control frames.

**Trust boundaries:** every byte entering a `decode`/`recover`/`open` is
untrusted. The host process is trusted; plugins (SDK v1) are compile-time linked
and in-trust for now (see §5).

---

## 2. Findings & remediations (this phase)

### F-1 — `FecGroup.recover` could crash on hostile FEC input — **High → Fixed**

`recover` is on the receive path (A1/A3) and consumed attacker-controlled shard
indices, payload lengths, and `shardLen`. Three crash paths existed:

1. **Out-of-range / negative shard index** → null-assert (`dataByIndex[i]!`) or
   an out-of-bounds list write threw.
2. **Corrupt `shardLen` or oversized surviving payload** → `_pack`'s `setRange`
   threw `RangeError`.
3. **Corrupt embedded length prefix in a *recovered* shard** → `_unpack`'s
   `sublist` threw `RangeError` *outside* the existing `try/catch`, so it
   propagated out of `recover`.

A single crafted shard could therefore crash the receiver (DoS).

**Remediation:** `recover` now validates `shardLen ≥ lenPrefix`, rejects any
index outside `[0, dataShards)` / `[0, parityShards)`, rejects a surviving
payload longer than the shard, requires parity shards to be exactly `shardLen`,
and routes recovered shards through a nullable `_unpack` that bounds-checks the
length prefix. Every malformed path now returns `null` (→ Opus PLC), never
throws. Verified by `test/fuzz/asp2_fuzz_test.dart` (4000 hostile iterations,
asserted `returnsNormally`).

### F-2 — `ControlMessage.decode` threw on malformed control input — **Medium → Fixed**

`decode(String)` could throw `FormatException` (bad JSON), `TypeError`
(non-object root, missing/non-object `data`), or `ArgumentError` (unknown `type`
via `values.byName`). An A1/A2 adversary could crash a control-plane handler
that didn't wrap every receive in a `try`.

**Remediation:** added `ControlMessage.tryDecode(String) → ControlMessage?`
which never throws and drops malformed messages. The receive path uses it.
`decode` is retained (strict) for trusted/local use. Fuzzed in
`asp2_fuzz_test.dart`. *Residual:* per-type payload accessors (`asZoneRoute`,
etc.) still assume a well-formed envelope; callers must wrap per-type decoding
when the payload itself is untrusted — tracked as R-3.

### F-3 — Privileged control actions had no authorization model — **Medium → Mitigated**

Any connected client (A2) could send a `zoneRoute`, `zoneRemove`, or a
recording-start with no role check. **Remediation:** added RBAC
(`lib/asp2/security/permissions.dart`) — four ordered roles and capability gates
(`AccessControl.require` throws `PermissionDenied`). *Residual:* the host must
actually call `require(...)` at each privileged dispatch site when the live
control wiring lands — tracked as R-1.

### F-4 — No recording-consent enforcement — **Medium → Mitigated**

Recording a multi-party session has legal consent requirements with no
enforcement point. **Remediation:** added an all-party consent gate
(`lib/asp2/security/recording_consent.dart`): recording arms only while every
present participant has granted consent; a new joiner or a revocation gates it
off. *Residual:* the consent UI and the host's stop-on-revoke wiring are
deferred — tracked as R-2.

---

## 3. Crypto review

The AEAD/handshake layer (`lib/asp2/crypto/**`, backed by
`package:cryptography`) reviewed as **sound by design**:

| Property            | Assessment                                                              |
|---------------------|-------------------------------------------------------------------------|
| AEAD                | ChaCha20-Poly1305-IETF, 16-byte tag. ✅                                  |
| Fail-closed         | `Asp2AeadBox.open` returns `null` on any auth failure — never fails open. ✅ |
| AAD binding         | 20-byte header is the AAD; header tampering is detected. ✅              |
| Nonce uniqueness    | 4-byte salt ++ 8-byte counter; 64-bit space + 5-min rotation. ✅         |
| Forward secrecy     | Ephemeral X25519 per session, discarded after. ✅                        |
| MITM resistance     | Ed25519 device identity signs the ephemeral key. ✅                      |
| Key derivation      | HKDF-SHA256 with domain-separation info `"ASP2-session"`. ✅             |

**Crypto observations (not defects):**

* **C-1 (replay).** AEAD authenticates a frame but does not by itself reject a
  replayed valid frame. The `sequence_no` is authenticated (in the AAD), so a
  per-stream replay window/high-water-mark *can* be enforced cheaply; the
  receiver should track it. Tracked as R-4.
* **C-2 (nonce salt source).** `NonceSequencer.fromSalt` takes caller-supplied
  randomness (kept testable / `Math.random`-free). Production callers must seed
  it from a CSPRNG (platform secure random), and **must not** reuse a salt+key
  epoch across restarts without rotating the key. Documented requirement.
* **C-3 (identity persistence).** The Ed25519 seed must be stored in platform
  secure storage (Keychain / Keystore / DPAPI), never in plaintext prefs. App-
  layer requirement.

---

## 4. Availability / DoS surface

* Decode surfaces are now crash-safe (F-1, F-2) and fuzzed.
* **Unbounded work:** FEC group size, control-message rate, and per-client mix
  contributions should be rate-/size-capped at the transport boundary to bound
  CPU and memory under A2/A3 flooding. Tracked as R-5 (transport-layer, lands
  with live wiring).

---

## 5. Plugin trust

Plugin SDK v1 plugins are compile-time linked and run in-process with full
trust. A dynamic, disk-loaded plugin host MUST sandbox plugins (isolate +
capability scoping + no ambient FS/network) before untrusted plugins are
allowed. Tracked as R-6.

---

## 6. Residual risk register

| ID  | Risk                                                        | Severity | Owner / when            |
|-----|-------------------------------------------------------------|----------|-------------------------|
| R-1 | RBAC `require()` not yet called at live dispatch sites      | Medium   | live control wiring     |
| R-2 | Recording-consent UI + stop-on-revoke wiring deferred       | Medium   | recording UI            |
| R-3 | Per-type control payload accessors can throw on bad payload | Low      | wrap at dispatch        |
| R-4 | No replay-window enforcement on `sequence_no`               | Medium   | receiver state          |
| R-5 | No transport-layer rate/size caps (flood DoS)               | Medium   | live transport          |
| R-6 | Dynamic plugin sandboxing (future SDK major)                | High*    | when disk-load plugins land |

\* R-6 is High *only if/when* untrusted disk-loaded plugins are enabled; not a
risk for the current compile-time SDK.

---

## 7. Verification

* `test/fuzz/asp2_fuzz_test.dart` — fuzzes all decode surfaces (F-1, F-2).
* `test/asp2/security_test.dart` — RBAC inheritance/denial + consent gate (F-3, F-4).
* `test/bench/asp2_bench_test.dart` — throughput ceilings for the DoS analysis.
* External pen-test and the 72-hour soak are `[needs-service]` /
  `[needs-real-world]` and tracked as pending.
