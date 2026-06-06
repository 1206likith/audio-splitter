import 'dart:typed_data';

import '../../core/contracts/audio_format.dart';

/// Pure-Dart **FLAC** encoder using CONSTANT and VERBATIM subframes — a fully
/// valid, lossless FLAC bitstream with no native dependency. It does not do
/// Rice/LPC compression (so files are roughly WAV-sized), but the container is
/// real FLAC: `fLaC` marker, a correct STREAMINFO metadata block, and audio
/// frames with proper CRC-8 headers and CRC-16 footers. Silent stem regions
/// collapse to one-sample CONSTANT subframes, so digital silence is tiny.
///
/// This gives the recorder a second genuine, openable lossless format alongside
/// [WavWriter]. Compressed lossless (LPC) and the lossy MP3/Opus encoders need
/// native libraries and are deferred behind the [AudioEncoder] load-probe.
///
/// Only 16-bit integer PCM is supported (every source/codec in the pipeline).
class FlacWriter {
  FlacWriter._();

  /// Samples-per-channel per FLAC frame (within the FLAC subset for ≤48 kHz).
  static const int blockSize = 4096;

  /// Encode interleaved 16-bit [pcm] in [format] to a complete `.flac` file.
  static Uint8List encode(AudioFormat format, Uint8List pcm) {
    assert(format.bitDepth == 16, 'FlacWriter encodes 16-bit PCM only');
    final channels = format.channels;
    final frameBytes = format.frameBytes;
    final totalSamples = frameBytes == 0 ? 0 : pcm.length ~/ frameBytes;
    final view = ByteData.view(pcm.buffer, pcm.offsetInBytes, pcm.length);

    // Build all audio frames first so STREAMINFO can carry exact block sizes.
    final out = BytesBuilder();
    var minBlock = blockSize;
    var maxBlock = 0;
    var frameNumber = 0;
    for (var start = 0; start < totalSamples; start += blockSize) {
      final n = (start + blockSize <= totalSamples)
          ? blockSize
          : totalSamples - start;
      if (n < minBlock) minBlock = n;
      if (n > maxBlock) maxBlock = n;
      out.add(_encodeFrame(view, channels, start, n, frameNumber, format));
      frameNumber++;
    }
    if (totalSamples == 0) {
      minBlock = 0;
      maxBlock = 0;
    }

    final frames = out.toBytes();
    final header = _streamHeader(format, totalSamples, minBlock, maxBlock);
    final result = Uint8List(header.length + frames.length);
    result.setRange(0, header.length, header);
    result.setRange(header.length, result.length, frames);
    return result;
  }

  /// `fLaC` marker + a single (last) STREAMINFO metadata block.
  static Uint8List _streamHeader(
      AudioFormat format, int totalSamples, int minBlock, int maxBlock) {
    final bw = _BitWriter();
    // Stream marker.
    bw.writeBits(0x664C6143, 32); // 'fLaC'
    // Metadata block header: last-block=1, type=0 (STREAMINFO), length=34.
    bw.writeBits(1, 1);
    bw.writeBits(0, 7);
    bw.writeBits(34, 24);
    // STREAMINFO body.
    bw.writeBits(minBlock, 16);
    bw.writeBits(maxBlock, 16);
    bw.writeBits(0, 24); // min frame size unknown
    bw.writeBits(0, 24); // max frame size unknown
    bw.writeBits(format.sampleRate, 20);
    bw.writeBits(format.channels - 1, 3);
    bw.writeBits(format.bitDepth - 1, 5);
    bw.writeBits(totalSamples, 36);
    // MD5 of the unencoded audio: all-zero signals "not computed" (legal).
    for (var i = 0; i < 16; i++) {
      bw.writeBits(0, 8);
    }
    return bw.toBytes();
  }

  /// Sample-rate codes that need no extra header bytes; 0 ⇒ read from
  /// STREAMINFO.
  static int _sampleRateCode(int sr) {
    switch (sr) {
      case 88200:
        return 0x1;
      case 176400:
        return 0x2;
      case 192000:
        return 0x3;
      case 8000:
        return 0x4;
      case 16000:
        return 0x5;
      case 22050:
        return 0x6;
      case 24000:
        return 0x7;
      case 32000:
        return 0x8;
      case 44100:
        return 0x9;
      case 48000:
        return 0xA;
      case 96000:
        return 0xB;
      default:
        return 0x0; // get from STREAMINFO
    }
  }

