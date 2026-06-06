import 'dart:io';

import 'package:audio_splitter_app/models/audio_stream.dart';
import 'package:audio_splitter_app/providers/app_state_provider.dart';
import 'package:audio_splitter_app/services/audio_service.dart';
import 'package:audio_splitter_app/widgets/audio_source_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // System-audio capture is a real, supported feature on Windows and Android
  // (native capture plugins ship for both). It is unsupported elsewhere. Keep
  // these expectations aligned with [AudioService.isSourceSupported] so the
  // suite is platform-robust across the CI matrix (ubuntu/windows/macos).
  final systemAudioSupported = Platform.isWindows || Platform.isAndroid;

  test('AudioService exposes supported capture sources and output routing',
      () async {
    final audioService = AudioService();

    expect(audioService.isSourceSupported(AudioSource.microphone), isTrue);
    expect(audioService.isSourceSupported(AudioSource.mediaFile), isTrue);
    expect(
      audioService.isSourceSupported(AudioSource.systemAudio),
      systemAudioSupported,
    );

    await audioService.setPreferSpeakerOutput(false);
    expect(audioService.preferSpeakerOutput, isFalse);

    await audioService.setPreferSpeakerOutput(true);
    expect(audioService.preferSpeakerOutput, isTrue);
  });

  testWidgets('Audio source selector selects supported capture sources',
      (tester) async {
    final appState = AppStateProvider();
    final audioService = AudioService();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: appState),
          Provider<AudioService>.value(value: audioService),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: AudioSourceSelector(),
          ),
        ),
      ),
    );

    await tester.pump();

    expect(find.text('Microphone'), findsOneWidget);
    expect(find.text('System Audio'), findsOneWidget);
    expect(find.text('Media File'), findsOneWidget);
    expect(find.text('Streaming'), findsOneWidget);

    await tester.tap(find.text('Microphone'));
    await tester.pump();
    expect(appState.selectedAudioSource, AudioSource.microphone);

    // Tapping System Audio selects it where supported; on unsupported
    // platforms the source stays microphone.
    await tester.tap(find.text('System Audio'));
    await tester.pump();
    expect(
      appState.selectedAudioSource,
      systemAudioSupported ? AudioSource.systemAudio : AudioSource.microphone,
    );
  });
}
