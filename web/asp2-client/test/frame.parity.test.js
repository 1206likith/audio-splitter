import { describe, it, expect } from 'vitest';
import golden from './golden_frame.json';
import { encodeFrame, decodeFrame } from '../src/asp2/frame';
function hexToBytes(hex) {
    const out = new Uint8Array(hex.length / 2);
    for (let i = 0; i < out.length; i++) {
        out[i] = parseInt(hex.substr(i * 2, 2), 16);
    }
    return out;
}
function bytesToHex(bytes) {
    return Array.from(bytes)
        .map((b) => b.toString(16).padStart(2, '0'))
        .join('');
}
describe('ASP-2 frame cross-stack parity', () => {
    const f = {
        version: golden.fields.version,
        flags: golden.fields.flags,
        codecId: golden.fields.codecId,
        streamId: golden.fields.streamId,
        sequenceNumber: golden.fields.sequenceNumber,
        presentationTsUs: golden.fields.presentationTsUs,
        fecGroupId: golden.fields.fecGroupId,
        fecIndex: golden.fields.fecIndex,
        payload: hexToBytes(golden.fields.payloadHex),
    };
    it('encodes to the exact bytes the Dart encoder produces', () => {
        expect(bytesToHex(encodeFrame(f))).toBe(golden.encodedHex);
    });
    it('round-trips through decode', () => {
        const back = decodeFrame(hexToBytes(golden.encodedHex));
        expect(back.codecId).toBe(f.codecId);
        expect(back.streamId).toBe(f.streamId);
        expect(back.sequenceNumber).toBe(f.sequenceNumber);
        expect(back.presentationTsUs).toBe(f.presentationTsUs);
        expect(bytesToHex(back.payload)).toBe(golden.fields.payloadHex);
    });
});
