# ASP-2 Protocol Specification (v2)

Audio Splitter Protocol v2 (**ASP-2**) is the layered, versioned wire protocol
that carries real-time audio and session control across the Audio Splitter
fabric. This document is the normative reference for the binary media frame, the
control plane, the crypto envelope, and the FEC scheme. It is the source of
truth that both the Dart engine (`lib/asp2/**`) and the TypeScript web client
(`web/asp2-client/src/asp2/**`) implement, and is pinned on both sides by a
shared golden vector (`web/asp2-client/test/golden_frame.json`).

> Endianness: **all multi-byte integers are little-endian** unless stated
> otherwise. Versions are 4-bit; this document describes `version = 2`.

---

## 1. Layered model

ASP-2 is strictly layered; a lower layer never depends on an upper one:

```
Sources → Pre-DSP → Source Router (DAG) → Mix/Split → Codec
       → Frame + FEC + Crypt → Transport Mux → Time Sync → Sinks
                          ⇅ Control Plane (parallel reliable channel)
```

Two channels run in parallel:

* **Media path** — the real-time, lossy-tolerant binary frame (§2). One frame
  carries one codec packet for one stream.
* **Control plane** — a reliable, low-rate JSON channel (§5) carrying everything
  *about* the session: clock sync, telemetry, routing, beat grids, reactions,
  captions, listener pose.

---

## 2. Binary media frame

A frame is a fixed 20-byte header, an opaque payload, and — when encrypted — a
16-byte authentication tag and a 12-byte nonce.

```
Offset  Size  Field          Notes
------  ----  -------------  ---------------------------------------------------
0       1     version|flags  high nibble = version (2), low nibble = flags
1       1     codec_id       0=PCM16, 1=Opus, 2=LC3, 3=FLAC, 4..15 reserved
2       2     stream_id      u16 — zone / track identifier
4       4     sequence_no    u32 — monotonic per stream
8       8     pts_us         u64 — presentation timestamp, host-clock µs
16      2     payload_len    u16 — length of the payload field
18      1     fec_group_id   0 = not in a FEC group; else 1..255
19      1     fec_index      data index, or (dataShards + parityIndex) for parity
20      N     payload        codec packet; ciphertext when encrypted
20+N    16    poly1305_tag   present only when the encrypted flag is set
36+N    12    aead_nonce     present only when the encrypted flag is set
```

### 2.1 Flags (low nibble of byte 0)

| Bit  | Name        | Meaning                                              |
|------|-------------|------------------------------------------------------|
| 0x1  | encrypted   | Payload is ciphertext; tag + nonce trail the payload |
| 0x2  | parity      | This frame is an FEC parity shard, not media data    |
| 0x4  | reserved    | Must be 0 in v2                                       |
| 0x8  | reserved    | Must be 0 in v2                                       |

### 2.2 Header as AEAD associated data

The 20-byte header **is** the AEAD associated data (AAD). The header bound into
the tag is the header *as it appears on the wire* — i.e. with the `encrypted`
flag set and `payload_len` equal to the ciphertext length (which equals the
plaintext length, since ChaCha20 is a stream cipher). Any tampering with
`codec_id`, `stream_id`, `sequence_no`, `pts_us`, or the FEC fields therefore
fails authentication and the frame is dropped.

### 2.3 Decoder robustness (normative)

`Asp2Frame.decode` MUST reject a malformed or truncated buffer by throwing a
`FormatException` (the transport then drops it) and MUST NOT throw any other
error type or read out of bounds. Specifically:

* a buffer shorter than 20 bytes → `FormatException`;
* a buffer shorter than `20 + payload_len (+ 28 when encrypted)` → `FormatException`;
* trailing bytes beyond the declared frame are ignored.

This is enforced by the protocol fuzzer (`test/fuzz/asp2_fuzz_test.dart`).

---

## 3. Codec layer

`codec_id` selects the payload codec. The codec is opaque to the frame layer.

| id | codec  | status          | packetization                          |
|----|--------|-----------------|----------------------------------------|
| 0  | PCM16  | live (pure Dart)| raw interleaved s16le                  |
| 1  | Opus   | FFI scaffold    | one Opus packet, 20 ms / 960 samples   |
| 2  | LC3    | reserved        | —                                      |
| 3  | FLAC   | live (record)   | used by the recording path, not the wire |

