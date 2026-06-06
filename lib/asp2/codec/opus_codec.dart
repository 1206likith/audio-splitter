import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../../core/contracts/audio_format.dart';
import '../../core/contracts/i_codec.dart';
import 'native/opus_bindings.dart';

/// Real Opus codec over libopus via dart:ffi (ASP-2 codec_id = 1).
///
/// Operates on fixed **20 ms frames** (960 samples per channel at 48 kHz) — one
/// Opus packet per ASP-2 frame. A decode of an empty payload triggers Opus
/// **packet-loss concealment** (`opus_decode(null, 0, …)`), which is what lets
/// the FEC/PLC gate hold: a lost, unrecoverable frame produces a synthesised
/// 20 ms of audio instead of a zero-length gap.
///
/// The native library is loaded lazily and defensively: [tryCreate] returns null
/// when libopus is absent or incompatible (the documented MSVC-CRT / ABI failure
/// mode), so the caller falls back to [Pcm16Codec] and CI stays green without a
/// vendored binary. See `third_party/README.md` for where to drop the binaries.
class OpusCodec implements ICodec {
  /// Opus operates natively at 48 kHz; this is the only supported sample rate.
  static const int sampleRate = 48000;

  /// 20 ms at 48 kHz = 960 samples per channel.
  static const int samplesPerChannel = 960;

  /// Generous upper bound for one encoded packet (max real ~1275 B for 20 ms).
  static const int _maxPacketBytes = 4000;

  @override
  final AudioFormat format;

  final OpusBindings _b;
  final Pointer<Void> _encoder;
  final Pointer<Void> _decoder;
  final int _channels;

  // Reusable native scratch buffers (allocated once, freed in dispose).
  final Pointer<Int16> _pcmIn;
  final Pointer<Uint8> _pktOut;
  final Pointer<Int16> _pcmOut;

  bool _disposed = false;

  OpusCodec._(
    this._b,
    this._encoder,
    this._decoder,
    this._channels,
    this.format,
  )   : _pcmIn = calloc<Int16>(samplesPerChannel * _channelsOf(format)),
        _pktOut = calloc<Uint8>(_maxPacketBytes),
        _pcmOut = calloc<Int16>(samplesPerChannel * _channelsOf(format));

  static int _channelsOf(AudioFormat f) => f.channels;

  @override
  int get codecId => CodecId.opus;

  /// Number of bytes in one fully-populated 20 ms PCM16 frame for this format.
  int get frameBytes => samplesPerChannel * _channels * 2;

  /// Candidate library filenames per platform, tried in order by [tryCreate].
  static List<String> get _libraryCandidates {
    if (Platform.isWindows) return const ['opus.dll', 'libopus.dll'];
    if (Platform.isMacOS) return const ['libopus.dylib', 'libopus.0.dylib'];
    if (Platform.isAndroid || Platform.isLinux) {
      return const ['libopus.so', 'libopus.so.0'];
    }
    if (Platform.isIOS) return const ['opus.framework/opus']; // static-linked
    return const ['libopus.so'];
  }

