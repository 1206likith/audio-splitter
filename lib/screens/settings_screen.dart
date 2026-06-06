import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import '../asp2/asp2_config.dart';
import '../providers/app_state_provider.dart';
import '../services/streaming_service.dart';
import '../services/settings_service.dart';
import '../models/audio_stream.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late SettingsService _settingsService;
  String? _currentPin;
  bool _useAsp2Wire = Asp2Config.useAsp2Wire;

  @override
  void initState() {
    super.initState();
    _settingsService = context.read<SettingsService>();
    _loadPin();
  }

  Future<void> _loadPin() async {
    final pin = await _settingsService.loadHostPin();
    if (mounted) setState(() => _currentPin = pin);
  }

  @override
  Widget build(BuildContext context) {
    return Consumer2<AppStateProvider, StreamingService>(
      builder: (context, appState, streaming, _) {
        return Scaffold(
          appBar: AppBar(
            title: const Text('Settings',
                style: TextStyle(fontWeight: FontWeight.bold)),
            centerTitle: true,
          ),
          body: ListView(
            children: [
              _sectionHeader('Network'),
              ListTile(
                leading: Icon(MdiIcons.networkOutline),
                title: const Text('Port'),
                subtitle: Text('Current: ${appState.port}'),
                trailing: IconButton(
                  icon: Icon(MdiIcons.pencil),
                  onPressed: () => _showPortDialog(appState),
                ),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.swap_horiz),
                title: const Text('Binary Transport'),
                subtitle: const Text(
                    'Compact binary WebSocket frames — faster, less overhead'),
                value: streaming.useBinaryTransport,
                onChanged: (v) => streaming.setUseBinaryTransport(v),
              ),
              _sectionHeader('Audio'),
              ListTile(
                leading: Icon(MdiIcons.musicNote),
                title: const Text('Streaming Quality'),
                subtitle: Text(appState.audioQuality.displayName),
                trailing: DropdownButton<AudioQuality>(
                  value: appState.audioQuality,
                  underline: const SizedBox(),
                  onChanged: (q) {
                    if (q != null) appState.setAudioQuality(q);
                  },
                  items: AudioQuality.values
                      .map((q) => DropdownMenuItem(
                            value: q,
                            child: Text(q.displayName),
                          ))
                      .toList(),
                ),
              ),
              ListTile(
                leading: Icon(MdiIcons.information),
                title: const Text('Codec'),
                subtitle:
                    const Text('Low: AAC · Medium/High: Opus · Ultra: PCM16'),
                dense: true,
              ),
              SwitchListTile(
                secondary: Icon(MdiIcons.equalizer),
                title: const Text('Stereo Audio'),
                subtitle: const Text('Off = mono (halves bandwidth)'),
                value: appState.stereo,
                onChanged: (v) => appState.setStereo(v),
              ),
              ListTile(
                leading: Icon(MdiIcons.timerOutline),
                title: const Text('Buffer Size'),
                subtitle: Text(
                    '${appState.bufferSizeMs}ms — lower = less latency, higher = smoother'),
                trailing: DropdownButton<int>(
                  value: appState.bufferSizeMs,
                  underline: const SizedBox(),
                  onChanged: (v) {
                    if (v != null) appState.setBufferSizeMs(v);
                  },
                  items: const [
                    DropdownMenuItem(
                        value: 60, child: Text('60ms (Low latency)')),
                    DropdownMenuItem(
                        value: 120, child: Text('120ms (Balanced)')),
                    DropdownMenuItem(value: 250, child: Text('250ms (Smooth)')),
                    DropdownMenuItem(
                        value: 500, child: Text('500ms (Max smooth)')),
                  ],
                ),
              ),
              _sectionHeader('Host Protection'),
              ListTile(
                leading: Icon(MdiIcons.lock),
                title: const Text('Host PIN'),
                subtitle: Text(_currentPin != null
                    ? 'PIN set — clients must enter PIN to join'
                    : 'No PIN — anyone can join'),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_currentPin != null)
                      TextButton(
                        onPressed: () async {
                          await _settingsService.saveHostPin(null);
                          streaming.setHostPin(null);
                          if (mounted) setState(() => _currentPin = null);
                          _snack('PIN removed');
                        },
                        child: const Text('Remove',
                            style: TextStyle(color: Colors.red)),
                      ),
                    FilledButton(
                      onPressed: () => _showSetPinDialog(streaming),
                      child: Text(_currentPin != null ? 'Change' : 'Set PIN'),
                    ),
                  ],
                ),
              ),
              SwitchListTile(
                secondary: Icon(MdiIcons.shieldKey),
                title: const Text('Encrypt Audio Stream'),
                subtitle:
                    const Text('AES-128 encryption for each broadcast session'),
                value: streaming.encryptionEnabled,
                onChanged: (v) {
                  if (v) {
                    streaming.enableEncryption();
                  } else {
                    streaming.disableEncryption();
                  }
                  setState(() {});
                },
              ),
              _sectionHeader('ASP-2 Protocol'),
              SwitchListTile(
                secondary: Icon(MdiIcons.radioTower),
                title: const Text('ASP-2 Wire Format'),
                subtitle: const Text(
                    'Send audio as ASP-2 PCM16 frames (native peers only). '
                    'Default off until two-device smoke test. '
                    'Legacy web room always uses v1 format.'),
                value: _useAsp2Wire,
                onChanged: (v) {
                  // Import is handled via asp2_config.dart at service level.
                  // The flag is a static — updating here reflects immediately.
                  // ignore: invalid_use_of_protected_member
                  setState(() => _useAsp2Wire = v);
                  streaming.setUseAsp2Wire(v);
                },
              ),
              _sectionHeader('Advanced'),
              SwitchListTile(
                secondary: Icon(MdiIcons.replay),
                title: const Text('Loopback Test'),
                subtitle: const Text('Play host audio locally for testing'),
                value: streaming.loopbackTestEnabled,
                onChanged: (v) => streaming.setLoopbackTest(v),
              ),
              _sectionHeader('Developer'),
              SwitchListTile(
                secondary: Icon(MdiIcons.chartLine),
                title: const Text('Show Performance Metrics'),
                subtitle: const Text(
                    'Display latency, jitter, and buffer stats overlay'),
                value: appState.showDiagnostics,
                onChanged: (v) => appState.setShowDiagnostics(v),
              ),
              _sectionHeader('About'),
              ListTile(
                leading: Icon(MdiIcons.broadcast),
                title: const Text('Audio Splitter'),
                subtitle: const Text('Version 1.0.0'),
              ),
              ListTile(
                leading: Icon(MdiIcons.license),
                title: const Text('Open Source Licenses'),
                onTap: () => showLicensePage(
                    context: context, applicationName: 'Audio Splitter'),
              ),
              const SizedBox(height: 32),
            ],
          ),
        );
      },
    );
  }

  Widget _sectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
      child: Text(
        title.toUpperCase(),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.2,
            ),
      ),
    );
  }

  void _showPortDialog(AppStateProvider appState) {
    final ctrl = TextEditingController(text: appState.port.toString());
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Set Port'),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(
              labelText: 'Port (1024–65534)', border: OutlineInputBorder()),
          keyboardType: TextInputType.number,
          autofocus: true,
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              final port = int.tryParse(ctrl.text);
              if (port != null && port > 1024 && port < 65535) {
                appState.setPort(port);
                Navigator.pop(context);
                _snack('Port set to $port');
              } else {
                _snack('Invalid port', error: true);
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _showSetPinDialog(StreamingService streaming) {
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Set Host PIN'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
                'Clients must enter this PIN before joining your stream.'),
            const SizedBox(height: 16),
            TextField(
              controller: ctrl,
              decoration: const InputDecoration(
                labelText: 'PIN (4–8 digits)',
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
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              final pin = ctrl.text.trim();
              if (pin.length < 4) {
                _snack('PIN must be at least 4 digits', error: true);
                return;
              }
              Navigator.pop(context);
              await _settingsService.saveHostPin(pin);
              streaming.setHostPin(pin);
              if (mounted) setState(() => _currentPin = pin);
              _snack('PIN set successfully');
            },
            child: const Text('Save PIN'),
          ),
        ],
      ),
    );
  }

  void _snack(String message, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      behavior: SnackBarBehavior.floating,
      backgroundColor: error ? Theme.of(context).colorScheme.error : null,
    ));
  }
}
