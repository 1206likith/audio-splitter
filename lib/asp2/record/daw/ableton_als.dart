import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../stem_recorder.dart';

/// Generates an **Ableton Live Set** (`.als`) referencing the recorded stems,
/// one Audio Track per stem with its clip pre-placed at the captured timeline
/// position. An `.als` is gzip-compressed XML; [buildXml] produces the XML (the
/// deterministic, unit-testable part) and [encode] gzips it into the final
/// `.als` bytes.
///
/// The Live Set schema is large and version-specific. This emits a structurally
/// faithful subset — `Ableton → LiveSet → Tracks → AudioTrack → … → AudioClip →
/// SampleRef` with clip start/end in beats and the sample path — which the gate
/// validates structurally. **Opening byte-for-byte in a specific Ableton build
/// is [needs-app-verify]** (no Ableton on this dev machine); the Reaper `.rpp`
/// export is the fully-verifiable DAW target. Positions are derived the same way
/// for both, so the placement logic is covered regardless.
class AbletonProject {
  AbletonProject._();

  /// Build the Live Set XML for [session]. Clip positions are in beats at
  /// [tempo] BPM (`beats = seconds * tempo / 60`).
  static String buildXml(
    RecordedSession session, {
    required String Function(RecordedStem stem) stemPathFor,
    double tempo = 120.0,
  }) {
    final beatsPerSecond = tempo / 60.0;
    final b = StringBuffer();
    b.writeln('<?xml version="1.0" encoding="UTF-8"?>');
    b.writeln('<Ableton MajorVersion="5" MinorVersion="11.0_11300" '
        'SchemaChangeCount="3" Creator="AudioSplitter v2" Revision="">');
    b.writeln('  <LiveSet>');
    b.writeln('    <Tempo><Manual Value="${_num(tempo)}"/></Tempo>');
    b.writeln('    <Tracks>');

    var trackId = 0;
    for (final stem in session.stems) {
      final start = _num(stem.startSeconds * beatsPerSecond);
      final end = _num(stem.endSeconds * beatsPerSecond);
      final name = _esc(stem.spec.name);
      final path = _esc(stemPathFor(stem));
      b.writeln('      <AudioTrack Id="$trackId">');
      b.writeln('        <Name>');
      b.writeln('          <EffectiveName Value="$name"/>');
      b.writeln('          <UserName Value="$name"/>');
      b.writeln('        </Name>');
      b.writeln('        <DeviceChain>');
      b.writeln('          <MainSequencer>');
      b.writeln('            <Sample>');
      b.writeln('              <ArrangerAutomation>');
      b.writeln('                <Events>');
      b.writeln('                  <AudioClip Id="$trackId" Time="$start">');
      b.writeln('                    <CurrentStart Value="$start"/>');
      b.writeln('                    <CurrentEnd Value="$end"/>');
      b.writeln('                    <Name Value="$name"/>');
      b.writeln('                    <SampleRef>');
      b.writeln('                      <FileRef>');
      b.writeln('                        <RelativePathType Value="3"/>');
      b.writeln('                        <RelativePath Value="$path"/>');
      b.writeln('                        <Path Value="$path"/>');
      b.writeln('                      </FileRef>');
      b.writeln('                    </SampleRef>');
      b.writeln('                  </AudioClip>');
      b.writeln('                </Events>');
      b.writeln('              </ArrangerAutomation>');
      b.writeln('            </Sample>');
      b.writeln('          </MainSequencer>');
      b.writeln('        </DeviceChain>');
      b.writeln('      </AudioTrack>');
      trackId++;
    }

    b.writeln('    </Tracks>');
    b.writeln('  </LiveSet>');
    b.writeln('</Ableton>');
    return b.toString();
  }

  /// Build and gzip the Live Set into final `.als` bytes.
  static Uint8List encode(
    RecordedSession session, {
    required String Function(RecordedStem stem) stemPathFor,
    double tempo = 120.0,
  }) {
    final xml = buildXml(session, stemPathFor: stemPathFor, tempo: tempo);
    return Uint8List.fromList(gzip.encode(utf8.encode(xml)));
  }

  static String _num(double v) => v.toStringAsFixed(6);

  static String _esc(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');
}
