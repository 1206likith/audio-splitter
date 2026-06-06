import 'package:flutter/material.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import '../asp2/party/beat_grid.dart';
import '../asp2/party/crossfade.dart' show Crossfade;

/// DJ deck screen — Phase 5 party layer UI.
///
/// This screen exposes the ASP-2 [HostCrossfader] and [BeatGrid] state to the
/// host operator. Track loading and live deck playback require a file-picker
/// and an audio output pipeline that are wired when device-specific platform
/// code is available; until then those actions show a clear "coming soon" note
/// — the DSP math ([HostCrossfader], [BeatGrid], [EqKills]) is exercised in
/// tests today. [needs-app-verify]
class DjScreen extends StatefulWidget {
  const DjScreen({super.key});

  @override
  State<DjScreen> createState() => _DjScreenState();
}

class _DjScreenState extends State<DjScreen> {
  // Crossfader position: 0.0 = full deck A, 1.0 = full deck B.
  double _crossfader = 0.5;

  // EQ kill switches per deck.
  final _killsA = _EqKills();
  final _killsB = _EqKills();

  // Simulated BPM for demo / manual mode.
  double _bpmA = 120.0;
  double _bpmB = 120.0;

  // Beat grid state (kept local; broadcast via ControlMessage in live wiring).
  BeatGrid? _beatGrid;

  // Track info (placeholder until file-picker wiring [needs-app-verify]).
  // List is final; elements are mutated via setState when tracks are loaded.
  final _tracks = ['No track loaded', 'No track loaded'];

  void _updateCrossfader(double v) {
    setState(() => _crossfader = v);
    // Gains are consumed live in _buildCrossfaderCard; in the wired host path
    // they would also feed the deck audio channels [needs-app-verify].
  }

  void _syncBpm() {
    // Tempo-match deck B to deck A (soundtouch FFI — [needs-FFI]).
    // For now just snap the display.
    setState(() => _bpmB = _bpmA);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('BPM synced (soundtouch FFI — [needs-FFI])'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _setBeatGrid() {
    // In live use the beat detector fires this automatically; here we stamp a
    // manual grid at the current moment.
    setState(() {
      _beatGrid = BeatGrid(
        downbeatTsUs: DateTime.now().microsecondsSinceEpoch,
        bpm: _bpmA,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('DJ Deck',
            style: TextStyle(fontWeight: FontWeight.bold)),
        centerTitle: true,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Beat grid status
          _buildBeatGridCard(theme),
          const SizedBox(height: 16),
          // Two deck cards side-by-side
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                    child: _buildDeckCard('A', _tracks[0], _bpmA, _killsA)),
                const SizedBox(width: 12),
                Expanded(
                    child: _buildDeckCard('B', _tracks[1], _bpmB, _killsB)),
              ],
            ),
          ),
          const SizedBox(height: 16),
          // Crossfader
          _buildCrossfaderCard(theme),
          const SizedBox(height: 16),
          // BPM sync
          _buildBpmCard(theme),
          const SizedBox(height: 16),
          // Deferral note
          Card(
            color: theme.colorScheme.surfaceContainerHighest,
            child: ListTile(
              leading: Icon(MdiIcons.informationOutline,
                  color: theme.colorScheme.onSurfaceVariant),
              title: const Text('Live deck playback'),
              subtitle: const Text(
                  'Track loading and live audio output wiring require a '
                  'file-picker integration and audio output pipeline. '
                  'The DSP math (HostCrossfader, BeatGrid, EQ kills) runs '
                  'today in tests. [needs-app-verify]'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBeatGridCard(ThemeData theme) {
    final grid = _beatGrid;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(
              grid != null ? MdiIcons.metronome : Icons.music_off,
              color: grid != null
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Beat Grid',
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.bold)),
                  Text(
                    grid != null
                        ? '${grid.bpm.toStringAsFixed(1)} BPM'
                        : 'No grid — tap "Set" to stamp a manual downbeat',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            FilledButton.tonal(
              onPressed: _setBeatGrid,
              child: const Text('Set'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDeckCard(
      String label, String track, double bpm, _EqKills kills) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Deck $label',
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(
              track,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: const Text('File picker — [needs-app-verify]'),
                  behavior: SnackBarBehavior.floating,
                  backgroundColor: theme.colorScheme.primary,
                ));
              },
              icon: Icon(MdiIcons.folderOpen, size: 16),
              label: const Text('Load Track'),
            ),
            const SizedBox(height: 8),
            Text('${bpm.toStringAsFixed(1)} BPM',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text('EQ Kills',
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _EqKillButton('Hi', kills.hi, () {
                  setState(() => kills.hi = !kills.hi);
                }),
                _EqKillButton('Mid', kills.mid, () {
                  setState(() => kills.mid = !kills.mid);
                }),
                _EqKillButton('Lo', kills.lo, () {
                  setState(() => kills.lo = !kills.lo);
                }),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCrossfaderCard(ThemeData theme) {
    final gainA = Crossfade.gainA(_crossfader);
    final gainB = Crossfade.gainB(_crossfader);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Text('Crossfader',
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Row(
              children: [
                Text('A', style: theme.textTheme.bodySmall),
                Expanded(
                  child: Slider(
                    value: _crossfader,
                    onChanged: _updateCrossfader,
                    min: 0,
                    max: 1,
                    divisions: 200,
                  ),
                ),
                Text('B', style: theme.textTheme.bodySmall),
              ],
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'A: ${(gainA * 100).toStringAsFixed(0)}%',
                  style: theme.textTheme.bodySmall,
                ),
                Text(
                  'B: ${(gainB * 100).toStringAsFixed(0)}%',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBpmCard(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Tempo',
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Deck A',
                          style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant)),
                      Slider(
                        value: _bpmA,
                        min: 60,
                        max: 200,
                        divisions: 280,
                        label: '${_bpmA.round()} BPM',
                        onChanged: (v) => setState(() => _bpmA = v),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton.tonal(
                  onPressed: _syncBpm,
                  child: const Text('Sync'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _EqKills {
  bool hi = false;
  bool mid = false;
  bool lo = false;
}

class _EqKillButton extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _EqKillButton(this.label, this.active, this.onTap);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: active
              ? theme.colorScheme.error
              : theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.bold,
            color: active
                ? theme.colorScheme.onError
                : theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
