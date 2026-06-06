import 'dart:async';

import 'package:flutter/material.dart';

import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../providers/app_state_provider.dart';
import '../services/audio_service.dart';
import '../services/background_audio_service.dart';
import '../services/streaming_service.dart';
import '../services/bluetooth_service.dart';
import '../services/sync_service.dart';
import '../models/audio_stream.dart';
import '../models/connected_device.dart';
import '../widgets/device_list_widget.dart';
import '../widgets/audio_source_selector.dart';
import '../widgets/audio_waveform_widget.dart';
import '../utils/local_ip.dart' as local_ip;
import 'recording_screen.dart';
import 'dj_screen.dart';

class HostScreen extends StatefulWidget {
  const HostScreen({super.key});

  @override
  State<HostScreen> createState() => _HostScreenState();
}

class _HostScreenState extends State<HostScreen> {
  late AppStateProvider _appState;
  late AudioService _audioService;
  late StreamingService _streamingService;
  late BluetoothService _bluetoothService;
  late SyncService _syncService;
  bool _isStreaming = false;
  bool _isPushToTalk = false;
  String _localIpAddress = 'Detecting...';
  final List<StreamSubscription<dynamic>> _subscriptions = [];

  @override
  void initState() {
    super.initState();
    _appState = context.read<AppStateProvider>();
    _audioService = context.read<AudioService>();
    _streamingService = context.read<StreamingService>();
    _bluetoothService = context.read<BluetoothService>();
    _syncService = context.read<SyncService>();
    _setupListeners();
    _detectLocalIp();
  }

  void _setupListeners() {
    // Listen to device connections
    _subscriptions.add(
      _streamingService.deviceConnectedStream.listen((device) {
        _appState.addConnectedDevice(device);
        // Auto-start streaming when first client joins while hosting
        if (_appState.isHosting && !_isStreaming && mounted) {
          _startStreaming();
        }
      }),
    );

    _subscriptions.add(
      _streamingService.deviceDisconnectedStream.listen((deviceId) {
        _appState.removeConnectedDevice(deviceId);
      }),
    );

    // Listen to Bluetooth device connections
    _subscriptions.add(
      _bluetoothService.deviceConnectedStream.listen((device) {
        _appState.addConnectedDevice(device);
      }),
    );

    _subscriptions.add(
      _bluetoothService.deviceDisconnectedStream.listen((deviceId) {
        _appState.removeConnectedDevice(deviceId);
      }),
    );

    // Listen to audio data and stream to connected devices
    _subscriptions.add(
      _audioService.audioDataStream.listen((audioData) {
        if (_isStreaming && !_appState.isMuted) {
          _streamingService.broadcastAudioData(audioData);
        }
      }),
    );

    // Adaptive bitrate — restart recording at lower quality if network degrades
    _subscriptions.add(
      _syncService.syncStatsStream.listen((stats) async {
        if (!_isStreaming || !mounted) return;
        final optimalQuality = _syncService.getOptimalQuality('host');
        // Only adapt down — don't auto-upgrade to avoid oscillation
        if (_appState.audioQuality.index > optimalQuality.index) {
          debugPrint('Adaptive bitrate: dropping to ${optimalQuality.name}');
          _appState.setAudioQuality(optimalQuality);
          // Restart recording at the new quality level
          await _audioService.stopRecording();
          await _audioService.startRecording(
            source: _appState.selectedAudioSource,
            quality: optimalQuality,
          );
        }
      }),
    );
  }

