# Deployment Guide

How to build, run, and operate Audio Splitter v2 across the supported targets,
and what each optional capability needs before it lights up.

---

## 1. Toolchain

* **Flutter** (Dart SDK bundled). This repo is developed against the Flutter
  install at `F:\Apps\Flutter\flutter`.
* CI gate (also the local pre-commit gate):

  ```
  dart format --output=none --set-exit-if-changed lib test
  flutter analyze
  flutter test
  ```

  `dart format` reflows new files, so run it in write mode before the check.

---

## 2. Build targets

| Target          | Buildable here | Notes                                          |
|-----------------|----------------|------------------------------------------------|
| Windows desktop | ✅ (dev)       | host + client                                  |
| Android         | ✅ (dev)       | NDK r27+, 16 KB page alignment for native libs |
| Web (legacy)    | ✅             | embedded room; being replaced by the PWA       |
| Web (PWA)       | ⏸ `[needs-node]` | `web/asp2-client` Vite/TS app — `npm` required |
| iOS / macOS     | ⏸ `[needs-Mac]`  | deferred to CI mac runners                      |
| Linux           | ⏸             | needs the platform folder + runner             |

### Windows native libraries

Optional native codecs/DSP (`opus.dll`, `rnnoise.dll`, …) are copied next to the
runner via a `POST_BUILD` step in `windows/runner/CMakeLists.txt`. Until a
binary is present, the matching feature reports `isAvailable == false` and a
pure-Dart fallback runs. See `third_party/README.md`.

### Android native libraries

Ship one `.so` per ABI under `android/app/src/main/jniLibs/<abi>/`. Pin
`ndkVersion` in `android/app/build.gradle`. Don't commit large binaries to git
history — use Git LFS or the CI download-and-cache step.

---

## 3. Running a session

1. **Host** on the Windows desktop (or an Android device). The host opens the
   WebSocket transport, advertises via mDNS (`_asplitter._tcp`, IPv4 + IPv6),
   and accepts clients.
2. **Clients** discover the host (mDNS, or manual IP) and connect.
3. Audio flows host → clients as ASP-2 frames; the control plane carries clock
   sync (PTP-lite), telemetry, and routing.

The native↔native wire can run encrypted ASP-2 (`useAsp2Wire = true`); browsers
on the legacy room run the v1 PCM16 path until they migrate to the PWA.

---

## 4. Optional / external capabilities

Each is implemented against an interface with a software simulator or pure-Dart
fallback, and reports unavailable until its dependency is provided — never a
silent skip.

| Capability                         | Needs                              | Fallback                         |
|------------------------------------|------------------------------------|----------------------------------|
| Opus codec                         | `libopus` binary `[needs-FFI]`     | PCM16                            |
| RNNoise / WebRTC APM denoise       | `librnnoise` / APM `[needs-FFI]`   | pure-Dart EQ/comp/limiter        |
| WebRTC / SFU transport             | LiveKit/mediasoup `[needs-service]`| LAN WebSocket + mesh relay       |
| QUIC transport                     | QUIC service `[needs-service]`     | WebSocket                        |
| Bluetooth A2DP / LE Audio sink     | BT hardware `[needs-hardware]`     | local playback                   |
| DMX / Hue / LIFX lighting          | rig / bulbs `[needs-hardware]`     | flashlight strobe + screen ambient |
| MIDI DJ controller                 | controller `[needs-hardware]`      | on-screen deck                   |
| Steam Audio HRTF / whisper STT     | SDK + model `[needs-FFI]`          | BinauralPanner / ScriptedStt     |
| BLE/UWB positioning, head tracking | beacons / earbuds `[needs-hardware]`| tap-on-floorplan                |
| MP3 / Ogg-Opus export              | `libmp3lame` / `libopus` `[needs-FFI]` | WAV / FLAC                  |
| Cloud sync                         | S3/R2 `[needs-service]`            | local `.zip` bundle              |
| Telemetry dashboards               | Prometheus+Grafana `[needs-service]`| in-app `ClientSyncReport`        |

---

## 5. Capacity (from the Phase 8 benchmarks)

Measured on the dev machine (`test/bench/asp2_bench_test.dart`); indicative, not
a guarantee:

* **Frame codec:** ~620k frames/s (~2.4 GB/s payload) — at 50 frames/s/stream,
  ample headroom for thousands of concurrent streams on the frame layer.
* **FEC (k=8/m=2):** ~11k encode and ~11k recover groups/s.
* **Mixer (4→2ch, 20 ms):** ~250k blocks/s.
* **DSP master chain (EQ→comp→limiter):** ~6k blocks/s — ~120 simultaneous
  20 ms zones per core before the DSP stage saturates.

The mixer and DSP chain are the first ceilings on a mobile host; profile on the
lowest-spec target and offload to a relay/SFU beyond it.

---

## 6. Soak & beta (operational gate)

The Phase 8 close-out gate is a **72-hour soak** (zero crashes / leaks /
dropouts) plus deployment at **3 real venues**. Both are `[needs-real-world]`:
they require sustained multi-device hardware time and venue access, and are
tracked as pending external validation. The automated hardening that de-risks
them — the protocol fuzzer and the benchmarks — runs in CI today.
