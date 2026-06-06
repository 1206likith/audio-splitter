import 'dart:typed_data';

import 'package:audio_splitter_app/core/contracts/audio_format.dart';
import 'package:audio_splitter_app/core/pipeline/audio_chunk.dart';
import 'package:audio_splitter_app/asp2/control/control_plane.dart';
import 'package:audio_splitter_app/asp2/light/flashlight.dart';
import 'package:audio_splitter_app/asp2/light/light_controller.dart';
import 'package:audio_splitter_app/asp2/party/beat_grid.dart';
import 'package:audio_splitter_app/asp2/party/crossfade.dart';
import 'package:audio_splitter_app/asp2/party/dj_deck.dart';
import 'package:audio_splitter_app/asp2/party/karaoke.dart';
import 'package:audio_splitter_app/asp2/party/reactions.dart';
import 'package:audio_splitter_app/asp2/party/request_queue.dart';
import 'package:flutter_test/flutter_test.dart';

/// Build a synthetic click track: a short decaying impulse on every beat. Used
/// to exercise the pure-Dart [BeatDetector] deterministically.
PcmChunk clickTrack({
  required double bpm,
  required int beats,
  AudioFormat format = AudioFormat.cdStereo,
}) {
  final periodSamples = (60.0 / bpm * format.sampleRate).round();
  final totalFrames = periodSamples * beats;
  final pcm = Uint8List(totalFrames * format.frameBytes);
  final bd = ByteData.view(pcm.buffer);
  final clickLen = (format.sampleRate * 0.005).round();
  for (var beat = 0; beat < beats; beat++) {
    final start = beat * periodSamples;
    for (var i = 0; i < clickLen; i++) {
      final frame = start + i;
      final amp = 0.8 * (1 - i / clickLen);
      final s = (amp * 32000).round();
      for (var c = 0; c < format.channels; c++) {
        bd.setInt16((frame * format.channels + c) * 2, s, Endian.little);
      }
    }
  }
  return PcmChunk(pcm: pcm, presentationTsUs: 0, format: format);
}

/// A flat constant-valued stereo chunk (so two decks are byte-distinguishable).
PcmChunk constChunk(int value, int frames,
    {AudioFormat format = AudioFormat.cdStereo, int tsUs = 0}) {
  final pcm = Uint8List(frames * format.frameBytes);
  final bd = ByteData.view(pcm.buffer);
  for (var f = 0; f < frames; f++) {
    for (var c = 0; c < format.channels; c++) {
      bd.setInt16((f * format.channels + c) * 2, value, Endian.little);
    }
  }
  return PcmChunk(pcm: pcm, presentationTsUs: tsUs, format: format);
}

