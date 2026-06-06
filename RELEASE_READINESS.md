# Release Readiness Guide

This checklist reflects the current, verified state of the project.

## Current Verified State

- Flutter analyzer: clean
- Unit/integration tests: passing in this workspace
- Web release build: successful (`flutter build web --no-wasm-dry-run`)
- Runtime host/client layout overflow issue: fixed in host and client screens

## Runtime Targets

- Web (Chrome/Edge): supported and verified for build and debug
- Windows desktop: requires Visual Studio Build Tools / Visual Studio installation

## Functional Scope (Current MVP)

- Host mode and client mode UI
- Host discovery (mDNS + subnet scan fallback)
- WebSocket audio transport with binary frame path
- Sync and latency telemetry plumbing
- Microphone source capture path
- Playback route preference toggle (speaker preferred vs external route)

## Known Constraints

- Capture source support is intentionally restricted to microphone in this build.
- Advanced source modes (system audio, media file, remote stream ingest) are not implemented as production capture paths yet.
- Desktop Windows run can fail on machines without required MSVC tooling.

## Release Checklist

1. Environment
- Install Flutter SDK and verify `flutter doctor` is clean.
- For Windows desktop release, install Visual Studio with Desktop development with C++ workload.

2. Dependencies
- Run `flutter pub get`.
- Run `flutter pub outdated` and decide whether to pin/upgrade before release.

3. Quality gates
- Run `flutter analyze`.
- Run `flutter test`.
- Run focused integration tests if target-specific behavior changed.

4. Build gates
- Web: `flutter build web --no-wasm-dry-run`
- Windows (if shipping desktop): `flutter build windows`

5. Smoke tests
- Launch host on one device/browser instance.
- Connect a client from another device/browser instance on same network.
- Start/stop streaming and verify no crashes.
- Validate reconnect behavior by temporary network interruption.

6. Release artifacts
- Web artifact: `build/web`
- Windows artifact: `build/windows/runner/Release`

## Recommended Next Engineering Steps

1. Implement real source adapters for `mediaFile` and `streaming` modes.
2. Add output routing confirmation UI (active route + failure states).
3. Add integration tests for host/client connect, reconnect, and stream lifecycle.
4. Add CI workflow for analyze, test, and web build.
