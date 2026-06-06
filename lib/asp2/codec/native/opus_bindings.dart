import 'dart:ffi';

/// Minimal hand-written FFI bindings for libopus.
///
/// These cover exactly the symbols [OpusCodec] needs (create/encode/decode/
/// destroy + the bitrate CTL). The canonical, fuller bindings can be regenerated
/// from the public headers with `dart run ffigen --config ffigen_opus.yaml`
/// (see `third_party/README.md`); this file is kept small and dependency-light so
/// the codec compiles and unit-tests its load-probe path without the generator.
///
/// libopus C signatures (from opus.h):
/// ```c
/// OpusEncoder* opus_encoder_create(opus_int32 Fs, int channels, int application, int* error);
/// int          opus_encode(OpusEncoder* st, const opus_int16* pcm, int frame_size,
///                          unsigned char* data, opus_int32 max_data_bytes);
/// void         opus_encoder_destroy(OpusEncoder* st);
/// int          opus_encoder_ctl(OpusEncoder* st, int request, ...);
/// OpusDecoder* opus_decoder_create(opus_int32 Fs, int channels, int* error);
/// int          opus_decode(OpusDecoder* st, const unsigned char* data, opus_int32 len,
///                          opus_int16* pcm, int frame_size, int decode_fec);
/// void         opus_decoder_destroy(OpusDecoder* st);
/// ```

// Opaque encoder/decoder state pointers.
typedef OpusEncoder = Pointer<Void>;
typedef OpusDecoder = Pointer<Void>;

// --- opus_encoder_create ---
typedef _EncoderCreateC = Pointer<Void> Function(
    Int32 fs, Int32 channels, Int32 application, Pointer<Int32> error);
typedef EncoderCreateDart = Pointer<Void> Function(
    int fs, int channels, int application, Pointer<Int32> error);

// --- opus_encode ---
typedef _EncodeC = Int32 Function(Pointer<Void> st, Pointer<Int16> pcm,
    Int32 frameSize, Pointer<Uint8> data, Int32 maxDataBytes);
typedef EncodeDart = int Function(Pointer<Void> st, Pointer<Int16> pcm,
    int frameSize, Pointer<Uint8> data, int maxDataBytes);

// --- opus_encoder_destroy ---
typedef _EncoderDestroyC = Void Function(Pointer<Void> st);
typedef EncoderDestroyDart = void Function(Pointer<Void> st);

// --- opus_encoder_ctl (int32 setter form only) ---
//
// opus_encoder_ctl is variadic in C. Every CTL we use (OPUS_SET_BITRATE etc.)
// takes a single opus_int32 by value, which the SysV/Win64/AArch64 ABIs pass in
// the same register as a fixed argument — so a fixed 3-arg signature is safe for
// these setters. Do NOT reuse this binding for pointer-returning getters.
typedef _EncoderCtlSetC = Int32 Function(
    Pointer<Void> st, Int32 request, Int32 value);
typedef EncoderCtlSetDart = int Function(
    Pointer<Void> st, int request, int value);

// --- opus_decoder_create ---
typedef _DecoderCreateC = Pointer<Void> Function(
    Int32 fs, Int32 channels, Pointer<Int32> error);
typedef DecoderCreateDart = Pointer<Void> Function(
    int fs, int channels, Pointer<Int32> error);

// --- opus_decode ---
typedef _DecodeC = Int32 Function(Pointer<Void> st, Pointer<Uint8> data,
    Int32 len, Pointer<Int16> pcm, Int32 frameSize, Int32 decodeFec);
typedef DecodeDart = int Function(Pointer<Void> st, Pointer<Uint8> data,
    int len, Pointer<Int16> pcm, int frameSize, int decodeFec);

// --- opus_decoder_destroy ---
typedef _DecoderDestroyC = Void Function(Pointer<Void> st);
typedef DecoderDestroyDart = void Function(Pointer<Void> st);

/// libopus constants we rely on (from opus_defines.h).
class OpusConstants {
  /// application: general audio (good default for music streaming).
  static const int applicationAudio = 2049;

  /// application: lowest algorithmic delay (best for tight real-time sync).
  static const int applicationRestrictedLowDelay = 2051;

  /// OPUS_SET_BITRATE request id.
  static const int setBitrateRequest = 4002;

  /// Error codes.
  static const int ok = 0;

  /// Sentinel meaning "let Opus choose the bitrate".
  static const int bitrateAuto = -1000;
}

/// Resolved function pointers from a loaded libopus [DynamicLibrary].
///
/// Construction looks up every needed symbol up front, so a missing/incompatible
/// library fails fast at load time (caught by [OpusCodec.tryCreate]) rather than
/// mid-stream.
class OpusBindings {
  final EncoderCreateDart encoderCreate;
  final EncodeDart encode;
  final EncoderDestroyDart encoderDestroy;
  final EncoderCtlSetDart encoderCtlSet;
  final DecoderCreateDart decoderCreate;
  final DecodeDart decode;
  final DecoderDestroyDart decoderDestroy;

  OpusBindings(DynamicLibrary lib)
      : encoderCreate = lib.lookupFunction<_EncoderCreateC, EncoderCreateDart>(
            'opus_encoder_create'),
        encode = lib.lookupFunction<_EncodeC, EncodeDart>('opus_encode'),
        encoderDestroy =
            lib.lookupFunction<_EncoderDestroyC, EncoderDestroyDart>(
                'opus_encoder_destroy'),
        encoderCtlSet = lib.lookupFunction<_EncoderCtlSetC, EncoderCtlSetDart>(
            'opus_encoder_ctl'),
        decoderCreate = lib.lookupFunction<_DecoderCreateC, DecoderCreateDart>(
            'opus_decoder_create'),
        decode = lib.lookupFunction<_DecodeC, DecodeDart>('opus_decode'),
        decoderDestroy =
            lib.lookupFunction<_DecoderDestroyC, DecoderDestroyDart>(
                'opus_decoder_destroy');
}
