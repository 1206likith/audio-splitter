// WebSocket transport for the web client — the browser side of WsTransport
// (lib/asp2/transport/ws_transport.dart). Receives binary ASP-2 frames and
// hands decoded frames to a callback; sends frames back on the control path.
import { decodeFrame, encodeFrame } from './frame';
export class WsTransport {
    constructor(onFrame) {
        this.ws = null;
        this.onFrame = onFrame;
    }
    get isOpen() {
        return this.ws?.readyState === WebSocket.OPEN;
    }
    connect(url) {
        return new Promise((resolve, reject) => {
            const ws = new WebSocket(url);
            ws.binaryType = 'arraybuffer';
            ws.onopen = () => resolve();
            ws.onerror = (e) => reject(e);
            ws.onmessage = (ev) => {
                if (ev.data instanceof ArrayBuffer) {
                    try {
                        this.onFrame(decodeFrame(new Uint8Array(ev.data)));
                    }
                    catch {
                        // Malformed frame — drop it (mirrors the native transport).
                    }
                }
            };
            this.ws = ws;
        });
    }
    send(frame) {
        if (this.isOpen)
            this.ws.send(encodeFrame(frame));
    }
    close() {
        this.ws?.close();
        this.ws = null;
    }
}
