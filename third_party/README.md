# third_party — vendored native binaries (libopus, librnnoise, et al.)

Phase 1 introduces the first native dependency: **libopus**, called from Dart via
`dart:ffi`. The Dart side (`lib/asp2/codec/`) is committed and unit-tested; the
native binaries are **not** checked into this README's directory by default —
they are large and platform-specific. Drop them in (or wire the CI cache below)
to light up the real Opus codec. Until then, `OpusCodec.tryCreate()` returns
`null` and the app falls back to PCM16 — nothing breaks.

Phase 2 adds a second optional native dependency, **librnnoise** (neural voice
denoise), introduced through the exact same load-probe contract
(`RnnoiseDenoiser.tryCreate()` → `null` when absent → the DSP chain omits the
denoise stage and the pure-Dart EQ/compressor/limiter still run). See
[librnnoise](#librnnoise-phase-2-voice-denoise) below. The WebRTC
`audio_processing` module (AGC/AEC/VAD) is the next planned FFI sibling and is
**deferred** — its binary is heavier and its build is documented but not yet
wired.

## Where each platform looks for the library

`OpusCodec` calls `DynamicLibrary.open(...)` with these names, in order:

| Platform | Filename(s)                    | Where to place it                                                |
|----------|--------------------------------|------------------------------------------------------------------|
| Windows  | `opus.dll`, `libopus.dll`      | next to the built `.exe` (copied via `windows/runner/CMakeLists.txt`, see below) |
| Android  | `libopus.so`                   | `android/app/src/main/jniLibs/<abi>/libopus.so`                  |
| Linux    | `libopus.so`, `libopus.so.0`   | a directory on the loader path                                   |
| macOS    | `libopus.dylib`                | bundled framework / `@rpath` *(needs a Mac — deferred to CI)*    |
| iOS      | statically linked              | `opus.framework` *(needs a Mac — deferred to CI)*               |

### Android ABIs

Ship one `.so` per ABI you support:

```
android/app/src/main/jniLibs/
  arm64-v8a/libopus.so      # required (modern phones)
  armeabi-v7a/libopus.so    # older 32-bit devices
  x86_64/libopus.so         # emulator
```

> **Android 15 / NDK note:** build with **NDK r27+** and 16 KB page alignment, or
> the loader rejects the `.so` on Android 15 devices. Pin `ndkVersion` in
> `android/app/build.gradle`.

### Windows POST_BUILD copy

Add to `windows/runner/CMakeLists.txt` so the DLL lands next to the runner:

```cmake
add_custom_command(TARGET ${BINARY_NAME} POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
    "${CMAKE_SOURCE_DIR}/../third_party/opus/windows/opus.dll"
    "$<TARGET_FILE_DIR:${BINARY_NAME}>/opus.dll")
```

## Getting / building libopus

- **Prebuilt (fastest):** grab official or vcpkg/Homebrew binaries for each target
  and copy them to the locations above. Pin the **opus version** (e.g. 1.5.2) here
  when you do, so builds are reproducible.
- **From source:** `git clone https://gitlab.xiph.org/xiph/opus`, then per platform
  - Windows: CMake + MSVC → `opus.dll`
  - Android: `cmake` with the NDK toolchain per ABI → `libopus.so`

## Binary distribution strategy (avoid repo bloat)

Do **not** commit large `.dll/.so` straight into git history. Pick one:

1. **Git LFS** — `git lfs track "third_party/**/*.dll" "third_party/**/*.so"`.
2. **CI download-and-cache** — a workflow step fetches pinned binaries and caches
   them by version hash (scaffolded in `.github/workflows/flutter_ci.yml`).

## Headers (for regenerating FFI bindings)

The committed bindings are hand-written. To regenerate the full set with ffigen,
place the headers here and run `dart run ffigen --config ffigen_opus.yaml`:

```
third_party/opus/include/opus.h
third_party/opus/include/opus_defines.h
third_party/opus/include/opus_types.h
```

## librnnoise (Phase 2 voice denoise)

`RnnoiseDenoiser` (`lib/asp2/dsp/rnnoise_denoiser.dart`) loads via the same
`DynamicLibrary.open(...)` probe, trying these names in order:

| Platform | Filename(s)                       | Where to place it                                  |
|----------|-----------------------------------|----------------------------------------------------|
| Windows  | `rnnoise.dll`, `librnnoise.dll`   | next to the built `.exe` (POST_BUILD copy as above) |
| Android  | `librnnoise.so`                   | `android/app/src/main/jniLibs/<abi>/librnnoise.so` |
| macOS    | `librnnoise.dylib`, `rnnoise.dylib` | bundled framework *(needs a Mac — deferred to CI)* |
| Linux    | `librnnoise.so`                   | a directory on the loader path                     |

- **Model:** `rnnoise_create(NULL)` uses the built-in model — no separate weights
  file to vendor. A custom model would be passed as the `RNNModel*` argument.
- **Frame size:** RNNoise is mono / 48 kHz / **480-sample (10 ms)** frames;
  `RnnoiseDenoiser` buffers arbitrary chunk sizes to that boundary internally.
- **Build from source:** `git clone https://gitlab.xiph.org/xiph/rnnoise`, then
  `./autogen.sh && ./configure && make` (desktop) or the NDK toolchain per ABI
  (Android). Pin the rnnoise commit here when you vendor it.
- **Verify:** `RnnoiseDenoiser.isAvailable` is `true` once a binary is present;
  the gated denoise test in `test/asp2/dsp_test.dart` self-skips until then.

> The WebRTC `audio_processing` (APM) FFI — AGC target -18 dBFS, AEC, VAD — is the
> next native node. It is **deferred**: the chain runs EQ→compressor→limiter in
> pure Dart today, and APM slots in as another optional `IEffect` behind a
> `tryCreate` probe when its binary is built.

## steamaudio / whisper (Phase 6 spatial + AI) — deferred

Phase 6 follows the same load-probe + simulator discipline. The **pure-Dart**
cores are committed and unit-tested (`test/asp2/spatial_test.dart`,
`test/asp2/ai_test.dart`); the heavy native pieces are scaffolds that report
unavailable until a binary lands, and a live pure-Dart fallback runs meanwhile:

| Feature | Native dep (deferred) | Live pure-Dart fallback | Scaffold |
|---------|-----------------------|-------------------------|----------|
| Binaural HRTF | **Steam Audio** SDK + HRIR dataset (FFI) | `BinauralPanner` (ITD + ILD), `AmbisonicDecoder` | `SteamAudioHrtf.isAvailable => false` (`lib/asp2/spatial/hrtf.dart`) |
| Speech-to-text | **whisper.cpp** lib + `tiny`/`base` model | `ScriptedStt` (deterministic) | `WhisperStt.isAvailable => false` (`lib/asp2/ai/stt.dart`) |
| Translation | on-device MT model / cloud API | `DictionaryTranslator` (offline glossary) | `CloudTranslator.isAvailable => false` |
| Track ID | **AcoustID** web API (key + network) | `ChromaFingerprint` (Goertzel chroma, offline) | `AcoustIdLookup.isAvailable => false` |
| Positioning | **BLE/UWB beacons** (trilateration) | `ManualFloorplanPositioning` (tap-on-floorplan) | `BeaconPositioning.isAvailable => false` |

- **Steam Audio:** vendor `libphonon` (Windows `.dll`, Android `.so`) + an HRIR
  `.mhr`/SOFA dataset; place under `third_party/steamaudio/`. Until then
  `SteamAudioHrtf.renderBinaural` throws and callers use `BinauralPanner`.
- **whisper.cpp:** build `libwhisper` per platform and vendor a quantized model
  (`ggml-base.bin`) under `third_party/whisper/`. The recognizer pushes
  `CaptionLine`s onto the existing `caption` control message — no wire change.
- **Head tracking** (AirPods/Pixel Buds orientation) and **BLE/UWB anchors** are
  `[needs-hardware]`; the spatial math (`AmbisonicDecoder.rotateYaw`,
  `Floorplan.zoneGainsAt`) is exercised today via `ManualFloorplanPositioning`
  and the `listenerPose` control message.

## Phase 7 (recording + post + web rewrite) — deferred pieces

Phase 7's **lossless, pure-Dart** recording path is live and unit-tested: WAV
(`lib/asp2/record/wav_writer.dart`), a real verbatim/constant **FLAC** encoder
(`flac_writer.dart`), a store-mode **ZIP** packager (`zip_writer.dart`), the
multi-stem `SessionRecorder`, and the Reaper `.rpp` / Ableton `.als` exporters.
The deferred pieces follow the same probe-and-fallback discipline:

| Feature | Native dep / tool (deferred) | Live pure-Dart fallback | Scaffold / note |
|---------|------------------------------|-------------------------|-----------------|
| MP3 export | `libmp3lame` (FFI) | WAV / FLAC (lossless) | `Mp3Encoder.isAvailable => false` |
| Opus-file export | `libopus` + `libogg` muxer (FFI) | WAV / FLAC | `OggOpusEncoder.isAvailable => false` |
| Ableton open | Ableton Live app | Reaper `.rpp` is byte-verified; `.als` structure-tested | `.als` exact-open is **[needs-app-verify]** |
| Cloud sync | S3/R2 chunked-resume | local session bundle (`.zip`) | **[needs-service]**, not yet wired |
| Web client build | Node + npm (Vite/vitest) | — | **[needs-node]**, see `web/asp2-client/README.md` |

- **MP3/Opus:** lossy file encoders need their native libs vendored per platform
  (same locations/pattern as `libopus` above). `EncoderRegistry.resolveOrFallback`
  degrades any unavailable format to WAV — never a silent skip.
- **Web client:** `web/asp2-client/` is a Vite + TypeScript PWA scaffold. Its
  ASP-2 frame codec is a byte-exact TS port locked to the Dart wire by a shared
  golden vector (`test/golden_frame.json`), asserted on **both** sides
  (`test/asp2/web_parity_test.dart` in Dart, `test/frame.parity.test.ts` in
  vitest). `npm install` / `npm run dev` / `npm test` are deferred to a
  Node-capable environment.

## Phase 8 (hardening + beta) — deferred pieces

Phase 8 is **pure-Dart hardening + docs**, all live and tested: the protocol
fuzzer (`test/fuzz/asp2_fuzz_test.dart`) hammers every wire decode surface, the
benchmarks (`test/bench/asp2_bench_test.dart`) measure the hot paths, the RBAC +
recording-consent primitives (`lib/asp2/security/**`) gate privileged actions,
and the full spec lives under `docs/**` (see `docs/security-audit.md` for the
findings fixed this phase). The remaining pieces need infrastructure or
real-world access:

| Feature | Needs (deferred) | Status |
|---------|------------------|--------|
| External penetration test | third-party security firm + budget | **[needs-service]** — internal white-box audit done (`docs/security-audit.md`) |
| Telemetry dashboards | Prometheus + Grafana stack | **[needs-service]** — in-app `ClientSyncReport` telemetry exists; export not wired |
| 72-hour soak test | sustained multi-device hardware time | **[needs-real-world]** — fuzzer + benches de-risk it in CI |
| 3-venue closed beta | venue access + crews + hardware | **[needs-real-world]** — pending external access |

These are operational/real-world gates; everything implementable in pure Dart on
this machine (fuzzer, benchmarks, security model, documentation) is complete.

## Verifying the codec is live

```dart
import 'package:audio_splitter_app/asp2/codec/opus_codec.dart';
print(OpusCodec.isAvailable); // true once a binary is in place
```

Or run the gated tests: `flutter test test/asp2/opus_codec_test.dart` — the
roundtrip/PLC cases self-skip with a clear message until the binary is present.