PCM16 (`Pcm16Codec`) is the default low-latency LAN codec and the CI baseline;
Opus is enabled when the native binary is present (see `third_party/README.md`).

---

## 4. FEC scheme (Reed-Solomon over GF(256))

Lost packets are *erasures at known positions* — the frame's `fec_index` says
which shard each packet was — so recovery is a single matrix solve, never an
error-location search.

* Default group: **k = 8 data shards, m = 2 parity** (survives 2-of-10 = 20%
  loss). `fec_group_id = 0` is the low-latency no-FEC path.
* Variable-length payloads are packed as `[u16 len][payload][zero pad]` to the
  group's max length before parity, so the original length rides inside the
  FEC-protected data and a recovered shard trims exactly.
* The GF(256) field uses primitive polynomial `0x11D`, interoperable with
  mainstream (Backblaze / klauspost) implementations.
* An unrecoverable group (fewer than k shards survived, or any shard/length is
  corrupt) yields no output; the receiver falls back to Opus PLC.

`FecGroup.recover` is on the receive path and treats every index, length, and
`shardLen` as hostile: out-of-range indices, a bogus `shardLen`, or a corrupt
embedded length prefix all return `null` rather than throwing (Phase 8
hardening, fuzzed in `test/fuzz/asp2_fuzz_test.dart`).

---

## 5. Control plane

The control plane is a reliable, low-rate JSON channel: `{"type": "...",
"data": {...}}`. `type` is one of `ControlMessageType`:

| type           | direction       | payload            | phase |
|----------------|-----------------|--------------------|-------|
| `ptpProbe`     | client → host   | `PtpProbe`         | 2     |
| `ptpResponse`  | host → client   | `PtpResponse`      | 2     |
| `syncReport`   | client → host   | `ClientSyncReport` | 2     |
| `zoneRoute`    | host → clients  | `ZoneRoute`        | 3     |
| `zoneRemove`   | host → clients  | `{zoneId}`         | 3     |
| `beatGrid`     | host → clients  | `BeatGrid`         | 5     |
| `reaction`     | client → host   | `Reaction`         | 5     |
| `caption`      | host → clients  | `CaptionLine`      | 5/6   |
| `listenerPose` | client → host   | `ListenerPose`     | 6     |

Receive path: `ControlMessage.tryDecode(String)` MUST NOT throw — malformed
JSON, a non-object root, a missing/non-object `data`, or an unknown `type` all
return `null` and the message is dropped. Privileged message types are
additionally gated by RBAC (§6).

---

## 6. Security envelope

* **AEAD:** ChaCha20-Poly1305-IETF (12-byte nonce). The IETF variant is chosen
  over XChaCha20 so the 12-byte nonce fits the frame as drawn. `open` never
  fails open: an authentication failure drops the frame.
* **Nonce:** 4-byte random session salt ++ 8-byte LE counter, unique per key
  epoch. Never reuse a (key, nonce) pair.
* **Handshake:** X25519 ECDH → HKDF-SHA256 (info `"ASP2-session"`) → 32-byte
  AEAD key. Ephemeral keys give forward secrecy.
* **Identity:** Ed25519 device keypair signs the ephemeral X25519 public key,
  preventing a MITM from swapping in their own ephemeral key.
* **Key rotation:** every 5 minutes a fresh exchange replaces the session key.
* **Roles:** four roles (`listener` < `dj` < `moderator` < `admin`) gate every
  privileged control action via capabilities (`lib/asp2/security/permissions.dart`).
* **Recording consent:** all-party consent gate
  (`lib/asp2/security/recording_consent.dart`) — recording may run only while
  every present participant has granted consent.

See `docs/security-audit.md` for the full threat model and findings.

---

## 7. Versioning

The 4-bit version field allows 16 protocol generations. A receiver MUST drop a
frame whose version it does not implement. New message types extend the control
plane's `type` enum; an unknown `type` is dropped, so forward-compatible
additions never crash an older client.
