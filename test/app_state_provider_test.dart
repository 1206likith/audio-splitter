import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:audio_splitter_app/providers/app_state_provider.dart';
import 'package:audio_splitter_app/models/audio_stream.dart';
import 'package:audio_splitter_app/models/connected_device.dart';

void main() {
  // SharedPreferences must be mocked before AppStateProvider is constructed
  // because the constructor calls _loadSettings() which calls
  // SharedPreferences.getInstance().
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
  });

  group('AppStateProvider', () {
    late AppStateProvider provider;

    setUp(() {
      // Each test gets a fresh provider backed by an empty SharedPreferences
      // mock, so no persisted values interfere with assertions.
      SharedPreferences.setMockInitialValues({});
      provider = AppStateProvider(); // No SettingsService → uses defaults
    });

    tearDown(() {
      provider.dispose();
    });

    test('starts in host mode', () {
      expect(provider.mode, AppMode.host);
    });

    test('setMode changes mode', () {
      provider.setMode(AppMode.client);
      expect(provider.mode, AppMode.client);
    });

    test('setMode resets connection state', () {
      provider.setConnectedToHost(true,
          hostAddress: '192.168.1.1', hostName: 'Host');
      provider.setMode(AppMode.client);
      expect(provider.isConnectedToHost, isFalse);
      expect(provider.hostAddress, isNull);
    });

    test('canStartStreaming requires hosting to be active', () {
      // Not hosting yet — host mode but isHosting=false
      expect(provider.canStartStreaming, isFalse);
      provider.setHosting(true);
      expect(provider.canStartStreaming, isTrue);
    });

    test('setHosting true does not clear devices', () {
      provider.addConnectedDevice(ConnectedDevice(
        id: '1',
        name: 'Test',
        type: DeviceType.phone,
        ipAddress: '1.2.3.4',
        isConnected: true,
      ));
      provider.setHosting(true);
      expect(provider.connectedDevices.length, 1);
    });

    test('setHosting false clears connected devices', () {
      provider.addConnectedDevice(ConnectedDevice(
        id: '1',
        name: 'Test',
        type: DeviceType.phone,
        ipAddress: '1.2.3.4',
        isConnected: true,
      ));
      provider.setHosting(false);
      expect(provider.connectedDevices, isEmpty);
    });

    test('addConnectedDevice adds new device', () {
      final device = ConnectedDevice(
        id: 'abc',
        name: 'Phone',
        type: DeviceType.phone,
        ipAddress: '1.2.3.4',
        isConnected: true,
      );
      provider.addConnectedDevice(device);
      expect(provider.connectedDevices.length, 1);
    });

    test('addConnectedDevice replaces existing device with same id', () {
      final device1 = ConnectedDevice(
          id: 'abc',
          name: 'Old',
          type: DeviceType.phone,
          ipAddress: '1.1.1.1',
          isConnected: false);
      final device2 = ConnectedDevice(
          id: 'abc',
          name: 'New',
          type: DeviceType.phone,
          ipAddress: '1.1.1.1',
          isConnected: true);
      provider.addConnectedDevice(device1);
      provider.addConnectedDevice(device2);
      expect(provider.connectedDevices.length, 1);
      expect(provider.connectedDevices.first.name, 'New');
    });

    test('removeConnectedDevice removes by id', () {
      provider.addConnectedDevice(ConnectedDevice(
        id: 'abc',
        name: 'Phone',
        type: DeviceType.phone,
        ipAddress: '1.2.3.4',
        isConnected: true,
      ));
      provider.removeConnectedDevice('abc');
      expect(provider.connectedDevices, isEmpty);
    });

    test('connectedDeviceCount counts only connected devices', () {
      provider.addConnectedDevice(ConnectedDevice(
          id: '1',
          name: 'A',
          type: DeviceType.phone,
          ipAddress: '1',
          isConnected: true));
      provider.addConnectedDevice(ConnectedDevice(
          id: '2',
          name: 'B',
          type: DeviceType.phone,
          ipAddress: '2',
          isConnected: false));
      expect(provider.connectedDeviceCount, 1);
    });

    test('setVolume clamps to 0.0-1.0', () {
      provider.setVolume(2.0);
      expect(provider.volume, 1.0);
      provider.setVolume(-1.0);
      expect(provider.volume, 0.0);
    });

    test('setConnectedToHost sets connectionAttempted', () {
      expect(provider.connectionAttempted, isFalse);
      provider.setConnectedToHost(true,
          hostAddress: '1.2.3.4', hostName: 'Host');
      expect(provider.connectionAttempted, isTrue);
    });

    test('updateNetworkMetrics updates connectionQuality', () {
      // Excellent: latency < 30 AND jitter < 5
      provider.updateNetworkMetrics(latencyMs: 20, jitter: 2.0);
      expect(provider.connectionQuality, 'Excellent');

      // Good: latency < 60 AND jitter < 10 (but not Excellent)
      provider.updateNetworkMetrics(latencyMs: 50, jitter: 8.0);
      expect(provider.connectionQuality, 'Good');

      // Fair: latency < 100 AND jitter < 20 (but not Good)
      provider.updateNetworkMetrics(latencyMs: 80, jitter: 15.0);
      expect(provider.connectionQuality, 'Fair');

      // Poor: everything else
      provider.updateNetworkMetrics(latencyMs: 200, jitter: 50.0);
      expect(provider.connectionQuality, 'Poor');
    });

    test('setAudioQuality updates quality', () {
      provider.setAudioQuality(AudioQuality.low);
      expect(provider.audioQuality, AudioQuality.low);
    });

    test('setPort updates port', () {
      provider.setPort(9090);
      expect(provider.port, 9090);
    });

    test('notifyListeners fires on state change', () {
      int notifyCount = 0;
      provider.addListener(() => notifyCount++);
      provider.setMode(AppMode.client);
      expect(notifyCount, greaterThan(0));
    });
  });
}
