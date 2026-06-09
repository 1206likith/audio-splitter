import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:audio_splitter_app/services/settings_service.dart';

void main() {
  setUpAll(() => TestWidgetsFlutterBinding.ensureInitialized());

  setUp(() => SharedPreferences.setMockInitialValues({}));

  late SettingsService svc;
  setUp(() => svc = SettingsService());

  group('port', () {
    test('returns default when nothing saved', () async {
      expect(await svc.loadPort(), 8080);
      expect(await svc.loadPort(defaultPort: 9090), 9090);
    });

    test('persists and loads saved port', () async {
      await svc.savePort(1234);
      expect(await svc.loadPort(), 1234);
    });
  });

  group('quality', () {
    test('returns default when nothing saved', () async {
      expect(await svc.loadQuality(), 'high');
      expect(await svc.loadQuality(defaultQuality: 'low'), 'low');
    });

    test('persists and loads saved quality', () async {
      await svc.saveQuality('medium');
      expect(await svc.loadQuality(), 'medium');
    });
  });

  group('recent hosts', () {
    test('empty list when nothing saved', () async {
      expect(await svc.loadRecentHosts(), isEmpty);
    });

    test('saves and loads a single host', () async {
      await svc.saveRecentHost('192.168.1.1', 8080, name: 'Living Room');
      final hosts = await svc.loadRecentHosts();
      expect(hosts, hasLength(1));
      expect(hosts[0]['host'], '192.168.1.1');
      expect(hosts[0]['port'], 8080);
      expect(hosts[0]['name'], 'Living Room');
    });

    test('most-recently-added host appears first', () async {
      await svc.saveRecentHost('10.0.0.1', 8080);
      await svc.saveRecentHost('10.0.0.2', 8080);
      final hosts = await svc.loadRecentHosts();
      expect(hosts[0]['host'], '10.0.0.2');
      expect(hosts[1]['host'], '10.0.0.1');
    });

    test('re-adding same host deduplicates and moves to front', () async {
      await svc.saveRecentHost('10.0.0.1', 8080);
      await svc.saveRecentHost('10.0.0.2', 8080);
      await svc.saveRecentHost('10.0.0.1', 8080, name: 'Updated');
      final hosts = await svc.loadRecentHosts();
      expect(hosts, hasLength(2));
      expect(hosts[0]['host'], '10.0.0.1');
      expect(hosts[0]['name'], 'Updated');
    });

    test('list is capped at 5 entries', () async {
      for (var i = 1; i <= 7; i++) {
        await svc.saveRecentHost('10.0.0.$i', 8080);
      }
      expect(await svc.loadRecentHosts(), hasLength(5));
    });

    test('removes a specific host', () async {
      await svc.saveRecentHost('10.0.0.1', 8080);
      await svc.saveRecentHost('10.0.0.2', 8080);
      await svc.removeRecentHost('10.0.0.1', 8080);
      final hosts = await svc.loadRecentHosts();
      expect(hosts, hasLength(1));
      expect(hosts[0]['host'], '10.0.0.2');
    });

    test('remove non-existent host is a no-op', () async {
      await svc.saveRecentHost('10.0.0.1', 8080);
      await svc.removeRecentHost('99.99.99.99', 9999);
      expect(await svc.loadRecentHosts(), hasLength(1));
    });
  });

  group('host PIN', () {
    test('null when no PIN saved', () async {
      expect(await svc.loadHostPin(), isNull);
    });

    test('saves and loads PIN', () async {
      await svc.saveHostPin('1234');
      expect(await svc.loadHostPin(), '1234');
    });

    test('saveHostPin(null) removes PIN', () async {
      await svc.saveHostPin('9999');
      await svc.saveHostPin(null);
      expect(await svc.loadHostPin(), isNull);
    });

    test('saveHostPin empty string removes PIN', () async {
      await svc.saveHostPin('9999');
      await svc.saveHostPin('');
      expect(await svc.loadHostPin(), isNull);
    });
  });
}
