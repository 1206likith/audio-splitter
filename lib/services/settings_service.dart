import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SettingsService {
  static const _keyPort = 'audio_splitter_port';
  static const _keyQuality = 'audio_splitter_quality';
  static const _keyRecentHosts = 'audio_splitter_recent_hosts';

  Future<int> loadPort({int defaultPort = 8080}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getInt(_keyPort) ?? defaultPort;
    } catch (e) {
      debugPrint('Error loading port: $e');
      return defaultPort;
    }
  }

  Future<void> savePort(int port) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_keyPort, port);
    } catch (e) {
      debugPrint('Error saving port: $e');
    }
  }

  Future<String> loadQuality({String defaultQuality = 'high'}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_keyQuality) ?? defaultQuality;
    } catch (e) {
      debugPrint('Error loading quality: $e');
      return defaultQuality;
    }
  }

  Future<void> saveQuality(String quality) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyQuality, quality);
    } catch (e) {
      debugPrint('Error saving quality: $e');
    }
  }

  Future<List<Map<String, dynamic>>> loadRecentHosts() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_keyRecentHosts) ?? [];
      return raw
          .map((s) {
            try {
              return Map<String, dynamic>.from(jsonDecode(s) as Map);
            } catch (_) {
              return <String, dynamic>{};
            }
          })
          .where((m) => m.isNotEmpty)
          .toList();
    } catch (e) {
      debugPrint('Error loading recent hosts: $e');
      return [];
    }
  }

  Future<void> saveRecentHost(String host, int port,
      {String name = 'Audio Splitter Host'}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final existing = await loadRecentHosts();
      existing.removeWhere((h) => h['host'] == host && h['port'] == port);
      existing.insert(0, {'host': host, 'port': port, 'name': name});
      final trimmed = existing.take(5).toList();
      await prefs.setStringList(
          _keyRecentHosts, trimmed.map((m) => jsonEncode(m)).toList());
    } catch (e) {
      debugPrint('Error saving recent host: $e');
    }
  }

  Future<void> removeRecentHost(String host, int port) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final existing = await loadRecentHosts();
      existing.removeWhere((h) => h['host'] == host && h['port'] == port);
      await prefs.setStringList(
          _keyRecentHosts, existing.map((m) => jsonEncode(m)).toList());
    } catch (e) {
      debugPrint('Error removing recent host: $e');
    }
  }

  static const _keyHostPin = 'audio_splitter_host_pin';

  Future<String?> loadHostPin() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_keyHostPin);
    } catch (e) {
      debugPrint('Error loading host PIN: $e');
      return null;
    }
  }

  Future<void> saveHostPin(String? pin) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (pin == null || pin.isEmpty) {
        await prefs.remove(_keyHostPin);
      } else {
        await prefs.setString(_keyHostPin, pin);
      }
    } catch (e) {
      debugPrint('Error saving host PIN: $e');
    }
  }
}
