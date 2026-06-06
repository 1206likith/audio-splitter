import 'package:flutter_test/flutter_test.dart';
import 'package:audio_splitter_app/main.dart' as app;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('App boots and shows HomeScreen', (tester) async {
    await tester.pumpWidget(const app.AudioSplitterApp());
    await tester.pumpAndSettle();

    expect(find.text('Audio Splitter'), findsOneWidget);
    expect(find.text('Host'), findsOneWidget);
    expect(find.text('Client'), findsOneWidget);
  });

  testWidgets('Can navigate to Host screen and select Media File source',
      (tester) async {
    await tester.pumpWidget(const app.AudioSplitterApp());
    await tester.pumpAndSettle();

    // Tap on Host button
    await tester.tap(find.text('Host'));
    await tester.pumpAndSettle();

    expect(find.text('Start Hosting'), findsOneWidget);
    expect(find.text('Audio Source'), findsOneWidget);

    // Select Media File source (tap dropdown value)
    await tester.tap(find.text('Microphone').first);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Media File').last);
    await tester.pumpAndSettle();

    // Now the UI should show the select file button
    expect(find.text('Select Audio File'), findsOneWidget);
  });
}
