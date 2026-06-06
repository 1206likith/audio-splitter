// ASP-2 AEAD for the browser. The native build uses ChaCha20-Poly1305-IETF,
// which the WebCrypto SubtleCrypto API does NOT provide — so the single-stack
// web client uses libsodium.js (crypto_aead_chacha20poly1305_ietf_*). This
// module wraps it behind a small interface and stays inert until init()
// resolves the WASM module.
//
// AAD = the 20-byte frame header (see frame.ts). Nonce = 12 bytes, carried in
// the frame trailer. This mirrors lib/asp2/crypto/crypto_box.dart.
/**
 * libsodium-backed ChaCha20-Poly1305-IETF box. **[needs-node]**: the
 * `libsodium-wrappers` dependency is installed via `npm install` (deferred on
 * this offline dev machine). Until `init()` is awaited, `seal/open` throw.
 */
export class SodiumCryptoBox {
    constructor(key) {
        this.sodium = null;
        this.key = key;
    }
    /** Load the WASM module. Call once before seal/open. */
    async init() {
        const mod = await import('libsodium-wrappers');
        await mod.ready;
        this.sodium = mod;
    }
    get s() {
        if (!this.sodium) {
            throw new Error('SodiumCryptoBox.init() not awaited (libsodium not ready)');
        }
        return this.sodium;
    }
    seal(plaintext, aad, nonce) {
        const combined = this.s.crypto_aead_chacha20poly1305_ietf_encrypt(plaintext, aad, null, nonce, this.key);
        // libsodium appends the 16-byte tag to the ciphertext; split it out to
        // match the ASP-2 frame layout (payload | tag | nonce).
        const tag = combined.slice(combined.length - 16);
        const ciphertext = combined.slice(0, combined.length - 16);
        return { ciphertext, tag };
    }
    open(ciphertext, tag, aad, nonce) {
        const combined = new Uint8Array(ciphertext.length + tag.length);
        combined.set(ciphertext, 0);
        combined.set(tag, ciphertext.length);
        return this.s.crypto_aead_chacha20poly1305_ietf_decrypt(null, combined, aad, nonce, this.key);
    }
}
