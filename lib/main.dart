import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:ui' as ui;
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:provider/provider.dart';
import 'screens/home_screen.dart' as advanced;
import 'providers/app_state_provider.dart';
import 'services/audio_service.dart';
import 'services/streaming_service.dart';
import 'services/bluetooth_service.dart';
import 'services/sync_service.dart';
import 'services/performance_service.dart';
import 'services/settings_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Guarded Firebase + Crashlytics init (non-fatal if not configured)
  try {
    await Firebase.initializeApp();
    FlutterError.onError = FirebaseCrashlytics.instance.recordFlutterFatalError;
    ui.PlatformDispatcher.instance.onError = (error, stack) {
      FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
      return true;
    };
  } catch (_) {
    // Firebase not configured; proceed without Crashlytics
  }
  runApp(const AudioSplitterApp());
}

class AudioSplitterApp extends StatelessWidget {
  const AudioSplitterApp({super.key});

  static ThemeData _buildLightTheme() {
    return ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF6750A4),
        brightness: Brightness.light,
      ),
    );
  }

  static ThemeData _buildDarkTheme() {
    return ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF6750A4),
        brightness: Brightness.dark,
        surface: const Color(0xFF1C1B1F),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider(create: (_) => SettingsService()),
        ChangeNotifierProxyProvider<SettingsService, AppStateProvider>(
          create: (ctx) => AppStateProvider(
            settingsService: ctx.read<SettingsService>(),
          ),
          update: (ctx, settings, previous) =>
              previous ?? AppStateProvider(settingsService: settings),
        ),
        Provider(create: (_) => AudioService()),
        // StreamingService is a ChangeNotifier, so it must use
        // ChangeNotifierProvider (a plain Provider trips Provider's
        // debugCheckInvalidValueType assert and crashes the widget tree in
        // debug/test). No widget watches it today, so this only adds correct
        // auto-disposal at app teardown — no behavior change.
        ChangeNotifierProvider(create: (_) => StreamingService()),
        Provider(create: (_) => BluetoothService()),
        Provider(create: (_) => SyncService()),
        Provider(create: (_) => PerformanceService()),
      ],
      child: MaterialApp(
        title: 'Audio Splitter',
        theme: _buildLightTheme(),
        darkTheme: _buildDarkTheme(),
        themeMode: ThemeMode.system,
        home: const advanced.HomeScreen(),
        debugShowCheckedModeBanner: false,
      ),
    );
  }
}
