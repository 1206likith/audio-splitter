import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';

import 'package:audio_splitter_app/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('app shows host and client tabs', (tester) async {
    tester.view.physicalSize = const Size(1440, 2200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(const AudioSplitterApp());
    await tester.pump();

    expect(find.text('Audio Splitter'), findsOneWidget);
    expect(find.widgetWithText(Tab, 'Host'), findsOneWidget);
    expect(find.widgetWithText(Tab, 'Client'), findsOneWidget);
  });
}
