import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/connected_device.dart';

class BluetoothService {
  static final BluetoothService _instance = BluetoothService._internal();
  factory BluetoothService() => _instance;
  BluetoothService._internal();

  // Stream controllers
  final StreamController<List<ConnectedDevice>> _devicesController =
      StreamController<List<ConnectedDevice>>.broadcast();
  Stream<List<ConnectedDevice>> get devicesStream => _devicesController.stream;

  final StreamController<ConnectedDevice> _deviceConnectedController =
      StreamController<ConnectedDevice>.broadcast();
  Stream<ConnectedDevice> get deviceConnectedStream =>
      _deviceConnectedController.stream;

  final StreamController<String> _deviceDisconnectedController =
      StreamController<String>.broadcast();
  Stream<String> get deviceDisconnectedStream =>
      _deviceDisconnectedController.stream;

  // Getters
  List<ConnectedDevice> get discoveredDevices => const [];
  List<ConnectedDevice> get connectedDevices => const [];
  bool get isScanning => false;
  bool get isInitialized => false;
  bool get isBluetoothAvailable => false;

  Future<bool> initialize() async {
    debugPrint('BluetoothService: not available on web');
    return false;
  }

  Future<bool> requestBluetoothPermissions() async => false;

  Future<void> startScanning(
      {Duration timeout = const Duration(seconds: 30)}) async {}

  Future<void> stopScanning() async {}

  Future<bool> connectToDevice(String deviceId) async => false;

  Future<bool> disconnectFromDevice(String deviceId) async => false;

  Future<void> disconnectAllDevices() async {}

  Future<List<ConnectedDevice>> getPairedDevices() async => [];

  Future<void> dispose() async {
    await _devicesController.close();
    await _deviceConnectedController.close();
    await _deviceDisconnectedController.close();
  }
}
