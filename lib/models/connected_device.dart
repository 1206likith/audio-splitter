class ConnectedDevice {
  final String id;
  final String name;
  final DeviceType type;
  final String ipAddress;
  final bool isConnected;
  final double latency;
  final DateTime connectedAt;

  ConnectedDevice({
    required this.id,
    required this.name,
    required this.type,
    required this.ipAddress,
    this.isConnected = false,
    this.latency = 0.0,
    DateTime? connectedAt,
  }) : connectedAt = connectedAt ?? DateTime.now();

  ConnectedDevice copyWith({
    String? id,
    String? name,
    DeviceType? type,
    String? ipAddress,
    bool? isConnected,
    double? latency,
    DateTime? connectedAt,
  }) {
    return ConnectedDevice(
      id: id ?? this.id,
      name: name ?? this.name,
      type: type ?? this.type,
      ipAddress: ipAddress ?? this.ipAddress,
      isConnected: isConnected ?? this.isConnected,
      latency: latency ?? this.latency,
      connectedAt: connectedAt ?? this.connectedAt,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'type': type.toString().split('.').last,
      'ipAddress': ipAddress,
      'isConnected': isConnected,
      'latency': latency,
      'connectedAt': connectedAt.toIso8601String(),
    };
  }

  factory ConnectedDevice.fromJson(Map<String, dynamic> json) {
    return ConnectedDevice(
      id: json['id'],
      name: json['name'],
      type: DeviceType.values.firstWhere(
        (e) => e.toString().split('.').last == json['type'],
      ),
      ipAddress: json['ipAddress'],
      isConnected: json['isConnected'] ?? false,
      latency: json['latency']?.toDouble() ?? 0.0,
      connectedAt: DateTime.parse(json['connectedAt']),
    );
  }
}

enum DeviceType {
  phone,
  tablet,
  computer,
  bluetoothHeadset,
  bluetoothSpeaker,
  smartWatch,
  other,
}

extension DeviceTypeExtension on DeviceType {
  String get displayName {
    switch (this) {
      case DeviceType.phone:
        return 'Phone';
      case DeviceType.tablet:
        return 'Tablet';
      case DeviceType.computer:
        return 'Computer';
      case DeviceType.bluetoothHeadset:
        return 'Bluetooth Headset';
      case DeviceType.bluetoothSpeaker:
        return 'Bluetooth Speaker';
      case DeviceType.smartWatch:
        return 'Smart Watch';
      case DeviceType.other:
        return 'Other Device';
    }
  }

  String get iconName {
    switch (this) {
      case DeviceType.phone:
        return 'phone';
      case DeviceType.tablet:
        return 'tablet';
      case DeviceType.computer:
        return 'laptop';
      case DeviceType.bluetoothHeadset:
        return 'headphones';
      case DeviceType.bluetoothSpeaker:
        return 'speaker';
      case DeviceType.smartWatch:
        return 'watch';
      case DeviceType.other:
        return 'device_unknown';
    }
  }
}
