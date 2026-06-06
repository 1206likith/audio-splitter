// WebSocket transport for the web client — the browser side of WsTransport
// (lib/asp2/transport/ws_transport.dart). Receives binary ASP-2 frames and
// hands decoded frames to a callback; sends frames back on the control path.

import { decodeFrame, encodeFrame, type Asp2Frame } from './frame';

export type FrameHandler = (frame: Asp2Frame) => void;

export class WsTransport {
  private ws: WebSocket | null = null;
  private onFrame: FrameHandler;

  constructor(onFrame: FrameHandler) {
    this.onFrame = onFrame;
  }

  get isOpen(): boolean {
    return this.ws?.readyState === WebSocket.OPEN;
  }

  connect(url: string): Promise<void> {
    return new Promise((resolve, reject) => {
      const ws = new WebSocket(url);
      ws.binaryType = 'arraybuffer';
      ws.onopen = () => resolve();
      ws.onerror = (e) => reject(e);
      ws.onmessage = (ev) => {
        if (ev.data instanceof ArrayBuffer) {
          try {
            this.onFrame(decodeFrame(new Uint8Array(ev.data)));
          } catch {
            // Malformed frame — drop it (mirrors the native transport).
          }
        }
      };
      this.ws = ws;
    });
  }

  send(frame: Asp2Frame): void {
    if (this.isOpen) this.ws!.send(encodeFrame(frame));
  }

  close(): void {
    this.ws?.close();
    this.ws = null;
  }
}
