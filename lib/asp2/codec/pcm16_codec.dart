import 'dart:typed_data';

import '../../core/contracts/audio_format.dart';
import '../../core/contracts/i_codec.dart';

/// Identity codec for raw PCM16 (ASP-2 codec_id = 0).
///
/// Pure Dart, no native dependency — this is the default low-latency LAN codec
/// and keeps CI green before the Opus FFI binary lands in Phase 1. Encode and
/// decode are pass-throughs; the value of routing PCM16 through [ICodec] is that
/// the frame layer treats every codec uniformly.
class Pcm16Codec implements ICodec {
  @override
  final AudioFormat format;

  Pcm16Codec({this.format = AudioFormat.cdStereo});

  @override
  int get codecId => CodecId.pcm16;

  @override
  Uint8List encode(Uint8List pcm16) => pcm16;

  @override
  Uint8List decode(Uint8List payload) => payload;

  @override
  void dispose() {}
}
