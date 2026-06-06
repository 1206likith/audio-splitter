import 'dart:math' as math;
import 'dart:typed_data';

import '../../core/contracts/audio_format.dart';
import '../../core/pipeline/audio_chunk.dart';
import '../dsp/pcm_float.dart';
import 'positioning.dart';

/// A direction to a sound source relative to the listener, as azimuth +
/// elevation in **degrees**. Azimuth is measured counter-clockwise from front
/// (0° = ahead, +90° = left, −90° = right); elevation is up from the horizontal
/// plane. This is the angle a first-order ambisonic encode needs.
class SphericalDir {
  final double azimuthDeg;
  final double elevationDeg;

  const SphericalDir({this.azimuthDeg = 0.0, this.elevationDeg = 0.0});

  /// Direction from a [listener] to a [source] point on the floorplan, with the
  /// listener's heading folded in so "front" tracks where they face. Elevation
  /// is 0 (the floorplan is a horizontal plane).
  factory SphericalDir.fromFloorplan(ListenerPose listener, Vec2 source) {
    final dx = source.x - listener.position.x;
    final dy = source.y - listener.position.y;
    // World bearing: 0° = +Y ("into the room"), increasing clockwise, matching
    // ListenerPose.headingDeg. atan2(dx, dy) gives that clockwise-from-+Y angle.
    final worldBearingDeg = math.atan2(dx, dy) * 180.0 / math.pi;
    // Azimuth relative to where the listener faces; CCW-from-front positive.
    final rel = listener.headingDeg - worldBearingDeg;
    return SphericalDir(azimuthDeg: rel, elevationDeg: 0.0);
  }

  double get azimuthRad => azimuthDeg * math.pi / 180.0;
  double get elevationRad => elevationDeg * math.pi / 180.0;
}

/// **First-order ambisonic B-format** (ACN channel order, SN3D normalization):
/// four coincident coefficient signals `W, Y, Z, X` describing a full-sphere
/// sound field. W is the omni (pressure) component; X/Y/Z are the figure-of-
/// eight gradients along front, left, and up. One [BFormat] holds all four
/// channels for a chunk of audio.
class BFormat {
  final Float64List w;
  final Float64List y;
  final Float64List z;
  final Float64List x;

  BFormat(this.w, this.y, this.z, this.x)
      : assert(w.length == y.length &&
            y.length == z.length &&
            z.length == x.length);

  int get frames => w.length;

  /// A silent field of [frames] samples.
  factory BFormat.silent(int frames) => BFormat(Float64List(frames),
      Float64List(frames), Float64List(frames), Float64List(frames));
}

/// Encodes mono sources into [BFormat]. SN3D coefficients for a source in
/// direction [dir]:  W = 1,  Y = sin(az)cos(el),  Z = sin(el),  X = cos(az)cos(el).
/// Multiple sources sum into the same field (ambisonics is linear), so a whole
/// scene is one B-format buffer.
class AmbisonicEncoder {
  AmbisonicEncoder._();

  /// SN3D coefficients `[W, Y, Z, X]` for a unit source in [dir].
  static List<double> coefficients(SphericalDir dir) {
    final az = dir.azimuthRad, el = dir.elevationRad;
    final cosEl = math.cos(el);
    return [
      1.0, // W
      math.sin(az) * cosEl, // Y
      math.sin(el), // Z
      math.cos(az) * cosEl, // X
    ];
  }

  /// Encode a mono signal in direction [dir] into a fresh [BFormat].
  static BFormat encodeMono(Float64List mono, SphericalDir dir) {
    final c = coefficients(dir);
    final n = mono.length;
    final w = Float64List(n), y = Float64List(n), z = Float64List(n);
    final x = Float64List(n);
    for (var i = 0; i < n; i++) {
      final s = mono[i];
      w[i] = s * c[0];
      y[i] = s * c[1];
      z[i] = s * c[2];
      x[i] = s * c[3];
    }
    return BFormat(w, y, z, x);
  }

