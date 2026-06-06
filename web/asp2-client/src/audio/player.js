// Web Audio playout: schedules decoded PCM16 chunks on an AudioContext with a
// small jitter buffer, converting interleaved int16 → planar float32. This is
// the browser counterpart of the FlutterSoundSink.
export class PcmPlayer {
    constructor(sampleRate = 48000, channels = 2) {
        this.nextStartTime = 0;
        this.sampleRate = sampleRate;
        this.channels = channels;
        this.ctx = new AudioContext({ sampleRate });
    }
    /** Resume the context (must be called from a user gesture in browsers). */
    async resume() {
        await this.ctx.resume();
    }
    /** Enqueue one interleaved 16-bit PCM chunk for gapless playback. */
    enqueue(pcm) {
        const frames = pcm.length / (2 * this.channels);
        const buffer = this.ctx.createBuffer(this.channels, frames, this.sampleRate);
        const view = new DataView(pcm.buffer, pcm.byteOffset, pcm.length);
        for (let ch = 0; ch < this.channels; ch++) {
            const out = buffer.getChannelData(ch);
            for (let f = 0; f < frames; f++) {
                out[f] = view.getInt16((f * this.channels + ch) * 2, true) / 32768;
            }
        }
        const src = this.ctx.createBufferSource();
        src.buffer = buffer;
        src.connect(this.ctx.destination);
        const now = this.ctx.currentTime;
        const start = Math.max(now + 0.02, this.nextStartTime);
        src.start(start);
        this.nextStartTime = start + frames / this.sampleRate;
    }
}