  Future<void> _detectLocalIp() async {
    try {
      final ip = await local_ip.detectLocalIp();
      if (!mounted) return;
      if (ip.isNotEmpty) setState(() => _localIpAddress = ip);
    } catch (e) {
      debugPrint('Error detecting local IP: $e');
    }
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppStateProvider>(
      builder: (context, appState, child) {
        return Padding(
          padding: const EdgeInsets.all(16.0),
          child: ListView(
            children: [
              // Host status card
              _buildHostStatusCard(appState),

              const SizedBox(height: 16),

              // Audio source selection
              const AudioSourceSelector(),

              const SizedBox(height: 16),

              // Streaming controls
              _buildStreamingControls(appState),

              const SizedBox(height: 16),

              // Quick-access: recording + DJ deck
              _buildQuickLaunchRow(context),

              const SizedBox(height: 16),

              // Broadcast rooms
              _buildRoomsCard(),

              const SizedBox(height: 16),

              // Connected devices
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Connected Devices (${appState.connectedDeviceCount})',
                        style:
                            Theme.of(context).textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                      ),
                      Row(
                        children: [
                          IconButton(
                            icon: Icon(MdiIcons.bluetooth),
                            onPressed: _scanForBluetoothDevices,
                            tooltip: 'Scan for Bluetooth devices',
                          ),
                          IconButton(
                            icon: Icon(MdiIcons.refresh),
                            onPressed: _refreshDevices,
                            tooltip: 'Refresh devices',
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 320,
                    child: DeviceListWidget(
                      devices: appState.connectedDevices,
                      isHost: true,
                      onDeviceDisconnect: _disconnectDevice,
                      onVolumeChanged: (deviceId, volume) => _streamingService
                          .sendVolumeToClient(deviceId, volume),
                      getClientStats: (deviceId) =>
                          _streamingService.getClientStats(deviceId),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildQuickLaunchRow(BuildContext context) {
    final streaming = context.read<StreamingService>();
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const RecordingScreen()),
            ),
            icon: streaming.isMultiStemRecording
                ? const Icon(Icons.fiber_manual_record,
                    color: Colors.red, size: 18)
                : const Icon(Icons.radio_button_unchecked, size: 18),
            label:
                Text(streaming.isMultiStemRecording ? 'Recording…' : 'Record'),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const DjScreen()),
            ),
            icon: const Icon(Icons.queue_music, size: 18),
            label: const Text('DJ Deck'),
          ),
        ),
      ],
    );
  }

  Widget _buildHostStatusCard(AppStateProvider appState) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              gradient: appState.isHosting
                  ? LinearGradient(
                      colors: [
                        Theme.of(context).colorScheme.primary,
                        Theme.of(context).colorScheme.secondary,
                      ],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    )
                  : null,
              color: appState.isHosting
                  ? null
                  : Theme.of(context).colorScheme.surfaceContainerHighest,
            ),
            child: Row(
              children: [
                Icon(
                  appState.isHosting
                      ? MdiIcons.broadcast
                      : MdiIcons.broadcastOff,
                  color: appState.isHosting
                      ? Theme.of(context).colorScheme.onPrimary
                      : Theme.of(context).colorScheme.onSurfaceVariant,
                  size: 32,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        appState.isHosting ? 'Broadcasting' : 'Ready to Host',
                        style:
                            Theme.of(context).textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: appState.isHosting
                                      ? Theme.of(context).colorScheme.onPrimary
                                      : Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant,
                                ),
                      ),
                      if (appState.isHosting)
                        Text(
                          'Port ${appState.port} · ${appState.connectedDeviceCount} device(s) · ${appState.audioQuality.displayName}',
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onPrimary
                                        .withValues(alpha: 0.8),
                                  ),
                        )
                      else
                        Text(
                          'Tap "Start Hosting" to begin',
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                        ),
                      if (appState.isHosting &&
                          _streamingService.isPinProtected)
                        Text(
                          'PIN protected',
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onPrimary
                                        .withValues(alpha: 0.8),
                                  ),
                        ),
                      if (_streamingService.encryptionEnabled)
                        Text(
                          'AES-128 encrypted',
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onPrimary
                                        .withValues(alpha: 0.8),
                                  ),
                        ),
                      if (appState.isHosting) ...[
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Icon(MdiIcons.ipNetwork,
                                size: 16,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onPrimary
                                    .withValues(alpha: 0.8)),
                            const SizedBox(width: 6),
                            Text(
                              'IP: $_localIpAddress',
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onPrimary
                                        .withValues(alpha: 0.9),
                                    fontFamily: 'monospace',
                                  ),
                            ),
                            const SizedBox(width: 8),
                            InkWell(
                              onTap: () {
                                Clipboard.setData(
                                    ClipboardData(text: _localIpAddress));
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('IP address copied'),
                                    duration: Duration(seconds: 1),
                                    behavior: SnackBarBehavior.floating,
                                  ),
                                );
                              },
                              child: Icon(MdiIcons.contentCopy,
                                  size: 16,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onPrimary
                                      .withValues(alpha: 0.8)),
                            ),
                            const SizedBox(width: 8),
                            InkWell(
                              onTap: () => _showQrDialog(appState),
                              child: Icon(MdiIcons.qrcode,
                                  size: 16,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onPrimary
                                      .withValues(alpha: 0.8)),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Icon(MdiIcons.web,
                                size: 16,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onPrimary
                                    .withValues(alpha: 0.8)),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                'Web: http://$_localIpAddress:${appState.port}/client',
                                style: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onPrimary
                                          .withValues(alpha: 0.9),
                                      fontFamily: 'monospace',
                                    ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 4),
                            InkWell(
                              onTap: () {
                                final url =
                                    'http://$_localIpAddress:${appState.port}/client';
                                Clipboard.setData(ClipboardData(text: url));
                                ScaffoldMessenger.of(context)
                                    .showSnackBar(const SnackBar(
                                  content: Text('Web client URL copied'),
                                  duration: Duration(seconds: 1),
                                  behavior: SnackBarBehavior.floating,
                                ));
                              },
                              child: Icon(MdiIcons.contentCopy,
                                  size: 16,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onPrimary
                                      .withValues(alpha: 0.8)),
                            ),
                            const SizedBox(width: 4),
                            InkWell(
                              onTap: () {
                                final url =
                                    'http://$_localIpAddress:${appState.port}/client';
                                showDialog(
                                  context: context,
                                  builder: (_) => AlertDialog(
                                    title: const Text('Web Client QR'),
                                    content: QrImageView(
                                        data: url,
                                        version: QrVersions.auto,
                                        size: 200),
                                    actions: [
                                      TextButton(
                                          onPressed: () =>
                                              Navigator.pop(context),
                                          child: const Text('Close'))
                                    ],
                                  ),
                                );
                              },
                              child: Icon(MdiIcons.qrcode,
                                  size: 16,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onPrimary
                                      .withValues(alpha: 0.8)),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _showQrDialog(AppStateProvider appState) {
    final qrData = 'audiosplitter://$_localIpAddress:${appState.port}';
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(MdiIcons.qrcode),
            const SizedBox(width: 8),
            const Text('Scan to Connect'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            QrImageView(
              data: qrData,
              version: QrVersions.auto,
              size: 220,
            ),
            const SizedBox(height: 12),
            Text(
              '$_localIpAddress:${appState.port}',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 4),
            Text(
              'Point the client camera at this QR code',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _buildStreamingControls(AppStateProvider appState) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Audio Streaming',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: appState.canStartStreaming
                        ? (_isStreaming ? _stopStreaming : _startStreaming)
                        : null,
                    icon: Icon(_isStreaming ? MdiIcons.stop : MdiIcons.play),
                    label: Text(
                        _isStreaming ? 'Stop Streaming' : 'Start Streaming'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _isStreaming
                          ? Theme.of(context).colorScheme.error
                          : Theme.of(context).colorScheme.primary,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  onPressed: appState.isMuted ? _unmute : _mute,
                  icon: Icon(appState.isMuted
                      ? MdiIcons.volumeOff
                      : MdiIcons.volumeHigh),
                  tooltip: appState.isMuted ? 'Unmute' : 'Mute',
                ),
                const SizedBox(width: 8),
                IconButton(
                  onPressed: () {
                    final enabling = !_isPushToTalk;
                    setState(() => _isPushToTalk = enabling);
                    if (enabling && _isStreaming) {
                      _appState.setMuted(
                          true); // immediately mute when PTT activates
                    } else if (!enabling) {
                      _appState.setMuted(false); // unmute when PTT deactivated
                    }
                    _showSnackBar(enabling
                        ? 'Push-to-Talk enabled — hold mic to talk'
                        : 'Push-to-Talk disabled');
                  },
                  icon: Icon(_isPushToTalk
                      ? MdiIcons.microphoneSettings
                      : MdiIcons.microphoneOutline),
                  tooltip: _isPushToTalk
                      ? 'PTT: ON (hold to talk)'
                      : 'Enable Push-to-Talk',
                  color: _isPushToTalk
                      ? Theme.of(context).colorScheme.primary
                      : null,
                ),
              ],
            ),
            if (_isPushToTalk && _isStreaming) ...[
              const SizedBox(height: 12),
              GestureDetector(
                onTapDown: (_) {
                  setState(() {});
                  // Un-mute for PTT
                  _appState.setMuted(false);
                },
                onTapUp: (_) {
                  setState(() {});
                  _appState.setMuted(true);
                },
                onTapCancel: () {
                  setState(() {});
                  _appState.setMuted(true);
                },
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 20),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                        color: Theme.of(context).colorScheme.primary, width: 2),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(MdiIcons.microphone,
                          size: 36,
                          color:
                              Theme.of(context).colorScheme.onPrimaryContainer),
                      const SizedBox(height: 4),
                      Text(
                        'Hold to Talk',
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onPrimaryContainer,
                            ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            if (_isStreaming) ...[
              const SizedBox(height: 12),
              AudioWaveformWidget(
                volumeStream: _audioService.volumeLevelStream,
                isActive: _isStreaming,
              ),
            ],
            if (!appState.hasClientsForStreaming &&
                appState.isHosting &&
                _isStreaming) ...[
              const SizedBox(height: 8),
              Text(
                'Streaming — waiting for devices to connect',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.primary,
                  fontSize: 12,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _startStreaming() async {
    final appState = _appState;

    // Create audio stream
    final audioStream = AudioStream(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: 'Live Audio Stream',
      source: appState.selectedAudioSource,
      quality: appState.audioQuality,
      isActive: true,
      connectedDeviceIds: appState.connectedDevices
          .where((d) => d.isConnected)
          .map((d) => d.id)
          .toList(),
    );

    appState.addAudioStream(audioStream);
    appState.setActiveStream(audioStream);

    // Start audio recording
    final success = await _audioService.startRecording(
      source: audioStream.source,
      quality: audioStream.quality,
    );

    if (!mounted) {
      return;
    }

    if (success) {
      setState(() {
        _isStreaming = true;
      });
      BackgroundAudioService().setPlayingState(
        playing: true,
        title: 'Broadcasting · $_localIpAddress',
      );
      BackgroundAudioService().setMediaButtonCallbacks(
        onPause: _mute,
        onStop: _stopStreaming,
      );
      _showSnackBar('Started streaming audio');
    } else {
      _showSnackBar('Failed to start audio streaming', isError: true);
    }
  }

  Future<void> _stopStreaming() async {
    await _audioService.stopRecording();

    if (!mounted) {
      return;
    }

    final appState = _appState;
    if (appState.activeStream != null) {
      appState.updateStreamActivity(appState.activeStream!.id, false);
      appState.setActiveStream(null);
    }

    setState(() {
      _isStreaming = false;
    });
    BackgroundAudioService().setPlayingState(playing: false);
    BackgroundAudioService().clearMediaButtonCallbacks();
    _showSnackBar('Stopped streaming audio');
  }

  void _mute() {
    context.read<AppStateProvider>().setMuted(true);
  }

  void _unmute() {
    context.read<AppStateProvider>().setMuted(false);
  }

  Future<void> _scanForBluetoothDevices() async {
    _showSnackBar('Scanning for Bluetooth devices...');
    await _bluetoothService.startScanning();

    if (!mounted) {
      return;
    }

    // Show discovered devices in a dialog
    _showBluetoothDevicesDialog();
  }

  void _showBluetoothDevicesDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Available Bluetooth Devices'),
        content: StreamBuilder<List<ConnectedDevice>>(
          stream: _bluetoothService.devicesStream,
          builder: (context, snapshot) {
            if (!snapshot.hasData || snapshot.data!.isEmpty) {
              return const SizedBox(
                height: 100,
                child: Center(
                  child: Text('No Bluetooth audio devices found'),
                ),
              );
            }

            return SizedBox(
              width: double.maxFinite,
              height: 300,
              child: ListView.builder(
                itemCount: snapshot.data!.length,
                itemBuilder: (context, index) {
                  final device = snapshot.data![index];
                  return ListTile(
                    leading: Icon(MdiIcons.bluetooth),
                    title: Text(device.name),
                    subtitle: Text(device.type.displayName),
                    trailing: ElevatedButton(
                      onPressed: () => _connectBluetoothDevice(device.id),
                      child: const Text('Connect'),
                    ),
                  );
                },
              ),
            );
          },
        ),
        actions: [
          TextButton(
            onPressed: () {
              _bluetoothService.stopScanning();
              Navigator.of(context).pop();
            },
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _connectBluetoothDevice(String deviceId) async {
    Navigator.of(context).pop(); // Close dialog

    _showSnackBar('Connecting to Bluetooth device...');
    final success = await _bluetoothService.connectToDevice(deviceId);

    if (!mounted) {
      return;
    }

    if (success) {
      _showSnackBar('Bluetooth device connected successfully');
    } else {
      _showSnackBar('Failed to connect to Bluetooth device', isError: true);
    }
  }

  Future<void> _refreshDevices() async {
    // Refresh connected devices list
    for (final device in _appState.connectedDevices) {
      _appState.updateDeviceConnection(device.id, device.isConnected);
    }

    _showSnackBar('Devices refreshed');
  }

  Future<void> _disconnectDevice(String deviceId) async {
    final device =
        _appState.connectedDevices.firstWhere((d) => d.id == deviceId);

    if (device.type == DeviceType.bluetoothHeadset ||
        device.type == DeviceType.bluetoothSpeaker) {
      await _bluetoothService.disconnectFromDevice(deviceId);
    }

    if (!mounted) {
      return;
    }

    _appState.removeConnectedDevice(deviceId);
    _showSnackBar('Device disconnected');
  }

  void _showAddRoomDialog() {
    final nameCtrl = TextEditingController(
        text: 'Room ${_streamingService.activeRooms.length + 2}');
    final portCtrl = TextEditingController(
        text: '${_appState.port + _streamingService.activeRooms.length + 1}');
    final pinCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add Broadcast Room'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(
                  labelText: 'Room Name', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: portCtrl,
              decoration: const InputDecoration(
                  labelText: 'Port', border: OutlineInputBorder()),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: pinCtrl,
              decoration: const InputDecoration(
                labelText: 'PIN (optional)',
                border: OutlineInputBorder(),
                hintText: 'Leave blank for open room',
              ),
              keyboardType: TextInputType.number,
              obscureText: true,
              maxLength: 8,
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              final name = nameCtrl.text.trim();
              final port = int.tryParse(portCtrl.text.trim());
              if (name.isEmpty || port == null || port < 1024 || port > 65534) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                  content: Text('Invalid room name or port'),
                  behavior: SnackBarBehavior.floating,
                ));
                return;
              }
              Navigator.pop(ctx);
              final pin =
                  pinCtrl.text.trim().isEmpty ? null : pinCtrl.text.trim();
              final id = 'room_${DateTime.now().millisecondsSinceEpoch}';
              final ok = await _streamingService.startRoom(id,
                  name: name, port: port, pin: pin);
              if (!ok && mounted) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text('Failed to start room on port $port'),
                  backgroundColor: Theme.of(context).colorScheme.error,
                  behavior: SnackBarBehavior.floating,
                ));
              }
            },
            child: const Text('Create Room'),
          ),
        ],
      ),
    );
  }

  Widget _buildRoomsCard() {
    final rooms = _streamingService.activeRooms;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  'Broadcast Rooms',
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                IconButton.filled(
                  onPressed: _showAddRoomDialog,
                  icon: const Icon(Icons.add),
                  tooltip: 'Add room',
                  iconSize: 18,
                ),
              ],
            ),
            if (rooms.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'No extra rooms. Add a room to broadcast on multiple ports simultaneously.',
                  style: TextStyle(color: Colors.grey, fontSize: 12),
                ),
              )
            else
              ...rooms.entries.map((e) {
                final room = e.value;
                return ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.broadcast_on_home, size: 20),
                  title: Text(room.name),
                  subtitle: Text(
                      'Port ${room.port} · ${room.clientCount} client${room.clientCount == 1 ? '' : 's'}'),
                  trailing: IconButton(
                    icon: const Icon(Icons.stop_circle_outlined,
                        color: Colors.red, size: 20),
                    tooltip: 'Stop room',
                    onPressed: () => _streamingService.stopRoom(e.key),
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }

  void _showSnackBar(String message, {bool isError = false}) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError
            ? Theme.of(context).colorScheme.error
            : Theme.of(context).colorScheme.primary,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}