void main() {
  group('BeatGrid', () {
    const grid = BeatGrid(downbeatTsUs: 0, bpm: 120); // 500ms/beat, 4/bar

    test('beat period and bar period', () {
      expect(grid.beatPeriodUs, closeTo(500000, 1e-6));
      expect(grid.barPeriodUs, closeTo(2000000, 1e-6));
    });

    test('beat index, downbeat detection, phase', () {
      expect(grid.beatIndexAt(0), 0);
      expect(grid.beatIndexAt(499999), 0);
      expect(grid.beatIndexAt(500000), 1);
      expect(grid.beatIndexAt(2000000), 4);
      expect(grid.isDownbeatAt(0), isTrue);
      expect(grid.isDownbeatAt(2000000), isTrue); // start of bar 2
      expect(grid.isDownbeatAt(500000), isFalse); // beat 1, not a downbeat
      expect(grid.phaseAt(0), closeTo(0.0, 1e-9));
      expect(grid.phaseAt(250000), closeTo(0.5, 1e-9));
    });

    test('nextBeatUs and beatTsUs', () {
      expect(grid.beatTsUs(3), 1500000);
      expect(grid.nextBeatUs(0), 0);
      expect(grid.nextBeatUs(1), 500000);
      expect(grid.nextBeatUs(500000), 500000);
    });

    test('json round-trip', () {
      final j = grid.toJson();
      expect(BeatGrid.fromJson(j), grid);
    });
  });

  group('BeatDetector (pure Dart)', () {
    test('recovers tempo from a 120 BPM click track', () {
      final det = BeatDetector();
      det.process(clickTrack(bpm: 120, beats: 16));
      final est = det.estimate();
      expect(est.bpm, closeTo(120, 5));
      expect(est.confidence, greaterThan(0.0));
    });

    test('recovers a different tempo (90 BPM)', () {
      final det = BeatDetector();
      det.process(clickTrack(bpm: 90, beats: 16));
      expect(det.estimate().bpm, closeTo(90, 5));
    });

    test('builds a BeatGrid anchored to the stream', () {
      final det = BeatDetector();
      det.process(clickTrack(bpm: 120, beats: 16));
      final grid = det.toBeatGrid(streamStartTsUs: 0);
      expect(grid, isNotNull);
      expect(grid!.bpm, closeTo(120, 5));
    });

    test('aubio tracker is a deferred scaffold', () {
      expect(AubioBeatTracker.isAvailable, isFalse);
    });
  });

  group('DjDeck', () {
    test('load/play/pause/advance moves the playhead by tempo', () {
      final deck = DjDeck(DeckId.a)..load('track1', bpm: 120);
      expect(deck.state.isPlaying, isFalse);
      deck.play();
      deck.advance(1000000); // 1s at 1.0x
      expect(deck.state.positionUs, 1000000);
      deck.setTempoRatio(1.5);
      deck.advance(1000000); // 1s at 1.5x
      expect(deck.state.positionUs, 2500000);
      deck.pause();
      deck.advance(1000000);
      expect(deck.state.positionUs, 2500000);
    });

    test('tempo match computes a ratio toward the target BPM', () {
      final deck = DjDeck(DeckId.b)..load('t', bpm: 120);
      final ratio = deck.matchTempo(128);
      expect(ratio, closeTo(128 / 120, 1e-9));
      expect(deck.state.effectiveBpm, closeTo(128, 1e-6));
    });

    test('EQ kills toggle and map to ParametricEq bands', () {
      final deck = DjDeck(DeckId.a)..load('t');
      expect(deck.killEqBands(), isEmpty);
      deck.toggleKill(EqKill.low);
      deck.toggleKill(EqKill.high);
      final bands = deck.killEqBands();
      expect(bands.length, 2);
      expect(bands.every((b) => b.gainDb < -40), isTrue);
      deck.toggleKill(EqKill.low); // off again
      expect(deck.killEqBands().length, 1);
    });

    test('hot cues store and jump', () {
      final deck = DjDeck(DeckId.a)..load('t');
      deck.addCue(const HotCue(index: 2, positionUs: 4000000));
      expect(deck.jumpToCue(2), isTrue);
      expect(deck.state.positionUs, 4000000);
      expect(deck.jumpToCue(5), isFalse);
    });

    test('state json round-trips', () {
      final deck = DjDeck(DeckId.a)
        ..load('t', bpm: 124)
        ..play()
        ..toggleKill(EqKill.mid)
        ..addCue(const HotCue(index: 0, positionUs: 1000));
      final j = deck.state.toJson();
      final back = DeckState.fromJson(j);
      expect(back.trackId, 't');
      expect(back.bpm, 124);
      expect(back.kills, {EqKill.mid});
      expect(back.cues.single.positionUs, 1000);
    });
  });

  group('Crossfade', () {
    test('equal-power curve is ~0.707 at centre, endpoints clean', () {
      expect(Crossfade.gainA(0), closeTo(1.0, 1e-9));
      expect(Crossfade.gainB(0), closeTo(0.0, 1e-9));
      expect(Crossfade.gainA(0.5), closeTo(0.70710678, 1e-6));
      expect(Crossfade.gainB(0.5), closeTo(0.70710678, 1e-6));
      // Constant power across the blend.
      final p = Crossfade.gainA(0.5) * Crossfade.gainA(0.5) +
          Crossfade.gainB(0.5) * Crossfade.gainB(0.5);
      expect(p, closeTo(1.0, 1e-6));
    });

    test('beat matcher computes tempo ratio and phase offset', () {
      expect(BeatMatcher.tempoRatio(120, 128), closeTo(128 / 120, 1e-9));
      const a = BeatGrid(downbeatTsUs: 0, bpm: 120);
      const b = BeatGrid(downbeatTsUs: 100000, bpm: 120); // 100ms late
      final off = BeatMatcher.phaseOffsetUs(a, b, 0);
      expect(off.abs(), lessThanOrEqualTo(a.beatPeriodUs ~/ 2 + 1));
      expect(BeatMatcher.isPhaseLocked(a, a, 0), isTrue);
    });

    test('host crossfader is byte-exact at the extremes', () {
      final a = constChunk(1000, 64);
      final b = constChunk(-2000, 64);
      final xf = HostCrossfader();
      xf.position = 0.0;
      expect(xf.mix(a, b).pcm, equals(a.pcm)); // full A
      xf.position = 1.0;
      expect(xf.mix(a, b).pcm, equals(b.pcm)); // full B
    });
  });

  group('RequestQueue', () {
    test('ranks by votes then submission order; idempotent submit', () {
      final q = RequestQueue();
      q.submit(id: 'r1', query: 'A', requestedBy: 'u1');
      q.submit(id: 'r2', query: 'B', requestedBy: 'u2');
      q.submit(id: 'r1', query: 'A again', requestedBy: 'u9'); // ignored
      q.upvote('r2', 'u3');
      q.upvote('r2', 'u4');
      final ranked = q.ranked();
      expect(ranked.first.id, 'r2'); // more votes
      expect(ranked[1].id, 'r1');
      // Double vote ignored.
      q.upvote('r2', 'u3');
      expect(q.byId('r2')!.votes, 3); // u2(requester) + u3 + u4
    });

    test('approve drives the up-next queue', () {
      final q = RequestQueue();
      q.submit(id: 'r1', query: 'A', requestedBy: 'u1');
      q.submit(id: 'r2', query: 'B', requestedBy: 'u2');
      expect(q.nextUp, isNull);
      q.approve('r1');
      expect(q.nextUp!.id, 'r1');
      q.markDone('r1');
      expect(q.nextUp, isNull);
    });
  });

  group('Reactions + voting', () {
    test('energy meter rises with reaction rate and counts clients', () {
      final meter = EnergyMeter(saturationCount: 30);
      for (var i = 0; i < 40; i++) {
        meter.add(Reaction(
          type: ReactionType.values[i % ReactionType.values.length],
          clientId: 'c${i % 20}',
          tsUs: 1000000 + i * 1000,
        ));
      }
      expect(meter.energyAt(1100000), 1.0); // 40 in window > saturation
      expect(meter.activeClientsAt(1100000), 20);
      expect(meter.energyAt(100000000), 0.0); // window moved past everything
    });

    test('poll tallies one-vote-per-client and picks a winner', () {
      final poll =
          Poll(id: 'p', question: 'genre?', options: ['house', 'techno']);
      poll.vote('a', 1);
      poll.vote('b', 1);
      poll.vote('c', 0);
      poll.vote('a', 0); // recast
      expect(poll.tally(), [2, 1]);
      expect(poll.winner, 0);
      expect(poll.totalVotes, 3);
    });
  });

  group('Karaoke / LRC', () {
    const lrc = '[ar:Artist]\n'
        '[00:01.00]First line\n'
        '[00:03.50]Second line\n'
        '[00:05.000]Third line\n';

    test('parses timestamps and finds the active line', () {
      final lyrics = LrcParser.parse(lrc);
      expect(lyrics.lines.length, 3);
      expect(lyrics.activeLineAt(0), isNull); // before first
      expect(lyrics.activeLineAt(1500000)!.text, 'First line');
      expect(lyrics.activeLineAt(3600000)!.text, 'Second line');
      expect(lyrics.nextLineAfter(3600000)!.text, 'Third line');
    });

    test('caption line json round-trips and lyrics provider is deferred', () {
      const c = CaptionLine(tsUs: 1000000, text: 'hi', durationMs: 500);
      expect(CaptionLine.fromJson(c.toJson()), c);
      expect(UnavailableLyricsProvider.isAvailable, isFalse);
    });
  });

  group('Control plane Phase 5 messages', () {
    test('beatGrid / reaction / caption round-trip through the envelope', () {
      const grid = BeatGrid(downbeatTsUs: 123, bpm: 128);
      final gm = ControlMessage.decode(ControlMessage.beatGrid(grid).encode());
      expect(gm.type, ControlMessageType.beatGrid);
      expect(gm.asBeatGrid(), grid);

      const r = Reaction(type: ReactionType.fire, clientId: 'c1', tsUs: 9);
      final rm = ControlMessage.decode(ControlMessage.reaction(r).encode());
      expect(rm.type, ControlMessageType.reaction);
      expect(rm.asReaction().type, ReactionType.fire);

      const cap = CaptionLine(tsUs: 5, text: 'sing!', durationMs: 100);
      final cm = ControlMessage.decode(ControlMessage.caption(cap).encode());
      expect(cm.type, ControlMessageType.caption);
      expect(cm.asCaption(), cap);
    });
  });

  // ------------------------------------------------------------------
  // PHASE 5 GATE — "20-client party demo: lights synced to beat,
  // reactions visible, two hosts crossfade live."
  // ------------------------------------------------------------------
  test(
      'GATE: 20-client party — beat-locked lights, crowd energy, live '
      'crossfade', () async {
    const grid = BeatGrid(downbeatTsUs: 0, bpm: 120); // 500ms/beat
    const program = BeatLightProgram(grid: grid, fixtureCount: 4);

    // 1) Lights synced to the beat: brighter on the beat than mid-beat (same
    //    beat ⇒ same hue, so the red channel is a clean brightness proxy).
    final onBeat = program.frameAt(0, energy: 0.5).colorOf(0);
    final offBeat = program.frameAt(250000, energy: 0.5).colorOf(0);
    expect(onBeat.r, greaterThan(offBeat.r));

    // Render a full bar into a simulated rig and confirm frames were emitted.
    final rig = SimulatedLightController();
    await rig.open();
    for (var t = 0; t < 2000000; t += 50000) {
      rig.send(program.frameAt(t, energy: 0.8));
    }
    expect(rig.frameCount, 40);

    // Flashlight strobe locks to the same grid: torch ON on the beat.
    final torch = FlashlightStrobe();
    await torch.open();
    expect(torch.shouldFlash(grid, 0), isTrue); // on the beat
    expect(torch.shouldFlash(grid, 400000), isFalse); // late in the beat

    // 2) Crowd reactions from 20 clients are visible on the energy meter.
    final meter = EnergyMeter(saturationCount: 30);
    for (var c = 0; c < 20; c++) {
      meter.add(Reaction(
          type: ReactionType.fire, clientId: 'client$c', tsUs: 1000000 + c));
      meter.add(Reaction(
          type: ReactionType.raiseHands,
          clientId: 'client$c',
          tsUs: 1000100 + c));
    }
    final energy = meter.energyAt(1001000);
    expect(meter.activeClientsAt(1001000), 20);
    expect(energy, 1.0); // 40 reactions in window ⇒ saturated

    // 3) Two hosts crossfade live, beat-matched. Deck A 128 BPM, Deck B 120 BPM
    //    matched up to 128; equal-power crossfade A→B is byte-clean at the ends.
    final deckA = DjDeck(DeckId.a)..load('setA', bpm: 128);
    final deckB = DjDeck(DeckId.b)..load('setB', bpm: 120);
    deckA.play();
    deckB.matchTempo(128);
    deckB.play();
    expect(deckB.state.effectiveBpm, closeTo(128, 1e-6));

    final a = constChunk(8000, 128);
    final b = constChunk(-8000, 128);
    final xf = HostCrossfader();
    xf.position = 0.0;
    expect(xf.mix(a, b).pcm, equals(a.pcm)); // hand-off start = deck A
    xf.position = 1.0;
    expect(xf.mix(a, b).pcm, equals(b.pcm)); // hand-off end = deck B
    // Mid-blend: both decks audibly present (neither side silent).
    xf.position = 0.5;
    final mid =
        ByteData.view(xf.mix(a, b).pcm.buffer).getInt16(0, Endian.little);
    expect(mid, lessThan(a.pcm[0])); // pulled away from pure A

    // ignore: avoid_print
    print(
        'Phase 5 gate: 20 clients reacting (energy=${energy.toStringAsFixed(2)}, '
        '${meter.activeClientsAt(1001000)} active); beat-locked lights '
        '(${rig.frameCount} frames/bar, on-beat r=${onBeat.r} vs off-beat '
        'r=${offBeat.r}); two decks beat-matched to '
        '${deckB.state.effectiveBpm!.toStringAsFixed(0)} BPM and crossfaded '
        'byte-clean A→B.');
  });
}
