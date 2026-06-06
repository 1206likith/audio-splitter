import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import '../providers/app_state_provider.dart';
import '../services/audio_service.dart';
import '../models/audio_stream.dart' as model;

class AudioControlsWidget extends StatefulWidget {
  const AudioControlsWidget({super.key});

  @override
  State<AudioControlsWidget> createState() => _AudioControlsWidgetState();
}

class _AudioControlsWidgetState extends State<AudioControlsWidget>
    with TickerProviderStateMixin {
  late AnimationController _volumeAnimationController;
  late Animation<double> _volumeAnimation;
  bool _showVolumeSlider = false;

  @override
  void initState() {
    super.initState();
    _volumeAnimationController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _volumeAnimation = CurvedAnimation(
      parent: _volumeAnimationController,
      curve: Curves.easeInOut,
    );
  }

  @override
  void dispose() {
    _volumeAnimationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppStateProvider>(
      builder: (context, appState, child) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Volume slider (animated)
            AnimatedBuilder(
              animation: _volumeAnimation,
              builder: (context, child) {
                return SizeTransition(
                  sizeFactor: _volumeAnimation,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Row(
                      children: [
                        Icon(MdiIcons.volumeLow, size: 20),
                        Expanded(
                          child: Slider(
                            value: appState.volume,
                            onChanged: (value) {
                              appState.setVolume(value);
                              context.read<AudioService>().setVolume(value);
                            },
                            divisions: 20,
                            label: '${(appState.volume * 100).round()}%',
                          ),
                        ),
                        Icon(MdiIcons.volumeHigh, size: 20),
                        const SizedBox(width: 8),
                        Text('${(appState.volume * 100).round()}%'),
                      ],
                    ),
                  ),
                );
              },
            ),

            // Main controls row
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                // Volume control
                _buildVolumeControl(appState),

                // Main action button
                _buildMainActionButton(appState),

                // Settings/Quality control
                _buildQualityControl(appState),
              ],
            ),
          ],
        );
      },
    );
  }

  Widget _buildVolumeControl(AppStateProvider appState) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          onPressed: () {
            setState(() {
              _showVolumeSlider = !_showVolumeSlider;
            });
            if (_showVolumeSlider) {
              _volumeAnimationController.forward();
            } else {
              _volumeAnimationController.reverse();
            }
          },
          icon: Icon(
            appState.isMuted
                ? MdiIcons.volumeOff
                : appState.volume > 0.6
                    ? MdiIcons.volumeHigh
                    : appState.volume > 0.3
                        ? MdiIcons.volumeMedium
                        : MdiIcons.volumeLow,
            size: 28,
          ),
          tooltip: appState.isMuted ? 'Unmute' : 'Volume',
        ),
        Text(
          appState.isMuted ? 'Muted' : '${(appState.volume * 100).round()}%',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  Widget _buildMainActionButton(AppStateProvider appState) {
    IconData iconData;
    String label;
    Color? backgroundColor;
    VoidCallback? onPressed;

    if (appState.mode == AppMode.host) {
      if (appState.isHosting) {
        if (appState.activeStream?.isActive == true) {
          iconData = MdiIcons.pause;
          label = 'Pause';
          backgroundColor = Theme.of(context).colorScheme.error;
          onPressed = () => _pauseStreaming(appState);
        } else {
          iconData = MdiIcons.play;
          label = 'Stream';
          backgroundColor = Theme.of(context).colorScheme.primary;
          onPressed = appState.canStartStreaming
              ? () => _startStreaming(appState)
              : null;
        }
      } else {
        iconData = MdiIcons.broadcast;
        label = 'Host';
        onPressed = () => _startHosting(appState);
      }
    } else {
      if (appState.isConnectedToHost) {
        iconData = MdiIcons.headphones;
        label = 'Connected';
        backgroundColor = Colors.green;
        onPressed = null; // Just status indicator
      } else {
        iconData = MdiIcons.link;
        label = 'Connect';
        onPressed = () => _showConnectDialog();
      }
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        FloatingActionButton(
          onPressed: onPressed,
          backgroundColor: backgroundColor,
          child: Icon(iconData),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  Widget _buildQualityControl(AppStateProvider appState) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        PopupMenuButton<model.AudioQuality>(
          onSelected: (quality) {
            appState.setAudioQuality(quality);
          },
          itemBuilder: (context) => model.AudioQuality.values.map((quality) {
            return PopupMenuItem(
              value: quality,
              child: Row(
                children: [
                  Icon(
                    _getQualityIcon(quality),
                    size: 20,
                    color: appState.audioQuality == quality
                        ? Theme.of(context).colorScheme.primary
                        : null,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    quality.displayName,
                    style: TextStyle(
                      fontWeight: appState.audioQuality == quality
                          ? FontWeight.bold
                          : FontWeight.normal,
                      color: appState.audioQuality == quality
                          ? Theme.of(context).colorScheme.primary
                          : null,
                    ),
                  ),
                ],
              ),
            );
          }).toList(),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: Theme.of(context)
                    .colorScheme
                    .outline
                    .withValues(alpha: 0.3),
              ),
            ),
            child: Icon(
              _getQualityIcon(appState.audioQuality),
              size: 24,
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          _getQualityShortName(appState.audioQuality),
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  IconData _getQualityIcon(model.AudioQuality quality) {
    switch (quality) {
      case model.AudioQuality.low:
        return MdiIcons.signalCellular1;
      case model.AudioQuality.medium:
        return MdiIcons.signalCellular2;
      case model.AudioQuality.high:
        return MdiIcons.signalCellular3;
      case model.AudioQuality.ultra:
        return MdiIcons.signalCellular3;
    }
  }

  String _getQualityShortName(model.AudioQuality quality) {
    switch (quality) {
      case model.AudioQuality.low:
        return 'Low';
      case model.AudioQuality.medium:
        return 'Med';
      case model.AudioQuality.high:
        return 'High';
      case model.AudioQuality.ultra:
        return 'Ultra';
    }
  }

  void _startHosting(AppStateProvider appState) {
    // This would trigger the hosting start in the parent component
    // For now, just show a message
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Use the floating action button to start hosting'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _startStreaming(AppStateProvider appState) {
    // This would trigger audio streaming start
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
            'Starting audio stream to ${appState.connectedDeviceCount} devices'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _pauseStreaming(AppStateProvider appState) {
    // This would pause the current audio stream
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Audio streaming paused'),
        behavior: SnackBarBehavior.floating,
      ),
    );
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

  void _connectToHost(String address) {
    if (address.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter a valid IP address'),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Connecting to $address...'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}
