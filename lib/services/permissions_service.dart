import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

class PermissionsService {
  static final PermissionsService _instance = PermissionsService._internal();
  factory PermissionsService() => _instance;
  PermissionsService._internal();

  Future<bool> ensureMicPermission() async {
    if (kIsWeb) return true;
    final p = defaultTargetPlatform;
    if (p != TargetPlatform.android &&
        p != TargetPlatform.iOS &&
        p != TargetPlatform.macOS &&
        p != TargetPlatform.windows) {
      return true;
    }
    final status = await Permission.microphone.status;
    if (status.isGranted) return true;
    final result = await Permission.microphone.request();
    return result.isGranted;
  }

  Future<bool> ensureBluetoothScanPermission() async {
    if (kIsWeb) return true;
    if (defaultTargetPlatform != TargetPlatform.android) return true;
    // On Android 12+, use runtime permissions
    final scan = await Permission.bluetoothScan.request();
    final connect = await Permission.bluetoothConnect.request();
    // Location may still be needed by some stacks
    final loc = await Permission.locationWhenInUse.request();
    return scan.isGranted && connect.isGranted && loc.isGranted;
  }
}
