// ASP-2 binary media frame — TypeScript port of lib/asp2/frame/asp2_frame.dart.
// Byte-for-byte identical wire layout (all integers little-endian); the shared
// golden vector in test/golden_frame.json locks the two implementations
// together. The 20-byte header doubles as the AEAD associated data.

export const HEADER_SIZE = 20;
export const TAG_SIZE = 16;
export const NONCE_SIZE = 12;
export const CURRENT_VERSION = 2;

export const FLAG_ENCRYPTED = 0x1;
export const FLAG_PARITY = 0x2;

export interface Asp2Frame {
  version: number;
  flags: number;
  codecId: number;
  streamId: number;
  sequenceNumber: number;
  /** Host-clock microseconds (uint64). */
  presentationTsUs: number;
  fecGroupId: number;
  fecIndex: number;
  payload: Uint8Array;
  tag?: Uint8Array;
  nonce?: Uint8Array;
}

export function isEncrypted(f: Pick<Asp2Frame, 'flags'>): boolean {
  return (f.flags & FLAG_ENCRYPTED) !== 0;
}

/** Serialize just the 20-byte header (also the AEAD AAD). */
export function encodeHeader(f: Asp2Frame): Uint8Array {
  const h = new Uint8Array(HEADER_SIZE);
  const dv = new DataView(h.buffer);
  dv.setUint8(0, ((f.version & 0x0f) << 4) | (f.flags & 0x0f));
  dv.setUint8(1, f.codecId & 0xff);
  dv.setUint16(2, f.streamId & 0xffff, true);
  dv.setUint32(4, f.sequenceNumber >>> 0, true);
  dv.setBigUint64(8, BigInt(f.presentationTsUs), true);
  dv.setUint16(16, f.payload.length & 0xffff, true);
  dv.setUint8(18, f.fecGroupId & 0xff);
  dv.setUint8(19, f.fecIndex & 0xff);
  return h;
}

/** Serialize the full frame: header + payload (+ tag + nonce when encrypted). */
export function encodeFrame(f: Asp2Frame): Uint8Array {
  const enc = isEncrypted(f);
  if (enc && (!f.tag || !f.nonce)) {
    throw new Error('Encrypted frame requires both tag and nonce');
  }
  const trailer = enc ? TAG_SIZE + NONCE_SIZE : 0;
  const out = new Uint8Array(HEADER_SIZE + f.payload.length + trailer);
  out.set(encodeHeader(f), 0);
  out.set(f.payload, HEADER_SIZE);
  if (enc) {
    const tagStart = HEADER_SIZE + f.payload.length;
    out.set(f.tag!, tagStart);
    out.set(f.nonce!, tagStart + TAG_SIZE);
  }
  return out;
}

/** Parse a frame; throws on a malformed/truncated buffer so callers can drop it. */
export function decodeFrame(bytes: Uint8Array): Asp2Frame {
  if (bytes.length < HEADER_SIZE) {
    throw new Error('ASP-2 frame shorter than header');
  }
  const dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.length);
  const b0 = dv.getUint8(0);
  const version = (b0 >> 4) & 0x0f;
  const flags = b0 & 0x0f;
  const codecId = dv.getUint8(1);
  const streamId = dv.getUint16(2, true);
  const sequenceNumber = dv.getUint32(4, true);
  const presentationTsUs = Number(dv.getBigUint64(8, true));
  const payloadLength = dv.getUint16(16, true);
  const fecGroupId = dv.getUint8(18);
  const fecIndex = dv.getUint8(19);

  const enc = (flags & FLAG_ENCRYPTED) !== 0;
  const trailer = enc ? TAG_SIZE + NONCE_SIZE : 0;
  const needed = HEADER_SIZE + payloadLength + trailer;
  if (bytes.length < needed) {
    throw new Error(`ASP-2 frame truncated: need ${needed}, have ${bytes.length}`);
  }

  const payload = bytes.slice(HEADER_SIZE, HEADER_SIZE + payloadLength);
  let tag: Uint8Array | undefined;
  let nonce: Uint8Array | undefined;
  if (enc) {
    const tagStart = HEADER_SIZE + payloadLength;
    tag = bytes.slice(tagStart, tagStart + TAG_SIZE);
    nonce = bytes.slice(tagStart + TAG_SIZE, tagStart + TAG_SIZE + NONCE_SIZE);
  }

  return {
    version,
    flags,
    codecId,
    streamId,
    sequenceNumber,
    presentationTsUs,
    fecGroupId,
    fecIndex,
    payload,
    tag,
    nonce,
  };
}