  /// Encode a (possibly multi-channel) [PcmChunk] — collapsed to mono — placed
  /// in direction [dir].
  static BFormat encodeChunk(PcmChunk chunk, SphericalDir dir) {
    final channels = PcmFloat.deinterleave(chunk.pcm, chunk.format);
    if (channels.isEmpty) return BFormat.silent(0);
    final frames = channels[0].length;
    final mono = Float64List(frames);
    for (var f = 0; f < frames; f++) {
      var sum = 0.0;
      for (final ch in channels) {
        sum += f < ch.length ? ch[f] : 0.0;
      }
      mono[f] = sum / channels.length;
    }
    return encodeMono(mono, dir);
  }

  /// Sum several fields into one (in-scene mixing). All must share frame count.
  static BFormat mixFields(List<BFormat> fields) {
    if (fields.isEmpty) return BFormat.silent(0);
    final n = fields.first.frames;
    final out = BFormat.silent(n);
    for (final f in fields) {
      final m = math.min(n, f.frames);
      for (var i = 0; i < m; i++) {
        out.w[i] += f.w[i];
        out.y[i] += f.y[i];
        out.z[i] += f.z[i];
        out.x[i] += f.x[i];
      }
    }
    return out;
  }
}

/// Rotates and decodes a [BFormat] field for one listener orientation.
///
/// **Yaw rotation** is what makes head tracking work: when the listener turns
/// their head [headingDeg], the whole sound field counter-rotates so sources
/// stay world-locked. For first order this only mixes the horizontal X/Y pair
/// (W omni and Z vertical are invariant). The stereo decode is a coincident
/// cardioid pair pointing hard-left / hard-right — cheap, headphone-friendly,
/// and exact at the cardinal directions (a source at +90° is left-only).
class AmbisonicDecoder {
  AmbisonicDecoder._();

  /// Counter-rotate the field by the listener's yaw [headingDeg] so the scene
  /// stays fixed as the head turns. Returns a fresh field.
  static BFormat rotateYaw(BFormat field, double headingDeg) {
    final theta = headingDeg * math.pi / 180.0;
    final c = math.cos(theta), s = math.sin(theta);
    final n = field.frames;
    final x = Float64List(n), y = Float64List(n);
    for (var i = 0; i < n; i++) {
      // Rotate the horizontal gradients; front (X) and left (Y) mix.
      x[i] = field.x[i] * c + field.y[i] * s;
      y[i] = -field.x[i] * s + field.y[i] * c;
    }
    return BFormat(
        Float64List.fromList(field.w), y, Float64List.fromList(field.z), x);
  }

  /// Decode [field] to interleaved stereo float channels `[L, R]` for a listener
  /// facing [headingDeg]. Left = ½(W + Y), Right = ½(W − Y): a virtual cardioid
  /// pair, so a hard-left source (Y = +1) lands fully in L, a centre source
  /// splits evenly, and a hard-right source lands fully in R.
  static List<Float64List> decodeStereo(BFormat field,
      {double headingDeg = 0.0}) {
    final rotated = headingDeg == 0.0 ? field : rotateYaw(field, headingDeg);
    final n = rotated.frames;
    final left = Float64List(n), right = Float64List(n);
    for (var i = 0; i < n; i++) {
      final w = rotated.w[i], y = rotated.y[i];
      left[i] = 0.5 * (w + y);
      right[i] = 0.5 * (w - y);
    }
    return [left, right];
  }

  /// Decode [field] to a stereo [PcmChunk] tagged at [tsUs].
  static PcmChunk decodeChunk(BFormat field,
      {double headingDeg = 0.0, int tsUs = 0}) {
    final stereo = decodeStereo(field, headingDeg: headingDeg);
    final pcm = PcmFloat.interleave(stereo, AudioFormat.cdStereo);
    return PcmChunk(
      pcm: pcm,
      presentationTsUs: tsUs,
      format: AudioFormat.cdStereo,
    );
  }
}
