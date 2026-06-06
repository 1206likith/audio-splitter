// Audio Splitter v2 web client entry point. Minimal single-stack ASP-2 listener:
// connect to a host, decode incoming PCM16 frames, play them through Web Audio.
// The full component model (host view, DJ deck, settings) is laid out in
// README.md; this is the listener path that the parity test exercises.

import { WsTransport } from './asp2/transport';
import { PcmPlayer } from './audio/player';
import { type Asp2Frame } from './asp2/frame';

const CODEC_PCM16 = 0;

function boot(): void {
  const player = new PcmPlayer(48000, 2);
  const transport = new WsTransport((frame: Asp2Frame) => {
    // Phase 7 ships the PCM16 path; the Opus path lights up once the WASM Opus
    // decoder is bundled (see README "Deferred").
    if (frame.codecId === CODEC_PCM16) {
      player.enqueue(frame.payload);
    }
  });

  const app = document.querySelector<HTMLDivElement>('#app');
  if (!app) return;
  app.innerHTML = `
    <main class="listener">
      <h1>Audio Splitter</h1>
      <input id="host" placeholder="ws://host:8080/asp2" />
      <button id="join">Join</button>
      <p id="status">idle</p>
    </main>`;

  const status = app.querySelector<HTMLParagraphElement>('#status')!;
  app.querySelector<HTMLButtonElement>('#join')!.addEventListener('click', async () => {
    const url = app.querySelector<HTMLInputElement>('#host')!.value;
    try {
      await player.resume();
      await transport.connect(url);
      status.textContent = 'connected';
    } catch {
      status.textContent = 'connection failed';
    }
  });
}

boot();
