import 'dart:typed_data';

import 'light_controller.dart';

/// A DMX-512 universe: 512 single-byte channels (1-indexed in the lighting
/// world, 0-indexed here). RGB fixtures occupy 3 consecutive channels from a
/// base address. Pure data — the byte layout a controller streams to fixtures.
class DmxUniverse {
  /// 512 channel values.
  final Uint8List channels = Uint8List(512);

  /// Universe number (0–32767 in Art-Net's 15-bit space).
  final int universe;

  DmxUniverse({this.universe = 0});

  /// Set channel [index] (0–511) to [value] (0–255). Out-of-range is ignored.
  void setChannel(int index, int value) {
    if (index < 0 || index >= 512) return;
    channels[index] = value & 0xff;
  }

  /// Write [color] to an RGB fixture whose first channel is [baseChannel]
  /// (0-indexed), i.e. R→base, G→base+1, B→base+2.
  void setRgb(int baseChannel, RgbColor color) {
    setChannel(baseChannel, color.r);
    setChannel(baseChannel + 1, color.g);
    setChannel(baseChannel + 2, color.b);
  }

  /// Map a [LightFrame] onto this universe assuming [channelsPerFixture]
  /// (default 3 = RGB) contiguous channels per fixture, fixture 0 at channel 0.
  /// The master dimmer is folded into the colours.
  void applyFrame(LightFrame frame, {int channelsPerFixture = 3}) {
    for (final f in frame.fixtures) {
      final base = f.fixtureId * channelsPerFixture;
      setRgb(base, f.color.dim(frame.masterDimmer));
    }
  }

  void clear() => channels.fillRange(0, channels.length, 0);
}

/// Builds **Art-Net** `ArtDmx` packets — the standard way to carry DMX-512 over
/// UDP to lighting nodes/fixtures. The byte layout is fully specified, so this is
/// pure and golden-byte testable; only the UDP socket send is hardware/network
/// bound and is deferred ([ArtNetSender]).
class ArtNetPacket {
  ArtNetPacket._();

  /// Art-Net packet identifier: the ASCII `"Art-Net"` plus a null terminator.
  static const List<int> id = [0x41, 0x72, 0x74, 0x2D, 0x4E, 0x65, 0x74, 0x00];

  /// `OpOutput` / `OpDmx` opcode, transmitted little-endian.
  static const int opOutput = 0x5000;

  /// Art-Net protocol version 14.
  static const int protocolVersion = 14;

  /// Encode one ArtDmx packet for [universe] with [sequence] (0 disables the
  /// sequence field; 1–255 cycles). The DMX data length is padded to an even
  /// number of bytes as the spec requires (min 2).
  static Uint8List buildArtDmx(
    DmxUniverse universe, {
    int sequence = 0,
    int physical = 0,
  }) {
    var dataLen = universe.channels.length;
    if (dataLen.isOdd) dataLen += 1;
    if (dataLen < 2) dataLen = 2;

    final out = Uint8List(18 + dataLen);
    var i = 0;
    for (final b in id) {
      out[i++] = b;
    }
    // OpCode, little-endian.
    out[i++] = opOutput & 0xff;
    out[i++] = (opOutput >> 8) & 0xff;
    // Protocol version, big-endian (high byte first).
    out[i++] = (protocolVersion >> 8) & 0xff;
    out[i++] = protocolVersion & 0xff;
    // Sequence + physical.
    out[i++] = sequence & 0xff;
    out[i++] = physical & 0xff;
    // 15-bit universe: low byte (Sub-Uni) then high byte (Net).
    out[i++] = universe.universe & 0xff;
    out[i++] = (universe.universe >> 8) & 0x7f;
    // Data length, big-endian (high byte first).
    out[i++] = (dataLen >> 8) & 0xff;
    out[i++] = dataLen & 0xff;
    // DMX data.
    out.setRange(i, i + universe.channels.length, universe.channels);
    return out;
  }
}

/// **[needs-hardware]** Art-Net transmitter scaffold. Building the packet bytes
/// ([ArtNetPacket]) is done and tested; opening a UDP socket and blasting frames
/// at a real Art-Net node/rig is deferred to the device path. [isAvailable] is
/// false here so the party host falls back to [SimulatedLightController].
class ArtNetSender implements LightController {
  @override
  final String id;

  final String host;
  final int port;
  final DmxUniverse _universe;
  int _sequence = 1;

  ArtNetSender({
    this.id = 'artnet',
    this.host = '255.255.255.255',
    this.port = 6454,
    int universe = 0,
  }) : _universe = DmxUniverse(universe: universe);

  /// No real UDP socket is bound in this sandbox.
  static bool get isAvailable => false;

  /// The most recent packet that *would* be sent — exposed for testing the
  /// frame→DMX→Art-Net mapping without a socket.
  Uint8List? lastPacket;

  @override
  Future<bool> open() async => false; // socket binding deferred

  @override
  void send(LightFrame frame) {
    _universe.applyFrame(frame);
    lastPacket = ArtNetPacket.buildArtDmx(_universe, sequence: _sequence);
    _sequence = _sequence >= 255 ? 1 : _sequence + 1;
    // Real send (socket.send(lastPacket!, address, port)) deferred [needs-hardware].
  }

  @override
  Future<void> close() async {}
}
