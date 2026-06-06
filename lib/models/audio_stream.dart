class AudioStream {
  final String id;
  final String name;
  final AudioSource source;
  final AudioQuality quality;
  final bool isActive;
  final List<String> connectedDeviceIds;
  final DateTime createdAt;

  AudioStream({
    required this.id,
    required this.name,
    required this.source,
    this.quality = AudioQuality.high,
    this.isActive = false,
    this.connectedDeviceIds = const [],
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  AudioStream copyWith({
    String? id,
    String? name,
    AudioSource? source,
    AudioQuality? quality,
    bool? isActive,
    List<String>? connectedDeviceIds,
    DateTime? createdAt,
  }) {
    return AudioStream(
      id: id ?? this.id,
      name: name ?? this.name,
      source: source ?? this.source,
      quality: quality ?? this.quality,
      isActive: isActive ?? this.isActive,
      connectedDeviceIds: connectedDeviceIds ?? this.connectedDeviceIds,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'source': source.toString().split('.').last,
      'quality': quality.toString().split('.').last,
      'isActive': isActive,
      'connectedDeviceIds': connectedDeviceIds,
      'createdAt': createdAt.toIso8601String(),
    };
  }

  factory AudioStream.fromJson(Map<String, dynamic> json) {
    return AudioStream(
      id: json['id'],
      name: json['name'],
      source: AudioSource.values.firstWhere(
        (e) => e.toString().split('.').last == json['source'],
      ),
      quality: AudioQuality.values.firstWhere(
        (e) => e.toString().split('.').last == json['quality'],
      ),
      isActive: json['isActive'] ?? false,
      connectedDeviceIds: List<String>.from(json['connectedDeviceIds'] ?? []),
      createdAt: DateTime.parse(json['createdAt']),
    );
  }
}

enum AudioSource {
  microphone,
  systemAudio,
  musicPlayer,
  mediaFile,
  streaming,
}

enum AudioQuality {
  low, // 64 kbps
  medium, // 128 kbps
  high, // 256 kbps
  ultra, // 320 kbps
}

extension AudioSourceExtension on AudioSource {
  String get displayName {
    switch (this) {
      case AudioSource.microphone:
        return 'Microphone';
      case AudioSource.systemAudio:
        return 'System Audio';
      case AudioSource.musicPlayer:
        return 'Music Player';
      case AudioSource.mediaFile:
        return 'Media File';
      case AudioSource.streaming:
        return 'Streaming';
    }
  }
}

extension AudioQualityExtension on AudioQuality {
  String get displayName {
    switch (this) {
      case AudioQuality.low:
        return 'Low (64 kbps)';
      case AudioQuality.medium:
        return 'Medium (128 kbps)';
      case AudioQuality.high:
        return 'High (256 kbps)';
      case AudioQuality.ultra:
        return 'Ultra (320 kbps)';
    }
  }

  int get bitrate {
    switch (this) {
      case AudioQuality.low:
        return 64000;
      case AudioQuality.medium:
        return 128000;
      case AudioQuality.high:
        return 256000;
      case AudioQuality.ultra:
        return 320000;
    }
  }
}
