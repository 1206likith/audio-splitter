import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import '../providers/app_state_provider.dart';
import '../services/audio_service.dart';
import '../services/streaming_service.dart';
import '../services/sync_service.dart';
import '../services/bluetooth_service.dart';
import '../services/performance_service.dart';
import '../services/settings_service.dart';
import '../services/background_audio_service.dart';
import '../widgets/audio_controls_widget.dart';
import '../widgets/connection_status_widget.dart';
import '../widgets/performance_monitor_widget.dart';
import 'host_screen.dart';
import 'client_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {
  late TabController _tabController;
  late AudioService _audioService;
  late StreamingService _streamingService;
  late BluetoothService _bluetoothService;
  late SyncService _syncService;
  late PerformanceService _performanceService;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);

    _audioService = context.read<AudioService>();
    _streamingService = context.read<StreamingService>();
    _bluetoothService = context.read<BluetoothService>();
    _syncService = context.read<SyncService>();
    _performanceService = context.read<PerformanceService>();

    _initializeServices();
  }

  Widget _buildDebugMetrics() {
    final streaming = context.read<StreamingService>();
    final sync = context.read<SyncService>();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Debug Metrics',
                style: Theme.of(context)
                    .textTheme
                    .titleSmall
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: StreamBuilder<int>(
                    stream: streaming.latencyStream,
                    builder: (context, snapshot) {
                      final latency = snapshot.data ?? 0;
                      return Text('RTT: ${latency}ms');
                    },
                  ),
                ),
                Expanded(
                  child: StreamBuilder<SyncStats>(
                    stream: sync.syncStatsStream,
                    builder: (context, snapshot) {
                      final stats = snapshot.data;
                      final jitter = stats?.jitter.toStringAsFixed(1) ?? '0.0';
                      final offset = stats?.clockOffset ?? 0;
                      final buf = stats?.totalBufferSize ?? 0;
                      final drops = stats?.droppedFrames ?? 0;
                      return Text(
                          'Jitter: ${jitter}ms  Offset: ${offset}ms  Buf: $buf  Drops: $drops');
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _initializeServices() async {
    await _audioService.initialize();
    await _bluetoothService.initialize();
    await _syncService.initialize();
    await _performanceService.initialize();
    await BackgroundAudioService().initialize();

    // Restore persisted PIN into StreamingService
    final settingsService = context.read<SettingsService>();
    final savedPin = await settingsService.loadHostPin();
    if (savedPin != null && savedPin.isNotEmpty) {
      _streamingService.setHostPin(savedPin);
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  void _showAboutDialog(BuildContext context) {
    showAboutDialog(
      context: context,
      applicationName: 'Audio Splitter',
      applicationVersion: '1.0.0',
      applicationIcon: Icon(MdiIcons.broadcast, size: 48),
      children: [
        const Text(
            'Stream audio from one device to many — wirelessly, with sub-50ms sync.'),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppStateProvider>(
      builder: (context, appState, child) {
        return Scaffold(
          appBar: AppBar(
            title: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(MdiIcons.musicNote, size: 20),
                const SizedBox(width: 8),
                const Text('Audio Splitter',
                    style: TextStyle(fontWeight: FontWeight.bold)),
              ],
            ),
            centerTitle: true,
            elevation: 2,
            bottom: TabBar(
              controller: _tabController,
              indicatorSize: TabBarIndicatorSize.tab,
              dividerColor: Colors.transparent,
              tabs: [
                Tab(icon: Icon(MdiIcons.broadcast), text: 'Host'),
                Tab(icon: Icon(MdiIcons.headphones), text: 'Client'),
              ],
              onTap: (index) {
                final newMode = index == 0 ? AppMode.host : AppMode.client;
                appState.setMode(newMode);
              },
            ),
            actions: [
              IconButton(
                icon: Icon(MdiIcons.informationOutline),
                onPressed: () => _showAboutDialog(context),
              ),
              IconButton(
                icon: Icon(MdiIcons.cog),
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const SettingsScreen()),
                ),
              ),
            ],
          ),
          body: Column(
            children: [
              // Connection status bar
              const ConnectionStatusWidget(),

              // Auto-reconnect connection banner — only shown in client mode after a prior connection
              StreamBuilder<bool>(
                stream: _streamingService.connectionStateStream,
                builder: (context, snapshot) {
                  final appState = context.read<AppStateProvider>();
                  final connected = snapshot.data ?? false;
                  if (connected || appState.mode == AppMode.host) {
                    return const SizedBox.shrink();
                  }
                  if (!appState.connectionAttempted) {
                    return const SizedBox.shrink();
                  }
                  return Container(
                    width: double.infinity,
                    color: Theme.of(context).colorScheme.errorContainer,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: Text(
                      'Disconnected. Attempting to reconnect…',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color:
                                Theme.of(context).colorScheme.onErrorContainer,
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                  );
                },
              ),

              // Debug metrics — shown when diagnostics overlay is enabled in Settings
              if (appState.showDiagnostics) _buildDebugMetrics(),

              // Performance monitor
              const PerformanceMonitorWidget(),

              // Main content
              Expanded(
                child: TabBarView(
                  controller: _tabController,
                  children: const [
                    HostScreen(),
                    ClientScreen(),
                  ],
                ),
              ),

              // Bottom controls
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.1),
                      blurRadius: 4,
                      offset: const Offset(0, -2),
                    ),
                  ],
                ),
                child: const AudioControlsWidget(),
              ),
            ],
          ),
          floatingActionButton: _buildFloatingActionButton(context, appState),
        );
      },
    );
  }

  Widget? _buildFloatingActionButton(
      BuildContext context, AppStateProvider appState) {
    if (appState.mode == AppMode.host) {
      return FloatingActionButton.extended(
        onPressed: appState.isHosting ? _stopHosting : _startHosting,
        icon: Icon(appState.isHosting ? MdiIcons.stop : MdiIcons.play),
        label: Text(appState.isHosting ? 'Stop Hosting' : 'Start Hosting'),
        backgroundColor: appState.isHosting
            ? Theme.of(context).colorScheme.error
            : Theme.of(context).colorScheme.primary,
      );
    } else {
      return FloatingActionButton.extended(
        onPressed: appState.isConnectedToHost
            ? _disconnectFromHost
            : _showConnectDialog,
        icon:
            Icon(appState.isConnectedToHost ? MdiIcons.linkOff : MdiIcons.link),
        label: Text(appState.isConnectedToHost ? 'Disconnect' : 'Connect'),
        backgroundColor: appState.isConnectedToHost
            ? Theme.of(context).colorScheme.error
            : Theme.of(context).colorScheme.primary,
      );
    }
  }

  Future<void> _startHosting() async {
    final appState = context.read<AppStateProvider>();
    final success = await _streamingService.startHosting(port: appState.port);

    if (success) {
      appState.setHosting(true);
      _showSnackBar('Started hosting on port ${appState.port}');
    } else {
      _showSnackBar('Failed to start hosting', isError: true);
    }
  }

  Future<void> _stopHosting() async {
    final appState = context.read<AppStateProvider>();
    await _streamingService.stopHosting();
    appState.setHosting(false);
    _showSnackBar('Stopped hosting');
  }

  Future<void> _disconnectFromHost() async {
    final appState = context.read<AppStateProvider>();
    await _streamingService.disconnectFromHost();
    appState.setConnectedToHost(false);
    _showSnackBar('Disconnected from host');
  }

  void _showConnectDialog() {
    final TextEditingController addressController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Connect to Host'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: addressController,
              decoration: const InputDecoration(
                labelText: 'Host IP Address',
                hintText: '192.168.1.100',
                prefixIcon: Icon(Icons.computer),
              ),
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
            ),
            const SizedBox(height: 16),
            const Text(
              'Enter the IP address of the host device you want to connect to.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.of(context).pop();
              _connectToHost(addressController.text.trim());
            },
            child: const Text('Connect'),
          ),
        ],
      ),
    );
  }

  Future<void> _connectToHost(String address) async {
    if (address.isEmpty) {
      _showSnackBar('Please enter a valid IP address', isError: true);
      return;
    }

    final appState = context.read<AppStateProvider>();
    _showSnackBar('Connecting to $address...');

    final success =
        await _streamingService.connectToHost(address, port: appState.port);

    if (success) {
      appState.setConnectedToHost(true,
          hostAddress: address, hostName: 'Host Device');
      _showSnackBar('Connected to host successfully');
    } else {
      _showSnackBar('Failed to connect to host', isError: true);
    }
  }

  void _showSnackBar(String message, {bool isError = false}) {
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
