import 'dart:math' as math;

import '../../core/contracts/audio_format.dart';
import '../../core/contracts/i_audio_sink.dart';
import '../../core/pipeline/audio_chunk.dart';
import '../dsp/pcm_float.dart';

/// One haptic pulse the device's vibration motor would play: an intensity in
/// `[0,1]` at a host-clock timestamp.
class HapticPulse {
  final double intensity;
  final int tsUs;

  const HapticPulse({required this.intensity, required this.tsUs});

  @override
  String toString() => 'HapticPulse(${(intensity * 100).round()}% @${tsUs}us)';
}

/// **Haptic-bass sink** ([IAudioSink]) — feels the kick. It low-passes the PCM
/// to isolate sub-bass energy and, on each rising bass transient, emits a
/// [HapticPulse] the phone's vibration motor plays, so the crowd *feels* the
/// drop even where it can't be loud.
///
/// The DSP (bass envelope + onset → pulse) is pure and tested; the actual motor
/// call (`HapticFeedback.vibrate` / a duration-amplitude plugin) is
/// **[needs-hardware]** and deferred. In [simulate] mode (default) pulses are
/// recorded in [pulses]; the real path leaves [unavailableReason] set.
class HapticSink implements IAudioSink {
  @override
  final String id;

  /// Record pulses instead of driving the motor (default; testable). Set false
  /// to target a real device — which is unavailable here, so [open] returns
  /// false and names the reason.
  final bool simulate;

  /// Low-pass cutoff isolating the "bass you feel" band.
  final double cutoffHz;

  /// Rising-edge bass-energy delta above which a pulse fires.
  final double onsetThreshold;

  /// Minimum spacing between pulses (debounce), microseconds.
  final int minIntervalUs;

  final List<HapticPulse> pulses = [];
  String? unavailableReason;

  double _lpState = 0.0; // one-pole low-pass memory
  double _prevEnergy = 0.0;
  int _lastPulseTsUs = -1 << 30;
  bool _open = false;

  HapticSink({
    this.id = 'haptic',
    this.simulate = true,
    this.cutoffHz = 120,
    this.onsetThreshold = 0.02,
    this.minIntervalUs = 90000, // ~max 11 pulses/sec
  });

  static bool get isAvailable => false;

  bool get isOpen => _open;

  @override
  Future<bool> open(AudioFormat format) async {
    if (!simulate) {
      unavailableReason =
          'No vibration motor available on this build for "$id"; '
          'wire HapticFeedback/amplitude plugin on the device path.';
      return false;
    }
    _open = true;
    return true;
  }

  @override
  void write(PcmChunk chunk) {
    // Tolerate writes before open (simulate path buffers; real path is inert).
    if (!simulate && !_open) return;
    final channels = PcmFloat.deinterleave(chunk.pcm, chunk.format);
    if (channels.isEmpty) return;
    final frames = channels[0].length;
    if (frames == 0) return;

    // One-pole low-pass coefficient for the cutoff, then mean-square of the
    // low-passed mono signal = bass energy over this chunk.
    final sr = chunk.format.sampleRate.toDouble();
    final dt = 1.0 / sr;
    final rc = 1.0 / (2 * math.pi * cutoffHz);
    final alpha = dt / (rc + dt);

    var sumSq = 0.0;
    for (var f = 0; f < frames; f++) {
      var mono = 0.0;
      for (final ch in channels) {
        mono += f < ch.length ? ch[f] : 0.0;
      }
      mono /= channels.length;
      _lpState += alpha * (mono - _lpState);
      sumSq += _lpState * _lpState;
    }
    final energy = sumSq / frames;

    final rise = energy - _prevEnergy;
    _prevEnergy = energy;

    final tsUs = chunk.presentationTsUs;
    if (rise > onsetThreshold && tsUs - _lastPulseTsUs >= minIntervalUs) {
      final intensity = (rise * 8).clamp(0.0, 1.0);
      _emit(HapticPulse(intensity: intensity, tsUs: tsUs));
      _lastPulseTsUs = tsUs;
    }
  }

  void _emit(HapticPulse pulse) {
    if (simulate) {
      pulses.add(pulse);
    }
    // Real: vibrate(duration, amplitude=(pulse.intensity*255)) — deferred.
  }

  @override
  Future<void> close() async {
    _open = false;
  }
}
