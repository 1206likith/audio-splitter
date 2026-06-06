import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../providers/app_state_provider.dart';
import '../services/audio_service.dart';
import '../services/streaming_service.dart';
import '../services/sync_service.dart';
import '../services/bluetooth_service.dart';
import '../services/settings_service.dart';
import '../widgets/device_list_widget.dart';
import '../widgets/audio_waveform_widget.dart';
import '../widgets/latency_graph_widget.dart';
import '../models/connected_device.dart';
import '../models/audio_stream.dart';
import '../services/recording_service.dart';
import '../services/background_audio_service.dart';
import 'package:share_plus/share_plus.dart';

class ClientScreen extends StatefulWidget {
  const ClientScreen({super.key});

  @override
  State<ClientScreen> createState() => _ClientScreenState();
}

class _ClientScreenState extends State<ClientScreen> {
  late AppStateProvider _appState;
  late AudioService _audioService;
  late StreamingService _streamingService;
  late BluetoothService _bluetoothService;
  late SyncService _syncService;
  late SettingsService _settingsService;
  bool _isReceivingAudio = false;
  bool _isRecording = false;
  String? _lastRecordingPath;
  bool _hasRequestedAudioConfig = false;
  bool _isScanning = false;
  final _manualIpController = TextEditingController();
  bool _manualDisconnect = false;
  int _reconnectCount = 0;
  int _audioSampleRate = 48000;
  int _audioChannels = 2;
  double get _signalStrength {
    if (_latency <= 0) return 0.0;
    if (_latency < 30) return 1.0;
    if (_latency < 60) return 0.8;
    if (_latency < 100) return 0.6;
    if (_latency < 150) return 0.4;
    return 0.2;
  }

  int _latency = 0;
  final List<Map<String, dynamic>> _discoveredHosts = [];
  List<Map<String, dynamic>> _recentHosts = [];
  String _selectedOutputId = 'speaker';
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  final StreamController<double> _receivedVolumeController =
      StreamController<double>.broadcast();

  // Connection quality computed getters
  String get _connectionQualityLabel {
    if (_latency < 30) return 'Excellent';
    if (_latency < 60) return 'Good';
    if (_latency < 100) return 'Fair';
    return 'Poor';
  }

  Color get _connectionQualityColor {
    if (_latency < 30) return Colors.green;
    if (_latency < 60) return Colors.lightGreen;
    if (_latency < 100) return Colors.orange;
    return Colors.red;
  }

  IconData get _connectionQualityIcon {
    if (_latency < 30) return Icons.signal_cellular_alt;
    if (_latency < 60) return Icons.signal_cellular_alt_2_bar;
    if (_latency < 100) return Icons.signal_cellular_alt_1_bar;
    return Icons.signal_cellular_0_bar;
  }

  @override
  void initState() {
    super.initState();
    _appState = context.read<AppStateProvider>();
    _audioService = context.read<AudioService>();
    _streamingService = context.read<StreamingService>();
    _bluetoothService = context.read<BluetoothService>();
    _syncService = context.read<SyncService>();
    _settingsService = SettingsService();
    // Provide SyncService to StreamingService for scheduling
    _streamingService.setSyncService(_syncService);
    _audioService.setPreferSpeakerOutput(true);
    _setupListeners();
    _loadRecentHosts();
  }

