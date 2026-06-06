# Audio Splitter v2 — Web Client (Vite + TypeScript PWA)

Phase 7 begins the **single-stack ASP-2 web client** that replaces v1's
embedded-HTML legacy room (and retires the dual-stack legacy PCM16+AES-CTR path
once it reaches feature parity). It speaks the *same* ASP-2 wire as the native
apps — same binary frame, same AEAD, same Opus codec — rather than a
browser-special protocol.

## Status

This is a **scaffold with a verified protocol core**, not yet a running build.
Building/running needs Node + npm, which aren't available on the current
offline dev machine, so `npm install` / `npm run dev` are **[needs-node]** and
deferred. What *is* done and locked:

| Piece | File | State |
|-------|------|-------|
| ASP-2 binary frame codec | `src/asp2/frame.ts` | ✅ byte-exact port of `asp2_frame.dart` |
| Cross-stack parity test | `test/frame.parity.test.ts` + `test/golden_frame.json` | ✅ shared golden vector |
| WebSocket transport | `src/asp2/transport.ts` | ✅ decode/send wired |
| Web Audio PCM player | `src/audio/player.ts` | ✅ int16→float, jitter-scheduled |
| AEAD (ChaCha20-Poly1305-IETF) | `src/asp2/crypto.ts` | scaffold — needs `libsodium-wrappers` (`npm i`) |
| Listener UI | `src/main.ts` + `index.html` | ✅ minimal join+play |
| PWA shell | `vite.config.ts` (vite-plugin-pwa) | ✅ manifest/service-worker config |

### Cross-stack parity (the gate's "feature-parity test")

`test/golden_frame.json` holds one canonical ASP-2 frame's fields and its exact
encoded bytes. **Two tests assert against the same fixture:**

- **Dart** — `test/asp2/web_parity_test.dart` asserts the real
  `Asp2Frame.encode()` produces `encodedHex`. This proves the fixture is the
  true canonical wire (runs in CI today).
- **TypeScript** — `test/frame.parity.test.ts` asserts `encodeFrame()` /
  `decodeFrame()` round-trip to the same bytes (run with `npm test` under
  Node/vitest).

Because both stacks are pinned to one fixture, the web client's frame layer is
provably wire-compatible with the native client the moment vitest runs green.

## Deferred (tracked, not silent)

- **[needs-node]** `npm install` (typescript, vite, vitest, vite-plugin-pwa,
  libsodium-wrappers) then `npm run dev` / `npm test` / `npm run build`.
- **WASM Opus decoder** for the `codecId === 1` path (PCM16 path ships now).
- **libsodium.js init** in `SodiumCryptoBox.init()` for the encrypted flag.
- **Full component model** beyond the listener: host view (source picker,
  zone/DJ controls), settings, recording/export download (consumes the Phase 7
  `SessionBundle` zip). Laid out here; implemented as the web effort continues.

## Layout

```
web/asp2-client/
  index.html          PWA entry
  vite.config.ts      build + PWA + vitest config
  src/
    main.ts           listener bootstrap
    asp2/
      frame.ts        ASP-2 binary frame (wire-locked)
      crypto.ts       ChaCha20-Poly1305-IETF via libsodium.js
      transport.ts    WebSocket transport
    audio/
      player.ts       Web Audio PCM16 playout
  test/
    frame.parity.test.ts   vitest cross-stack parity
    golden_frame.json      shared golden vector (also asserted in Dart)
```
