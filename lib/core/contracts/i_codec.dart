import 'dart:typed_data';

import 'audio_format.dart';

/// Codec IDs as encoded in the ASP-2 frame header (byte 1, `codec_id`).
///
/// Reserved 4..15 for future codecs. Adding a codec never changes the protocol;
/// it only consumes a new ID.
class CodecId {
  static const int pcm16 = 0;
  static const int opus = 1;
  static const int lc3 = 2;
  static const int flac = 3;
}

/// A media codec: PCM16 in, encoded payload out (and the reverse).
///
/// Codecs are protocol-agnostic — they know nothing about transports, framing,
/// or encryption. The frame layer slots the [codecId] into the header.
abstract class ICodec {
  /// The ASP-2 codec_id written into the frame header.
  int get codecId;

  /// The PCM format this codec instance is configured for.
  AudioFormat get format;

  /// Encode raw PCM16 to this codec's payload representation.
  Uint8List encode(Uint8List pcm16);

  /// Decode a payload back to PCM16.
  ///
  /// Implementations that support packet-loss concealment may accept an empty
  /// or null payload to synthesise a gap-filling frame.
  Uint8List decode(Uint8List payload);

  /// Release any native resources held by this codec.
  void dispose();
}
