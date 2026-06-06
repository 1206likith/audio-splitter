// ASP-2 AEAD for the browser. The native build uses ChaCha20-Poly1305-IETF,
// which the WebCrypto SubtleCrypto API does NOT provide — so the single-stack
// web client uses libsodium.js (crypto_aead_chacha20poly1305_ietf_*). This
// module wraps it behind a small interface and stays inert until init()
// resolves the WASM module.
//
// AAD = the 20-byte frame header (see frame.ts). Nonce = 12 bytes, carried in
// the frame trailer. This mirrors lib/asp2/crypto/crypto_box.dart.

export interface CryptoBox {
  /** Encrypt `plaintext` with `aad`; returns {ciphertext, tag, nonce}. */
  seal(
    plaintext: Uint8Array,
    aad: Uint8Array,
    nonce: Uint8Array
  ): { ciphertext: Uint8Array; tag: Uint8Array };
  /** Decrypt; throws on auth failure. */
  open(
    ciphertext: Uint8Array,
    tag: Uint8Array,
    aad: Uint8Array,
    nonce: Uint8Array
  ): Uint8Array;
}

/**
 * libsodium-backed ChaCha20-Poly1305-IETF box. **[needs-node]**: the
 * `libsodium-wrappers` dependency is installed via `npm install` (deferred on
 * this offline dev machine). Until `init()` is awaited, `seal/open` throw.
 */
export class SodiumCryptoBox implements CryptoBox {
  private sodium: any | null = null;
  private key: Uint8Array;

  constructor(key: Uint8Array) {
    this.key = key;
  }

  /** Load the WASM module. Call once before seal/open. */
  async init(): Promise<void> {
    const mod = await import('libsodium-wrappers');
    await mod.ready;
    this.sodium = mod;
  }

  private get s(): any {
    if (!this.sodium) {
      throw new Error('SodiumCryptoBox.init() not awaited (libsodium not ready)');
    }
    return this.sodium;
  }

  seal(plaintext: Uint8Array, aad: Uint8Array, nonce: Uint8Array) {
    const combined = this.s.crypto_aead_chacha20poly1305_ietf_encrypt(
      plaintext,
      aad,
      null,
      nonce,
      this.key
    ) as Uint8Array;
    // libsodium appends the 16-byte tag to the ciphertext; split it out to
    // match the ASP-2 frame layout (payload | tag | nonce).
    const tag = combined.slice(combined.length - 16);
    const ciphertext = combined.slice(0, combined.length - 16);
    return { ciphertext, tag };
  }

  open(
    ciphertext: Uint8Array,
    tag: Uint8Array,
    aad: Uint8Array,
    nonce: Uint8Array
  ): Uint8Array {
    const combined = new Uint8Array(ciphertext.length + tag.length);
    combined.set(ciphertext, 0);
    combined.set(tag, ciphertext.length);
    return this.s.crypto_aead_chacha20poly1305_ietf_decrypt(
      null,
      combined,
      aad,
      nonce,
      this.key
    ) as Uint8Array;
  }
}
