import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'permissions_service.dart';
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

  // State
  final List<ConnectedDevice> _discoveredDevices = [];
  final Map<String, BluetoothDevice> _connectedDevices = {};
  final Map<String, BluetoothDevice> _scannedDevices = {};
  bool _isScanning = false;
  bool _isInitialized = false;

  // Getters
  List<ConnectedDevice> get discoveredDevices =>
      List.unmodifiable(_discoveredDevices);
  List<ConnectedDevice> get connectedDevices => _connectedDevices.values
      .map((device) => _bluetoothDeviceToConnectedDevice(device, true))
      .toList();
  bool get isScanning => _isScanning;
  bool get isInitialized => _isInitialized;
  bool get isBluetoothAvailable =>
      FlutterBluePlus.adapterStateNow == BluetoothAdapterState.on;

  Future<bool> initialize() async {
    if (_isInitialized) return true;

    try {
      // Check if Bluetooth is available
      if (!await FlutterBluePlus.isSupported) {
        debugPrint('Bluetooth not available on this device');
        return false;
      }

      // Listen to adapter state changes
      FlutterBluePlus.adapterState.listen((state) {
        debugPrint('Bluetooth adapter state: $state');
        if (state != BluetoothAdapterState.on) {
          _clearDevices();
        }
      });

      // Listen to scan results
      FlutterBluePlus.scanResults.listen((results) {
        _handleScanResults(results);
      });

      _isInitialized = true;
      return true;
    } catch (e) {
      debugPrint('Error initializing Bluetooth service: $e');
      return false;
    }
  }

  Future<bool> requestBluetoothPermissions() async {
    try {
      // Turn on Bluetooth if it's off
      if (FlutterBluePlus.adapterStateNow == BluetoothAdapterState.off) {
        await FlutterBluePlus.turnOn();
      }
      return true;
    } catch (e) {
      debugPrint('Error requesting Bluetooth permissions: $e');
      return false;
    }
  }

  Future<void> startScanning(
      {Duration timeout = const Duration(seconds: 30)}) async {
    if (_isScanning || !_isInitialized) return;

    try {
      // Ensure runtime permissions
      final ok = await PermissionsService().ensureBluetoothScanPermission();
      if (!ok) {
        debugPrint('Bluetooth permissions not granted');
        return;
      }
      // Clear previous results
      _discoveredDevices.clear();

      // Start scanning
      await FlutterBluePlus.startScan(
        timeout: timeout,
        androidUsesFineLocation: true,
      );

      _isScanning = true;
      debugPrint('Started Bluetooth scanning');

      // Auto-stop scanning after timeout
      Timer(timeout, () {
        if (_isScanning) {
          stopScanning();
        }
      });
    } catch (e) {
      debugPrint('Error starting Bluetooth scan: $e');
      _isScanning = false;
    }
  }

  Future<void> stopScanning() async {
    if (!_isScanning) return;

    try {
      await FlutterBluePlus.stopScan();
      _isScanning = false;
      debugPrint('Stopped Bluetooth scanning');
    } catch (e) {
      debugPrint('Error stopping Bluetooth scan: $e');
    }
  }

  void _handleScanResults(List<ScanResult> results) {
    _discoveredDevices.clear();

    for (final result in results) {
      final device = result.device;
      _scannedDevices[device.remoteId.toString()] = device;

      // Filter for audio devices (headphones, speakers, etc.)
      if (_isAudioDevice(result)) {
        final connectedDevice =
            _bluetoothDeviceToConnectedDevice(device, false);
        _discoveredDevices.add(connectedDevice);
      }
    }

    _devicesController.add(List.unmodifiable(_discoveredDevices));
  }

  bool _isAudioDevice(ScanResult result) {
    // Check device name for audio-related keywords
    final deviceName = result.device.platformName.toLowerCase();
    final audioKeywords = [
      'headphone',
      'headset',
      'earphone',
      'earbud',
      'speaker',
      'soundbar',
      'audio',
      'beats',
      'sony',
      'bose',
      'sennheiser',
      'jbl',
      'airpods'
    ];

    for (final keyword in audioKeywords) {
      if (deviceName.contains(keyword)) {
        return true;
      }
    }

    // Check service UUIDs for audio services
    final serviceUuids = result.advertisementData.serviceUuids
        .map((uuid) => uuid.toString().toLowerCase())
        .toSet();
    const audioServiceUuids = {
      '0000110b-0000-1000-8000-00805f9b34fb', // Audio Sink
      '0000110a-0000-1000-8000-00805f9b34fb', // Audio Source
      '0000111e-0000-1000-8000-00805f9b34fb', // Hands-Free
      '00001108-0000-1000-8000-00805f9b34fb', // Headset
    };

    for (final uuid in serviceUuids) {
      if (audioServiceUuids.contains(uuid)) {
        return true;
      }
    }

    return false;
  }

  Future<bool> connectToDevice(String deviceId) async {
    try {
      // Ensure runtime permissions
      final ok = await PermissionsService().ensureBluetoothScanPermission();
      if (!ok) {
        debugPrint('Bluetooth permissions not granted');
        return false;
      }
      final device = _discoveredDevices.firstWhere((d) => d.id == deviceId,
          orElse: () => ConnectedDevice(
                id: deviceId,
                name: 'Bluetooth Device',
                type: DeviceType.other,
                ipAddress: 'bluetooth',
              ));
      final bluetoothDevice = FlutterBluePlus.connectedDevices.firstWhere(
        (d) => d.remoteId.toString() == deviceId,
        orElse: () =>
            _scannedDevices[deviceId] ??
            (throw StateError('Unknown Bluetooth device: $deviceId')),
      );

      // Connect to the device
      await bluetoothDevice.connect(timeout: const Duration(seconds: 15));

      // Listen for disconnection
      bluetoothDevice.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          _connectedDevices.remove(deviceId);
          _deviceDisconnectedController.add(deviceId);
        }
      });

      _connectedDevices[deviceId] = bluetoothDevice;

      final connectedDevice = device.copyWith(isConnected: true);
      _deviceConnectedController.add(connectedDevice);

      debugPrint('Connected to Bluetooth device: ${device.name}');
      return true;
    } catch (e) {
      debugPrint('Error connecting to Bluetooth device: $e');
      return false;
    }
  }

  Future<bool> disconnectFromDevice(String deviceId) async {
    try {
      final bluetoothDevice = _connectedDevices[deviceId];
      if (bluetoothDevice != null) {
        await bluetoothDevice.disconnect();
        _connectedDevices.remove(deviceId);
        _deviceDisconnectedController.add(deviceId);
        debugPrint('Disconnected from Bluetooth device');
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('Error disconnecting from Bluetooth device: $e');
      return false;
    }
  }

  Future<void> disconnectAllDevices() async {
    final deviceIds = _connectedDevices.keys.toList();
    for (final deviceId in deviceIds) {
      await disconnectFromDevice(deviceId);
    }
  }

  Future<List<ConnectedDevice>> getPairedDevices() async {
    try {
      final connectedDevices = FlutterBluePlus.connectedDevices;
      final pairedDevices = <ConnectedDevice>[];

      for (final device in connectedDevices) {
        if (_isAudioDeviceByName(device.platformName)) {
          final connectedDevice =
              _bluetoothDeviceToConnectedDevice(device, true);
          pairedDevices.add(connectedDevice);
        }
      }

      return pairedDevices;
    } catch (e) {
      debugPrint('Error getting paired devices: $e');
      return [];
    }
  }

  bool _isAudioDeviceByName(String deviceName) {
    final name = deviceName.toLowerCase();
    final audioKeywords = [
      'headphone',
      'headset',
      'earphone',
      'earbud',
      'speaker',
      'soundbar',
      'audio',
      'beats',
      'sony',
      'bose',
      'sennheiser',
      'jbl',
      'airpods'
    ];

    return audioKeywords.any((keyword) => name.contains(keyword));
  }

  ConnectedDevice _bluetoothDeviceToConnectedDevice(
      BluetoothDevice device, bool isConnected) {
    final deviceName =
        device.platformName.isNotEmpty ? device.platformName : 'Unknown Device';

    return ConnectedDevice(
      id: device.remoteId.toString(),
      name: deviceName,
      type: _getDeviceTypeFromName(deviceName),
      ipAddress: 'bluetooth',
      isConnected: isConnected,
    );
  }

  DeviceType _getDeviceTypeFromName(String deviceName) {
    final name = deviceName.toLowerCase();

    if (name.contains('headphone') ||
        name.contains('headset') ||
        name.contains('earphone') ||
        name.contains('earbud') ||
        name.contains('airpods')) {
      return DeviceType.bluetoothHeadset;
    } else if (name.contains('speaker') || name.contains('soundbar')) {
      return DeviceType.bluetoothSpeaker;
    } else if (name.contains('watch')) {
      return DeviceType.smartWatch;
    }

    return DeviceType.other;
  }

  void _clearDevices() {
    _discoveredDevices.clear();
    _connectedDevices.clear();
    _devicesController.add([]);
  }

  Future<void> dispose() async {
    await stopScanning();
    await disconnectAllDevices();

    await _devicesController.close();
    await _deviceConnectedController.close();
    await _deviceDisconnectedController.close();

    _isInitialized = false;
  }
}