  static Uint8List _encodeFrame(ByteData view, int channels, int startSample,
      int n, int frameNumber, AudioFormat format) {
    // --- Frame header (byte-aligned), then CRC-8 over it. ---
    final hb = _BitWriter();
    hb.writeBits(0x3FFE, 14); // sync code
    hb.writeBits(0, 1); // reserved
    hb.writeBits(0, 1); // blocking strategy: fixed block size
    hb.writeBits(0x7, 4); // block size: 16-bit (blocksize-1) at header end
    hb.writeBits(_sampleRateCode(format.sampleRate), 4);
    hb.writeBits(channels - 1, 4); // independent channels
    hb.writeBits(0x4, 3); // sample size: 16 bits
    hb.writeBits(0, 1); // reserved
    for (final b in _utf8Number(frameNumber)) {
      hb.writeBits(b, 8);
    }
    hb.writeBits(n - 1, 16); // explicit block size - 1
    final headerBytes = hb.toBytes();
    final crc8 = _crc8(headerBytes);

    // --- Whole frame: header + crc8 + subframes, then CRC-16. ---
    final fb = _BitWriter();
    for (final b in headerBytes) {
      fb.writeBits(b, 8);
    }
    fb.writeBits(crc8, 8);

    for (var ch = 0; ch < channels; ch++) {
      _encodeSubframe(fb, view, channels, ch, startSample, n);
    }
    fb.alignToByte();

    final body = fb.toBytes();
    final crc16 = _crc16(body);
    final frame = Uint8List(body.length + 2);
    frame.setRange(0, body.length, body);
    frame[body.length] = (crc16 >> 8) & 0xFF;
    frame[body.length + 1] = crc16 & 0xFF;
    return frame;
  }

  /// One channel's subframe: CONSTANT when every sample is equal (silence,
  /// holds), otherwise VERBATIM (raw 16-bit samples).
  static void _encodeSubframe(_BitWriter fb, ByteData view, int channels,
      int ch, int startSample, int n) {
    int sampleAt(int i) =>
        view.getInt16(((startSample + i) * channels + ch) * 2, Endian.little);

    var constant = true;
    final first = n > 0 ? sampleAt(0) : 0;
    for (var i = 1; i < n; i++) {
      if (sampleAt(i) != first) {
        constant = false;
        break;
      }
    }

    fb.writeBits(0, 1); // mandatory zero padding bit
    if (constant) {
      fb.writeBits(0x00, 6); // subframe type CONSTANT
      fb.writeBits(0, 1); // no wasted bits
      fb.writeBits(first & 0xFFFF, 16);
    } else {
      fb.writeBits(0x01, 6); // subframe type VERBATIM
      fb.writeBits(0, 1); // no wasted bits
      for (var i = 0; i < n; i++) {
        fb.writeBits(sampleAt(i) & 0xFFFF, 16);
      }
    }
  }

  /// FLAC's extended-UTF-8 coding of a frame/sample number.
  static List<int> _utf8Number(int val) {
    if (val < 0x80) return [val];
    int bytes;
    if (val < 0x800) {
      bytes = 2;
    } else if (val < 0x10000) {
      bytes = 3;
    } else if (val < 0x200000) {
      bytes = 4;
    } else if (val < 0x4000000) {
      bytes = 5;
    } else {
      bytes = 6;
    }
    final out = List<int>.filled(bytes, 0);
    var v = val;
    for (var i = bytes - 1; i > 0; i--) {
      out[i] = 0x80 | (v & 0x3F);
      v >>= 6;
    }
    const lead = [0, 0, 0xC0, 0xE0, 0xF0, 0xF8, 0xFC];
    out[0] = lead[bytes] | v;
    return out;
  }

  static int _crc8(List<int> data) {
    var crc = 0;
    for (final b in data) {
      crc ^= b;
      for (var i = 0; i < 8; i++) {
        crc =
            (crc & 0x80) != 0 ? ((crc << 1) ^ 0x07) & 0xFF : (crc << 1) & 0xFF;
      }
    }
    return crc & 0xFF;
  }

  static int _crc16(List<int> data) {
    var crc = 0;
    for (final b in data) {
      crc ^= (b << 8);
      for (var i = 0; i < 8; i++) {
        crc = (crc & 0x8000) != 0
            ? ((crc << 1) ^ 0x8005) & 0xFFFF
            : (crc << 1) & 0xFFFF;
      }
    }
    return crc & 0xFFFF;
  }
}

/// Minimal MSB-first bit writer backing the FLAC bitstream.
class _BitWriter {
  final BytesBuilder _bytes = BytesBuilder();
  int _acc = 0;
  int _nbits = 0;

  void writeBits(int value, int bits) {
    for (var i = bits - 1; i >= 0; i--) {
      _acc = (_acc << 1) | ((value >> i) & 1);
      _nbits++;
      if (_nbits == 8) {
        _bytes.addByte(_acc & 0xFF);
        _acc = 0;
        _nbits = 0;
      }
    }
  }

  void alignToByte() {
    if (_nbits != 0) {
      _acc <<= (8 - _nbits);
      _bytes.addByte(_acc & 0xFF);
      _acc = 0;
      _nbits = 0;
    }
  }

  Uint8List toBytes() {
    alignToByte();
    return _bytes.toBytes();
  }
}
