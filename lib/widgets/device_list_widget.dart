import 'package:flutter/material.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import '../models/connected_device.dart';
import '../services/streaming_service.dart' show ClientStats;

class DeviceListWidget extends StatefulWidget {
  final List<ConnectedDevice> devices;
  final bool isHost;
  final Function(String)? onDeviceDisconnect;
  final Function(String)? onDeviceConnect;
  final Function(String deviceId, double volume)? onVolumeChanged;
  final ClientStats? Function(String deviceId)? getClientStats;

  const DeviceListWidget({
    super.key,
    required this.devices,
    required this.isHost,
    this.onDeviceDisconnect,
    this.onDeviceConnect,
    this.onVolumeChanged,
    this.getClientStats,
  });

  @override
  State<DeviceListWidget> createState() => _DeviceListWidgetState();
}

class _DeviceListWidgetState extends State<DeviceListWidget> {
  final Map<String, double> _deviceVolumes = {};

  @override
  Widget build(BuildContext context) {
    if (widget.devices.isEmpty) {
      return _buildEmptyState(context);
    }

    return ListView.builder(
      itemCount: widget.devices.length,
      itemBuilder: (context, index) {
        final device = widget.devices[index];
        return _buildDeviceCard(context, device);
      },
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              widget.isHost
                  ? MdiIcons.accountMultipleOutline
                  : MdiIcons.serverOff,
              size: 64,
              color: Colors.grey,
            ),
            const SizedBox(height: 16),
            Text(
              widget.isHost
                  ? 'No devices connected'
                  : 'No output devices connected',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: Colors.grey,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              widget.isHost
                  ? 'Start hosting and have clients connect to this device'
                  : 'Connect Bluetooth headphones or speakers for audio output',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.grey,
                  ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDeviceCard(BuildContext context, ConnectedDevice device) {
    final volume = _deviceVolumes[device.id] ?? 1.0;
    return Card(
      margin: const EdgeInsets.only(bottom: 8.0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: _buildDeviceIcon(device),
            title: Text(
              device.name,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(device.type.displayName),
                if (device.ipAddress != 'bluetooth') ...[
                  Text('IP: ${device.ipAddress}'),
                ],
                if (device.latency > 0) ...[
                  Text('Latency: ${device.latency.toStringAsFixed(0)}ms'),
                ],
              ],
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Connection status indicator
                Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: device.isConnected ? Colors.green : Colors.red,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),

                // Signal strength indicator (for wireless devices)
                if (device.type == DeviceType.bluetoothHeadset ||
                    device.type == DeviceType.bluetoothSpeaker) ...[
                  _buildSignalStrengthIcon(device),
                  const SizedBox(width: 8),
                ],

                // Actions menu
                PopupMenuButton<String>(
                  onSelected: (value) =>
                      _handleMenuAction(context, device, value),
                  itemBuilder: (context) => [
                    if (device.isConnected) ...[
                      PopupMenuItem(
                        value: 'disconnect',
                        child: Row(
                          children: [
                            Icon(MdiIcons.linkOff, size: 20),
                            const SizedBox(width: 8),
                            const Text('Disconnect'),
                          ],
                        ),
                      ),
                      PopupMenuItem(
                        value: 'info',
                        child: Row(
                          children: [
                            Icon(MdiIcons.informationOutline, size: 20),
                            const SizedBox(width: 8),
                            const Text('Device Info'),
                          ],
                        ),
                      ),
                    ] else ...[
                      PopupMenuItem(
                        value: 'connect',
                        child: Row(
                          children: [
                            Icon(MdiIcons.link, size: 20),
                            const SizedBox(width: 8),
                            const Text('Connect'),
                          ],
                        ),
                      ),
                    ],
                    if (widget.isHost) ...[
                      PopupMenuItem(
                        value: 'remove',
                        child: Row(
                          children: [
                            Icon(MdiIcons.delete, size: 20, color: Colors.red),
                            const SizedBox(width: 8),
                            const Text('Remove',
                                style: TextStyle(color: Colors.red)),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
            onTap: () => _showDeviceDetails(context, device),
          ),
          if (widget.isHost && widget.onVolumeChanged != null) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Row(
                children: [
                  const Icon(Icons.volume_down, size: 16, color: Colors.grey),
                  Expanded(
                    child: Slider(
                      value: volume,
                      min: 0.0,
                      max: 1.0,
                      divisions: 20,
                      label: '${(volume * 100).round()}%',
                      onChanged: (v) {
                        setState(() => _deviceVolumes[device.id] = v);
                        widget.onVolumeChanged!(device.id, v);
                      },
                    ),
                  ),
                  const Icon(Icons.volume_up, size: 16, color: Colors.grey),
                  SizedBox(
                    width: 36,
                    child: Text(
                      '${(volume * 100).round()}%',
                      style: const TextStyle(fontSize: 11, color: Colors.grey),
                      textAlign: TextAlign.right,
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (widget.isHost && widget.getClientStats != null) ...[
            Builder(builder: (context) {
              final stats = widget.getClientStats!(device.id);
              if (stats == null) return const SizedBox.shrink();
              final minutes = stats.duration.inMinutes;
              final seconds = stats.duration.inSeconds % 60;
              return Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Row(
                  children: [
                    const Icon(Icons.analytics_outlined,
                        size: 14, color: Colors.grey),
                    const SizedBox(width: 6),
                    Text(
                      '${stats.packetsSent} pkts · ${(stats.bytesSent / 1024).toStringAsFixed(0)} KB · '
                      '${stats.kbps.toStringAsFixed(1)} KB/s · '
                      '${minutes}m${seconds}s',
                      style: const TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                  ],
                ),
              );
            }),
          ],
        ],
      ),
    );
  }

  Widget _buildDeviceIcon(ConnectedDevice device) {
    IconData iconData;
    Color iconColor = device.isConnected ? Colors.blue : Colors.grey;

    switch (device.type) {
      case DeviceType.phone:
        iconData = MdiIcons.cellphone;
        break;
      case DeviceType.tablet:
        iconData = MdiIcons.tablet;
        break;
      case DeviceType.computer:
        iconData = MdiIcons.laptop;
        break;
      case DeviceType.bluetoothHeadset:
        iconData = MdiIcons.headphones;
        break;
      case DeviceType.bluetoothSpeaker:
        iconData = MdiIcons.speaker;
        break;
      case DeviceType.smartWatch:
        iconData = MdiIcons.watch;
        break;
      case DeviceType.other:
        iconData = MdiIcons.devices;
        break;
    }

    return CircleAvatar(
      backgroundColor: iconColor.withValues(alpha: 0.1),
      child: Icon(
        iconData,
        color: iconColor,
        size: 24,
      ),
    );
  }

  Widget _buildSignalStrengthIcon(ConnectedDevice device) {
    // This would typically be based on actual signal strength data
    // For now, we'll use a placeholder based on connection status
    final strength = device.isConnected ? 0.8 : 0.2;

    return Icon(
      strength > 0.6
          ? MdiIcons.wifiStrength4
          : strength > 0.4
              ? MdiIcons.wifiStrength3
              : strength > 0.2
                  ? MdiIcons.wifiStrength2
                  : MdiIcons.wifiStrength1,
      size: 20,
      color: strength > 0.6
          ? Colors.green
          : strength > 0.4
              ? Colors.orange
              : Colors.red,
    );
  }

  void _handleMenuAction(
      BuildContext context, ConnectedDevice device, String action) {
    switch (action) {
      case 'connect':
        widget.onDeviceConnect?.call(device.id);
        break;
      case 'disconnect':
        widget.onDeviceDisconnect?.call(device.id);
        break;
      case 'info':
        _showDeviceDetails(context, device);
        break;
      case 'remove':
        _showRemoveDeviceDialog(context, device);
        break;
    }
  }

  void _showDeviceDetails(BuildContext context, ConnectedDevice device) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            _buildDeviceIcon(device),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                device.name,
                style: const TextStyle(fontSize: 18),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildInfoRow('Device Type', device.type.displayName),
            _buildInfoRow('Connection Status',
                device.isConnected ? 'Connected' : 'Disconnected'),
            if (device.ipAddress != 'bluetooth')
              _buildInfoRow('IP Address', device.ipAddress),
            if (device.latency > 0)
              _buildInfoRow(
                  'Latency', '${device.latency.toStringAsFixed(0)}ms'),
            _buildInfoRow('Connected At', _formatDateTime(device.connectedAt)),
            const SizedBox(height: 16),

            // Connection quality indicator
            if (device.isConnected) ...[
              const Text(
                'Connection Quality',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              LinearProgressIndicator(
                value: device.latency > 0
                    ? (1.0 - (device.latency / 200).clamp(0.0, 1.0))
                    : 0.8,
                backgroundColor: Colors.grey.withValues(alpha: 0.3),
                valueColor: AlwaysStoppedAnimation<Color>(
                  device.latency < 50
                      ? Colors.green
                      : device.latency < 100
                          ? Colors.orange
                          : Colors.red,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                device.latency < 50
                    ? 'Excellent'
                    : device.latency < 100
                        ? 'Good'
                        : 'Poor',
                style: TextStyle(
                  fontSize: 12,
                  color: device.latency < 50
                      ? Colors.green
                      : device.latency < 100
                          ? Colors.orange
                          : Colors.red,
                ),
              ),
            ],
          ],
        ),
        actions: [
          if (device.isConnected && widget.onDeviceDisconnect != null) ...[
            TextButton.icon(
              onPressed: () {
                Navigator.of(context).pop();
                widget.onDeviceDisconnect!(device.id);
              },
              icon: Icon(MdiIcons.linkOff, size: 16),
              label: const Text('Disconnect'),
              style: TextButton.styleFrom(foregroundColor: Colors.red),
            ),
          ],
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              '$label:',
              style: const TextStyle(
                fontWeight: FontWeight.w500,
                color: Colors.grey,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontWeight: FontWeight.w400),
            ),
          ),
        ],
      ),
    );
  }

  void _showRemoveDeviceDialog(BuildContext context, ConnectedDevice device) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove Device'),
        content: Text(
            'Are you sure you want to remove "${device.name}" from the list?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.of(context).pop();
              widget.onDeviceDisconnect?.call(device.id);
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
  }

  String _formatDateTime(DateTime dateTime) {
    final now = DateTime.now();
    final difference = now.difference(dateTime);

    if (difference.inMinutes < 1) {
      return 'Just now';
    } else if (difference.inHours < 1) {
      return '${difference.inMinutes}m ago';
    } else if (difference.inDays < 1) {
      return '${difference.inHours}h ago';
    } else {
      return '${dateTime.day}/${dateTime.month}/${dateTime.year}';
    }
  }
}