  void _setupListeners() {
    // Listen to messages from host
    _subscriptions.add(
      _streamingService.messageStream.listen((message) {
        _handleHostMessage(message);
      }),
    );
    // Listen to latency measurements
    _subscriptions.add(
      _streamingService.latencyStream.listen((rttMs) {
        if (!mounted) {
          return;
        }
        setState(() {
          _latency = rttMs;
        });
        // Update clock sync with latest server time if available from last pong via messageStream
        // We also update with local estimate using average
        // No direct server time here; messageStream handles assigning when pong received
      }),
    );

    // Listen to incoming audio data and compute RMS volume for waveform
    _subscriptions.add(
      _streamingService.audioDataStream.listen((audioData) {
        if (audioData.length >= 2) {
          // Compute RMS of PCM16 samples
          int sum = 0;
          final sampleCount = audioData.length ~/ 2;
          for (int i = 0; i < audioData.length - 1; i += 2) {
            final sample =
                audioData.buffer.asByteData().getInt16(i, Endian.little);
            sum += sample * sample;
          }
          final rms = (sum / sampleCount > 0) ? (sum / sampleCount) : 0.0;
          final normalized = (rms / (32768.0 * 32768.0)).clamp(0.0, 1.0);
          _receivedVolumeController.add(normalized.toDouble());
        }
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

    _subscriptions.add(
      _streamingService.connectionStateStream.listen((connected) {
        if (!connected && _appState.isConnectedToHost && !_manualDisconnect) {
          _appState.setConnectedToHost(false);
          if (mounted) setState(() => _isReceivingAudio = false);
          BackgroundAudioService().setPlayingState(playing: false);
          if (_reconnectCount < 5) {
            _reconnectCount++;
            _showSnackBar(
                'Connection lost — reconnecting ($_reconnectCount/5)...');
            Future.delayed(const Duration(seconds: 2), () {
              if (mounted && !_appState.isConnectedToHost) {
                final addr = _appState.hostAddress;
                if (addr != null) _connectToHost(addr);
              }
            });
          } else {
            _reconnectCount = 0;
            _showSnackBar('Could not reconnect — gave up after 5 attempts',
                isError: true);
          }
        }
        if (connected) _reconnectCount = 0;
      }),
    );
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _manualIpController.dispose();
    _receivedVolumeController.close();
    _audioService.stopPlayback();
    if (_isRecording) RecordingService().stopRecording();
    BackgroundAudioService().setPlayingState(playing: false);
    BackgroundAudioService().clearMediaButtonCallbacks();
    super.dispose();
  }

  void _handleHostMessage(Map<String, dynamic> message) {
    switch (message['type']) {
      case 'audio_data':
        // audio chunks are handled by AudioService playback stream once started
        break;
      case 'audio_config':
        _audioSampleRate = (message['sampleRate'] ?? 48000) as int;
        _audioChannels = (message['channels'] ?? 2) as int;
        if (!_isReceivingAudio) {
          _audioService.startPlayback(
            _streamingService.scheduledAudioStream,
            sampleRate: _audioSampleRate,
            numChannels: _audioChannels,
          );
          if (!mounted) {
            return;
          }
          setState(() {
            _isReceivingAudio = true;
          });
          BackgroundAudioService().setPlayingState(
            playing: true,
            title: 'Receiving from ${_appState.hostName ?? "Host"}',
          );
          BackgroundAudioService().setMediaButtonCallbacks(
            onPlay: _unmute,
            onPause: _mute,
            onStop: () {
              _manualDisconnect = true;
              _streamingService.disconnectFromHost();
              _appState.setConnectedToHost(false);
              if (mounted) setState(() => _isReceivingAudio = false);
              BackgroundAudioService().setPlayingState(playing: false);
              BackgroundAudioService().clearMediaButtonCallbacks();
            },
          );
        }
        // Handle audio configuration from host
        break;
      case 'pong':
        // Measure RTT and update clock sync
        final int t0 = (message['t0'] ?? 0) as int;
        final int serverTimeMs = (message['serverTimeMs'] ?? 0) as int;
        final int t1 = DateTime.now().millisecondsSinceEpoch;
        final rtt = t1 - t0;
        if (!mounted) {
          return;
        }
        setState(() {
          _latency = rtt;
        });
        _syncService.updateClockSync(serverTimeMs, rtt);
        break;
      case 'welcome':
        if (message['requiresPin'] == true) {
          _showPinDialog();
        } else if (!_hasRequestedAudioConfig) {
          _hasRequestedAudioConfig = true;
          _streamingService.requestAudioConfig();
        }
        break;
      case 'auth_failed':
        // Wrong PIN — show re-entry dialog without full reconnect
        _showPinRetryDialog();
        break;
      case 'pin_rejected':
        _showSnackBar('Incorrect PIN — access denied', isError: true);
        _hasRequestedAudioConfig = false;
        break;
      case 'pin_accepted':
        if (!_hasRequestedAudioConfig) {
          _hasRequestedAudioConfig = true;
          _streamingService.requestAudioConfig();
        }
        break;
      case 'set_volume':
        final vol = (message['volume'] as num?)?.toDouble() ?? 1.0;
        _audioService.setVolume(vol.clamp(0.0, 1.0));
        if (mounted) {
          _appState.setVolume(vol.clamp(0.0, 1.0));
        }
        break;
    }
  }

  void _showPinRetryDialog() {
    if (!mounted) return;
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Incorrect PIN'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('The PIN you entered was incorrect. Please try again.'),
            const SizedBox(height: 16),
            TextField(
              controller: ctrl,
              decoration: const InputDecoration(
                labelText: 'Host PIN',
                prefixIcon: Icon(Icons.lock_outline),
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.number,
              obscureText: true,
              maxLength: 8,
              autofocus: true,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              _manualDisconnect = true;
              _streamingService.disconnectFromHost();
            },
            child: const Text('Cancel', style: TextStyle(color: Colors.red)),
          ),
          FilledButton(
            onPressed: () {
              final pin = ctrl.text.trim();
              if (pin.length < 4) return;
              Navigator.of(ctx).pop();
              // Re-send PIN without reconnecting
              _streamingService.sendPinToHost(pin);
            },
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }

  void _showPinDialog() {
    final pinController = TextEditingController();
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Host is PIN Protected'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Enter the host PIN to join the audio stream.'),
            const SizedBox(height: 16),
            TextField(
              controller: pinController,
              decoration: const InputDecoration(
                labelText: 'PIN',
                prefixIcon: Icon(Icons.lock_outline),
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.number,
              obscureText: true,
              maxLength: 8,
              autofocus: true,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () async {
              Navigator.of(context).pop();
              _manualDisconnect = true;
              await _streamingService.disconnectFromHost();
              _manualDisconnect = false;
              _appState.setConnectedToHost(false);
            },
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final pin = pinController.text.trim();
              if (pin.isEmpty) return;
              Navigator.of(context).pop();
              _streamingService.sendPinToHost(pin);
            },
            child: const Text('Join'),
          ),
        ],
      ),
    );
  }

