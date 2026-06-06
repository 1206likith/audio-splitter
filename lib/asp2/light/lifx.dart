import 'dart:typed_data';

import 'light_controller.dart';

/// Builds **LIFX LAN protocol** UDP messages for controlling LIFX bulbs on the
/// local network. The 36-byte header + payload layout is pure bytes and
/// golden-byte testable; the UDP socket that sends it is **[needs-hardware]** and
/// deferred ([LifxLight]).
///
/// Header: Frame(8) · FrameAddress(16) · ProtocolHeader(12) · payload. The
/// `SetColor` message (type 102) carries an HSBK colour + transition duration.
class LifxPacket {
  LifxPacket._();

  /// LIFX message type for `SetColor`.
  static const int typeSetColor = 102;

  /// Encode a `SetColor` message for [color] with a [durationMs] transition.
  /// [target] is the 8-byte device MAC (0 = broadcast to all bulbs); [source]
  /// identifies this client; [sequence] lets the client match acks.
  static Uint8List buildSetColor(
    RgbColor color, {
    int target = 0,
    int source = 2,
    int sequence = 0,
    int durationMs = 0,
    int kelvin = 3500,
  }) {
    const headerSize = 36;
    const payloadSize = 13; // reserved(1) + HSBK(8) + duration(4)
    const total = headerSize + payloadSize;
    final out = Uint8List(total);
    final bd = ByteData.view(out.buffer);

    // --- Frame header (8 bytes) ---
    bd.setUint16(0, total, Endian.little); // size
    // protocol(12 bits)=1024, addressable=1, tagged=1 (broadcast), origin=0.
    // Packed little-endian uint16: low 12 bits protocol, bit12 addressable,
    // bit13 tagged, bits14-15 origin.
    final tagged = target == 0 ? 1 : 0;
    final flags = 1024 | (1 << 12) | (tagged << 13);
    bd.setUint16(2, flags, Endian.little);
    bd.setUint32(4, source, Endian.little);

    // --- Frame address (16 bytes) ---
    bd.setUint64(8, target, Endian.little); // target MAC (8 bytes)
    // bytes 16..21 reserved (6)
    out[22] = 0x00; // res_required / ack_required flags = 0
    out[23] = sequence & 0xff;

    // --- Protocol header (12 bytes) ---
    // bytes 24..31 reserved (uint64)
    bd.setUint16(32, typeSetColor, Endian.little);
    // bytes 34..35 reserved

    // --- Payload: SetColor (13 bytes) ---
    out[36] = 0x00; // reserved
    final hsbk = _toHsbk(color);
    bd.setUint16(37, hsbk[0], Endian.little); // hue
    bd.setUint16(39, hsbk[1], Endian.little); // saturation
    bd.setUint16(41, hsbk[2], Endian.little); // brightness
    bd.setUint16(43, kelvin, Endian.little); // kelvin
    bd.setUint32(45, durationMs, Endian.little);
    return out;
  }

  /// Convert RGB to LIFX HSBK 16-bit hue/sat/bri (kelvin handled separately).
  static List<int> _toHsbk(RgbColor c) {
    final r = c.r / 255, g = c.g / 255, b = c.b / 255;
    final max = [r, g, b].reduce((a, x) => a > x ? a : x);
    final min = [r, g, b].reduce((a, x) => a < x ? a : x);
    final delta = max - min;
    double hue = 0;
    if (delta != 0) {
      if (max == r) {
        hue = ((g - b) / delta) % 6;
      } else if (max == g) {
        hue = (b - r) / delta + 2;
      } else {
        hue = (r - g) / delta + 4;
      }
      hue *= 60;
      if (hue < 0) hue += 360;
    }
    final sat = max == 0 ? 0.0 : delta / max;
    final bri = max;
    return [
      (hue / 360 * 65535).round().clamp(0, 65535),
      (sat * 65535).round().clamp(0, 65535),
      (bri * 65535).round().clamp(0, 65535),
    ];
  }
}

/// **[needs-hardware]** LIFX bulb scaffold. Packet encoding ([LifxPacket]) is
/// done/tested; binding a UDP socket and broadcasting on the LAN is deferred to
/// the device path. Renders only fixture 0's colour (one bulb).
class LifxLight implements LightController {
  @override
  final String id;

  final String host;
  final int port;

  LifxLight(
      {this.id = 'lifx', this.host = '255.255.255.255', this.port = 56700});

  static bool get isAvailable => false;

  Uint8List? lastPacket;
  int _sequence = 0;

  @override
  Future<bool> open() async => false; // UDP socket deferred

  @override
  void send(LightFrame frame) {
    final color = frame.fixtures.isEmpty
        ? RgbColor.black
        : frame.fixtures.first.color.dim(frame.masterDimmer);
    lastPacket = LifxPacket.buildSetColor(color, sequence: _sequence);
    _sequence = (_sequence + 1) & 0xff;
  }

  @override
  Future<void> close() async {}
}
