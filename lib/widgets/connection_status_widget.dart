import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import '../providers/app_state_provider.dart';

class ConnectionStatusWidget extends StatefulWidget {
  const ConnectionStatusWidget({super.key});

  @override
  State<ConnectionStatusWidget> createState() => _ConnectionStatusWidgetState();
}

class _ConnectionStatusWidgetState extends State<ConnectionStatusWidget>
    with TickerProviderStateMixin {
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    );
    _pulseAnimation = Tween<double>(
      begin: 0.8,
      end: 1.2,
    ).animate(CurvedAnimation(
      parent: _pulseController,
      curve: Curves.easeInOut,
    ));

    _pulseController.repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppStateProvider>(
      builder: (context, appState, child) {
        if (!appState.hasActiveConnections && !appState.isHosting) {
          return const SizedBox.shrink();
        }

        return Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: _getStatusColor(appState).withValues(alpha: 0.1),
            border: Border(
              bottom: BorderSide(
                color: _getStatusColor(appState).withValues(alpha: 0.3),
                width: 1,
              ),
            ),
          ),
          child: Row(
            children: [
              // Status indicator with pulse animation
              AnimatedBuilder(
                animation: _pulseAnimation,
                builder: (context, child) {
                  return Transform.scale(
                    scale: appState.hasActiveConnections
                        ? _pulseAnimation.value
                        : 1.0,
                    child: Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: _getStatusColor(appState),
                        shape: BoxShape.circle,
                        boxShadow: appState.hasActiveConnections
                            ? [
                                BoxShadow(
                                  color: _getStatusColor(appState)
                                      .withValues(alpha: 0.5),
                                  blurRadius: 4,
                                  spreadRadius: 1,
                                )
                              ]
                            : null,
                      ),
                    ),
                  );
                },
              ),

              const SizedBox(width: 12),

              // Status icon
              Icon(
                _getStatusIcon(appState),
                size: 16,
                color: _getStatusColor(appState),
              ),

              const SizedBox(width: 8),

              // Status text
              Expanded(
                child: Text(
                  _getStatusText(appState),
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: _getStatusColor(appState),
                  ),
                ),
              ),

              // Additional info
              if (appState.mode == AppMode.host && appState.isHosting) ...[
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: _getStatusColor(appState).withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '${appState.connectedDeviceCount} ${appState.connectedDeviceCount == 1 ? 'device' : 'devices'}',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: _getStatusColor(appState),
                    ),
                  ),
                ),
              ],

              if (appState.mode == AppMode.client &&
                  appState.isConnectedToHost) ...[
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: _getStatusColor(appState).withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        MdiIcons.signalCellular3,
                        size: 12,
                        color: _getStatusColor(appState),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'Connected',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: _getStatusColor(appState),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Color _getStatusColor(AppStateProvider appState) {
    if (appState.mode == AppMode.host) {
      if (appState.isHosting && appState.connectedDeviceCount > 0) {
        return Colors.green;
      } else if (appState.isHosting) {
        return Colors.orange;
      } else {
        return Colors.grey;
      }
    } else {
      if (appState.isConnectedToHost) {
        return Colors.green;
      } else {
        return Colors.grey;
      }
    }
  }

  IconData _getStatusIcon(AppStateProvider appState) {
    if (appState.mode == AppMode.host) {
      if (appState.isHosting && appState.connectedDeviceCount > 0) {
        return MdiIcons.broadcast;
      } else if (appState.isHosting) {
        return MdiIcons.broadcastOff;
      } else {
        return MdiIcons.serverOff;
      }
    } else {
      if (appState.isConnectedToHost) {
        return MdiIcons.link;
      } else {
        return MdiIcons.linkOff;
      }
    }
  }

  String _getStatusText(AppStateProvider appState) {
    if (appState.mode == AppMode.host) {
      if (appState.isHosting && appState.connectedDeviceCount > 0) {
        return 'Broadcasting to connected devices • Port ${appState.port}';
      } else if (appState.isHosting) {
        return 'Hosting active, waiting for connections • Port ${appState.port}';
      } else {
        return 'Not hosting';
      }
    } else {
      if (appState.isConnectedToHost) {
        return 'Connected to ${appState.hostName ?? 'host'} (${appState.hostAddress})';
      } else {
        return 'Not connected to any host';
      }
    }
  }
}