  Future<void> _loadRecentHosts() async {
    final hosts = await _settingsService.loadRecentHosts();
    if (mounted) setState(() => _recentHosts = hosts);
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppStateProvider>(
      builder: (context, appState, child) {
        return Padding(
          padding: const EdgeInsets.all(16.0),
          child: ListView(
            children: [
              // Connection status card
              _buildConnectionStatusCard(appState),

              const SizedBox(height: 16),

              // Audio playback controls
              _buildAudioPlaybackCard(appState),

              const SizedBox(height: 16),

              // Audio output selection
              _buildAudioOutputCard(appState),

              const SizedBox(height: 16),

              // Host information
              if (appState.isConnectedToHost) ...[
                _buildHostInfoCard(appState),
                const SizedBox(height: 16),
              ],

              // Available hosts for connection
              if (!appState.isConnectedToHost) ...[
                _buildAvailableHostsList(),
              ] else ...[
                // Connected Bluetooth devices
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Audio Output Devices',
                          style:
                              Theme.of(context).textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.bold,
                                  ),
                        ),
                        IconButton(
                          icon: Icon(MdiIcons.bluetooth),
                          onPressed: _scanForBluetoothDevices,
                          tooltip: 'Scan for Bluetooth devices',
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 320,
                      child: DeviceListWidget(
                        devices: appState.connectedDevices,
                        isHost: false,
                        onDeviceDisconnect: _disconnectDevice,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _buildConnectionStatusCard(AppStateProvider appState) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  appState.isConnectedToHost ? MdiIcons.link : MdiIcons.linkOff,
                  color:
                      appState.isConnectedToHost ? Colors.green : Colors.grey,
                  size: 24,
                ),
                const SizedBox(width: 8),
                Text(
                  appState.isConnectedToHost
                      ? 'Connected to Host'
                      : 'Not Connected',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: appState.isConnectedToHost
                            ? Colors.green
                            : Colors.grey,
                      ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (appState.isConnectedToHost) ...[
              Text('Host: ${appState.hostName ?? 'Unknown'}'),
              Text('Address: ${appState.hostAddress ?? 'Unknown'}'),
              if (_latency > 0) ...[
                const SizedBox(height: 4),
                Row(
                  children: [
                    Chip(
                      label: Text(
                        _connectionQualityLabel,
                        style: const TextStyle(
                            fontSize: 11, fontWeight: FontWeight.bold),
                      ),
                      avatar: Icon(_connectionQualityIcon, size: 14),
                      backgroundColor:
                          _connectionQualityColor.withValues(alpha: 0.15),
                      side:
                          BorderSide(color: _connectionQualityColor, width: 1),
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                    ),
                    const SizedBox(width: 8),
                    Text('${_latency}ms RTT',
                        style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ],
              Row(
                children: [
                  const Text('Signal: '),
                  Expanded(
                    child: LinearProgressIndicator(
                      value: _signalStrength,
                      backgroundColor: Colors.grey.withValues(alpha: 0.3),
                      valueColor: AlwaysStoppedAnimation<Color>(
                        _signalStrength > 0.7
                            ? Colors.green
                            : _signalStrength > 0.4
                                ? Colors.orange
                                : Colors.red,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text('${(_signalStrength * 100).toInt()}%'),
                ],
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () async {
                  _manualDisconnect = true;
                  await _streamingService.disconnectFromHost();
                  _manualDisconnect = false;
                  if (mounted) {
                    _appState.setConnectedToHost(false);
                    setState(() => _isReceivingAudio = false);
                  }
                  BackgroundAudioService().setPlayingState(playing: false);
                },
                icon: const Icon(Icons.link_off, size: 18),
                label: const Text('Disconnect'),
              ),
            ] else ...[
              const Text('Connect to a host to start receiving audio'),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildAudioPlaybackCard(AppStateProvider appState) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Audio Playback',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Icon(
                  _isReceivingAudio ? MdiIcons.play : MdiIcons.pause,
                  color: _isReceivingAudio ? Colors.green : Colors.grey,
                  size: 32,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _isReceivingAudio
                            ? 'Receiving Audio'
                            : 'No Audio Signal',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                      if (_isReceivingAudio) ...[
                        const SizedBox(height: 4),
                        Text(
                          'Quality: ${appState.audioQuality.displayName}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ],
                  ),
                ),
                IconButton(
                  onPressed: appState.isMuted ? _unmute : _mute,
                  icon: Icon(appState.isMuted
                      ? MdiIcons.volumeOff
                      : MdiIcons.volumeHigh),
                  tooltip: appState.isMuted ? 'Unmute' : 'Mute',
                ),
              ],
            ),
            const SizedBox(height: 16),
            // Volume slider
            Row(
              children: [
                Icon(MdiIcons.volumeLow),
                Expanded(
                  child: Slider(
                    value: appState.volume,
                    onChanged: (value) {
                      appState.setVolume(value);
                      _audioService.setVolume(value);
                    },
                    divisions: 20,
                    label: '${(appState.volume * 100).round()}%',
                  ),
                ),
                Icon(MdiIcons.volumeHigh),
              ],
            ),
            if (_isReceivingAudio) ...[
              const SizedBox(height: 8),
              AudioWaveformWidget(
                volumeStream: _receivedVolumeController.stream,
                isActive: _isReceivingAudio,
                color: Theme.of(context).colorScheme.secondary,
              ),
            ],
            const SizedBox(height: 12),
            const Divider(),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (!_isRecording)
                  FilledButton.icon(
                    onPressed: _isReceivingAudio ? _startRecording : null,
                    icon: const Icon(Icons.fiber_manual_record),
                    label: const Text('Record'),
                    style: FilledButton.styleFrom(
                      backgroundColor: Theme.of(context).colorScheme.error,
                      foregroundColor: Colors.white,
                    ),
                  )
                else
                  FilledButton.icon(
                    onPressed: _stopRecording,
                    icon: const Icon(Icons.stop),
                    label: const Text('Stop'),
                  ),
                if (_lastRecordingPath != null && !_isRecording) ...[
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: _shareRecording,
                    icon: const Icon(Icons.share, size: 18),
                    label: const Text('Share'),
                  ),
                ],
              ],
            ),
            if (_isRecording) ...[
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.circle,
                      size: 10, color: Theme.of(context).colorScheme.error),
                  const SizedBox(width: 6),
                  Text('Recording…',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.error,
                          )),
                ],
              ),
            ],
            if (_lastRecordingPath != null && !_isRecording) ...[
              const SizedBox(height: 4),
              Text(
                _lastRecordingPath!.split(RegExp(r'[/\\]')).last,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _connectToHost(String hostAddress, {int? port}) async {
    final appState = _appState;
    final effectivePort = port ?? appState.port;
    _hasRequestedAudioConfig = false;
    _isReceivingAudio = false;
    BackgroundAudioService().setPlayingState(playing: false);
    _showSnackBar('Connecting to $hostAddress...');
    final ok =
        await _streamingService.connectToHost(hostAddress, port: effectivePort);
    if (!mounted) {
      return;
    }
    if (ok) {
      appState.setConnectedToHost(true,
          hostAddress: hostAddress, hostName: 'Audio Splitter Host');
      await _settingsService.saveRecentHost(hostAddress, effectivePort);
      setState(() {
        _isReceivingAudio = false;
      });
      _loadRecentHosts();
      _showSnackBar('Connected to host');
    } else {
      _showSnackBar('Failed to connect to host', isError: true);
    }
  }

  Future<void> _startRecording() async {
    final ok = await RecordingService().startRecording(
      _streamingService.scheduledAudioStream,
      sampleRate: _audioSampleRate,
      channels: _audioChannels,
    );
    if (!mounted) return;
    setState(() => _isRecording = ok);
    if (!ok) _showSnackBar('Failed to start recording', isError: true);
  }

  Future<void> _stopRecording() async {
    final path = await RecordingService().stopRecording();
    if (!mounted) return;
    setState(() {
      _isRecording = false;
      _lastRecordingPath = path;
    });
    _showSnackBar(path != null ? 'Recording saved' : 'Recording failed',
        isError: path == null);
  }

  Future<void> _shareRecording() async {
    if (_lastRecordingPath == null) return;
    await Share.shareXFiles(
      [XFile(_lastRecordingPath!)],
      subject: 'Audio Splitter Recording',
    );
  }

  Widget _buildAudioOutputCard(AppStateProvider appState) {
    final bluetoothDevices = appState.connectedDevices
        .where((device) =>
            device.type == DeviceType.bluetoothHeadset ||
            device.type == DeviceType.bluetoothSpeaker)
        .toList();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Audio Output',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 8),
            RadioListTile<String>(
              value: 'speaker',
              groupValue: _selectedOutputId,
              title: const Text('Device Speaker'),
              secondary: Icon(MdiIcons.speaker),
              onChanged: (value) {
                if (value == null || !mounted) return;
                setState(() => _selectedOutputId = value);
                _audioService.setPreferSpeakerOutput(true);
                _showSnackBar('Audio routed to Device Speaker');
              },
            ),
            ...bluetoothDevices.map((device) => RadioListTile<String>(
                  value: device.id,
                  groupValue: _selectedOutputId,
                  title: Text(device.name),
                  subtitle: Text(device.type.displayName),
                  secondary: Icon(MdiIcons.bluetooth),
                  onChanged: (value) {
                    if (value == null || !mounted) return;
                    setState(() => _selectedOutputId = value);
                    _audioService.setPreferSpeakerOutput(false);
                    _showSnackBar('Audio routed to ${device.name}');
                  },
                )),
          ],
        ),
      ),
    );
  }

  Widget _buildHostInfoCard(AppStateProvider appState) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Host Information',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 8),
            ListTile(
              leading: Icon(MdiIcons.server),
              title: Text(appState.hostName ?? 'Unknown Host'),
              subtitle: Text(appState.hostAddress ?? 'Unknown Address'),
            ),
            ListTile(
              leading: Icon(MdiIcons.musicNote),
              title: const Text('Audio Quality'),
              subtitle: Text(appState.audioQuality.displayName),
            ),
            if (_latency > 0) ...[
              ListTile(
                leading: Icon(MdiIcons.speedometer),
                title: const Text('Latency'),
                subtitle: Text('${_latency}ms'),
                trailing: Icon(
                  _latency < 50
                      ? MdiIcons.checkCircle
                      : _latency < 100
                          ? MdiIcons.alertCircle
                          : MdiIcons.closeCircle,
                  color: _latency < 50
                      ? Colors.green
                      : _latency < 100
                          ? Colors.orange
                          : Colors.red,
                ),
              ),
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: LatencyGraphWidget(
                  latencyStream: _streamingService.latencyStream,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildRecentHostsList() {
    if (_recentHosts.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Recent',
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
        const SizedBox(height: 4),
        ..._recentHosts.map((host) => Card(
              margin: const EdgeInsets.only(bottom: 4),
              child: ListTile(
                dense: true,
                leading: Icon(Icons.history,
                    color: Theme.of(context).colorScheme.primary),
                title: Text(host['name'] ?? 'Audio Splitter Host'),
                subtitle: Text('${host['host']}:${host['port']}'),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton(
                      onPressed: () => _connectToHost(host['host'],
                          port: host['port'] as int?),
                      child: const Text('Connect'),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, size: 16),
                      onPressed: () async {
                        await _settingsService.removeRecentHost(
                            host['host'], host['port'] as int);
                        _loadRecentHosts();
                      },
                    ),
                  ],
                ),
              ),
            )),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _buildAvailableHostsList() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _manualIpController,
                    decoration: const InputDecoration(
                      labelText: 'Enter host IP',
                      hintText: '192.168.1.x',
                      prefixIcon: Icon(Icons.lan),
                      border: OutlineInputBorder(),
                      isDense: true,
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    ),
                    keyboardType: TextInputType.number,
                    onSubmitted: (_) => _connectManual(),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _connectManual,
                  child: const Text('Connect'),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        _buildRecentHostsList(),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Available Hosts',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.qr_code_scanner),
                  tooltip: 'Scan QR Code',
                  onPressed: _showQrScanner,
                ),
                const SizedBox(width: 4),
                FilledButton.icon(
                  onPressed: _isScanning ? null : _scanForHosts,
                  icon: _isScanning
                      ? SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Theme.of(context).colorScheme.onPrimary,
                          ),
                        )
                      : Icon(MdiIcons.refresh),
                  label: Text(_isScanning ? 'Scanning...' : 'Scan'),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (_discoveredHosts.isEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(32.0),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      MdiIcons.accessPointNetwork,
                      size: 56,
                      color: Theme.of(context)
                          .colorScheme
                          .primary
                          .withValues(alpha: 0.5),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _isScanning ? 'Scanning network...' : 'No hosts found',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Make sure the host device is on the same WiFi network.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
          )
        else
          ...(_discoveredHosts.map((host) => Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor:
                        Theme.of(context).colorScheme.primaryContainer,
                    child: Icon(MdiIcons.broadcast,
                        color:
                            Theme.of(context).colorScheme.onPrimaryContainer),
                  ),
                  title: Text(host['name'] ?? 'Audio Splitter Host'),
                  subtitle: Text('${host['host']}:${host['port']}'),
                  trailing: FilledButton(
                    onPressed: () => _connectToHost(host['host']),
                    child: const Text('Connect'),
                  ),
                ),
              ))),
      ],
    );
  }

  void _connectManual() {
    final text = _manualIpController.text.trim();
    if (text.isEmpty) return;
    // Parse optional port: "192.168.1.5:9090"
    final parts = text.split(':');
    final ip = parts[0];
    final port = parts.length > 1 ? int.tryParse(parts[1]) : null;
    _connectToHost(ip, port: port);
  }

  String? _validateAudioSplitterUri(Uri uri) {
    if (uri.scheme != 'audiosplitter') return 'Invalid QR code format';
    final host = uri.host;
    if (host.isEmpty) return 'Missing host address';

    // Validate IPv4 or basic hostname
    final ipv4 = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$');
    final hostnameRe =
        RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9\-\.]{0,253}[a-zA-Z0-9]$');
    if (!ipv4.hasMatch(host) && !hostnameRe.hasMatch(host)) {
      return 'Invalid host address: $host';
    }
    if (ipv4.hasMatch(host)) {
      final parts = host.split('.').map(int.parse).toList();
      if (parts.any((p) => p > 255)) return 'Invalid IP address: $host';
    }

    final port = uri.port;
    if (port <= 0 || port > 65535) return 'Invalid port: $port';

    return null; // valid
  }

  void _showQrScanner() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.qr_code_scanner),
            SizedBox(width: 8),
            Text('Scan Host QR Code'),
          ],
        ),
        content: SizedBox(
          width: 280,
          height: 280,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: MobileScanner(
              onDetect: (capture) {
                final barcode = capture.barcodes.firstOrNull;
                final raw = barcode?.rawValue;
                if (raw == null) return;
                final uri = Uri.tryParse(raw);
                if (uri == null) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content:
                          const Text('Invalid QR code: could not parse URI'),
                      backgroundColor: Theme.of(context).colorScheme.error,
                      behavior: SnackBarBehavior.floating,
                    ));
                  }
                  return;
                }
                final error = _validateAudioSplitterUri(uri);
                if (error != null) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text('Invalid QR code: $error'),
                      backgroundColor: Theme.of(context).colorScheme.error,
                      behavior: SnackBarBehavior.floating,
                    ));
                  }
                  return;
                }
                Navigator.of(context).pop();
                final port = uri.port > 0 ? uri.port : _appState.port;
                _connectToHost(uri.host, port: port);
              },
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  void _mute() {
    context.read<AppStateProvider>().setMuted(true);
    _audioService.setVolume(0.0);
  }

  void _unmute() {
    final appState = context.read<AppStateProvider>();
    appState.setMuted(false);
    _audioService.setVolume(appState.volume);
  }

  Future<void> _scanForHosts() async {
    setState(() {
      _isScanning = true;
      _discoveredHosts.clear();
    });
    final sub = _streamingService.discoveredHostStream.listen((host) {
      if (!mounted) return;
      setState(() {
        if (!_discoveredHosts.any(
            (h) => h['host'] == host['host'] && h['port'] == host['port'])) {
          _discoveredHosts.add(host);
        }
      });
    });
    await _streamingService.scanForHosts(port: _appState.port);
    await sub.cancel();
    if (mounted) {
      setState(() => _isScanning = false);
    }
  }

  Future<void> _scanForBluetoothDevices() async {
    _showSnackBar('Scanning for Bluetooth devices...');
    // Ensure service is ready
    await _bluetoothService.initialize();
    await _bluetoothService.startScanning(timeout: const Duration(seconds: 15));
  }

  Future<void> _disconnectDevice(String deviceId) async {
    await _bluetoothService.disconnectFromDevice(deviceId);
    if (!mounted) {
      return;
    }
    _appState.removeConnectedDevice(deviceId);
    setState(() {
      if (_selectedOutputId == deviceId) {
        _selectedOutputId = 'speaker';
      }
    });
    _showSnackBar('Device disconnected');
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