  /// Try to load libopus and create an encoder+decoder pair. Returns null if the
  /// library can't be loaded or the codec can't be initialised — never throws,
  /// so callers can cleanly fall back to PCM16.
  static OpusCodec? tryCreate({
    AudioFormat format = const AudioFormat(
      sampleRate: sampleRate,
      channels: 2,
      bitDepth: 16,
    ),
    int? bitrate,
    int application = OpusConstants.applicationAudio,
  }) {
    DynamicLibrary? lib;
    for (final name in _libraryCandidates) {
      try {
        lib = DynamicLibrary.open(name);
        break;
      } catch (_) {
        // try the next candidate
      }
    }
    if (lib == null) return null;

    try {
      final bindings = OpusBindings(lib);
      final channels = format.channels;
      final err = calloc<Int32>();
      try {
        final enc = bindings.encoderCreate(
          sampleRate,
          channels,
          application,
          err,
        );
        if (err.value != OpusConstants.ok || enc == nullptr) {
          if (enc != nullptr) bindings.encoderDestroy(enc);
          return null;
        }
        if (bitrate != null) {
          bindings.encoderCtlSet(
            enc,
            OpusConstants.setBitrateRequest,
            bitrate,
          );
        }
        final dec = bindings.decoderCreate(sampleRate, channels, err);
        if (err.value != OpusConstants.ok || dec == nullptr) {
          bindings.encoderDestroy(enc);
          if (dec != nullptr) bindings.decoderDestroy(dec);
          return null;
        }
        return OpusCodec._(
          bindings,
          enc,
          dec,
          channels,
          AudioFormat(
            sampleRate: sampleRate,
            channels: channels,
            bitDepth: 16,
          ),
        );
      } finally {
        calloc.free(err);
      }
    } catch (_) {
      return null;
    }
  }

  /// Whether a real libopus is present and loadable on this platform right now.
  static bool get isAvailable {
    final c = tryCreate();
    if (c == null) return false;
    c.dispose();
    return true;
  }

  /// Encode one 20 ms PCM16 frame ([frameBytes] bytes) into an Opus packet.
  ///
  /// Shorter input is zero-padded to a full frame; longer input is truncated to
  /// one frame (callers should frame upstream at 20 ms). Returns an empty list on
  /// a native error so the transport can drop rather than crash.
  @override
  Uint8List encode(Uint8List pcm16) {
    if (_disposed) throw StateError('OpusCodec used after dispose');
    final samples = samplesPerChannel * _channels;
    // Zero the input buffer, then copy up to one frame of PCM16 into it.
    for (int i = 0; i < samples; i++) {
      _pcmIn[i] = 0;
    }
    final view = ByteData.view(pcm16.buffer, pcm16.offsetInBytes, pcm16.length);
    final count = (pcm16.length ~/ 2).clamp(0, samples);
    for (int i = 0; i < count; i++) {
      _pcmIn[i] = view.getInt16(i * 2, Endian.little);
    }
    final n = _b.encode(
      _encoder,
      _pcmIn,
      samplesPerChannel,
      _pktOut,
      _maxPacketBytes,
    );
    if (n < 0) return Uint8List(0);
    return Uint8List.fromList(_pktOut.asTypedList(n));
  }

  /// Decode an Opus packet back to one 20 ms PCM16 frame.
  ///
  /// An empty [payload] requests **packet-loss concealment**: Opus synthesises a
  /// 20 ms gap-filler from its internal state rather than returning silence.
  @override
  Uint8List decode(Uint8List payload) {
    if (_disposed) throw StateError('OpusCodec used after dispose');
    final int decoded;
    if (payload.isEmpty) {
      // PLC: null data pointer, length 0.
      decoded = _b.decode(
        _decoder,
        nullptr,
        0,
        _pcmOut,
        samplesPerChannel,
        0,
      );
    } else {
      final inPkt = calloc<Uint8>(payload.length);
      try {
        inPkt.asTypedList(payload.length).setAll(0, payload);
        decoded = _b.decode(
          _decoder,
          inPkt,
          payload.length,
          _pcmOut,
          samplesPerChannel,
          0,
        );
      } finally {
        calloc.free(inPkt);
      }
    }
    if (decoded < 0) return Uint8List(0);
    final out = Uint8List(decoded * _channels * 2);
    final outView = ByteData.view(out.buffer);
    for (int i = 0; i < decoded * _channels; i++) {
      outView.setInt16(i * 2, _pcmOut[i], Endian.little);
    }
    return out;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _b.encoderDestroy(_encoder);
    _b.decoderDestroy(_decoder);
    calloc.free(_pcmIn);
    calloc.free(_pktOut);
    calloc.free(_pcmOut);
  }
}
