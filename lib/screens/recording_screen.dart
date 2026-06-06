import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:provider/provider.dart';

import '../utils/file_io.dart' as file_io;

import '../asp2/record/audio_encoder.dart';
import '../asp2/record/session_bundle.dart';
import '../asp2/record/stem_recorder.dart';
import '../asp2/security/recording_consent.dart';
import '../services/streaming_service.dart';

class RecordingScreen extends StatefulWidget {
  const RecordingScreen({super.key});

  @override
  State<RecordingScreen> createState() => _RecordingScreenState();
}

class _RecordingScreenState extends State<RecordingScreen> {
  late StreamingService _streaming;

  // Recording duration ticker.
  Timer? _ticker;
  int _elapsedSeconds = 0;

  // Completed session (shown after stop).
  RecordedSession? _lastSession;
  String? _savedPath;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _streaming = context.read<StreamingService>();
    if (_streaming.isMultiStemRecording) _startTicker();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  void _startTicker() {
    _ticker?.cancel();
    _elapsedSeconds = 0;
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _elapsedSeconds++);
    });
  }

  void _stopTicker() {
    _ticker?.cancel();
    _ticker = null;
  }

  Future<void> _startRecording() async {
    final name =
        'Session_${DateTime.now().toIso8601String().replaceAll(':', '-').substring(0, 19)}';
    final nowUs = DateTime.now().microsecondsSinceEpoch;
    final ok = _streaming.startMultiStemRecording(name, nowUs);
    if (ok) {
      _startTicker();
      setState(() {
        _lastSession = null;
        _savedPath = null;
      });
    }
  }

  Future<void> _stopRecording() async {
    _stopTicker();
    final session = _streaming.stopMultiStemRecording();
    if (mounted) setState(() => _lastSession = session);
  }

  Future<void> _saveBundle() async {
    final session = _lastSession;
    if (session == null) return;
    setState(() => _saving = true);
    try {
      final zipBytes = SessionBundle.build(
        session,
        stemEncoder: EncoderRegistry.resolveOrFallback('flac'),
        includeReaper: true,
        includeAbleton: true,
      );
      final safeName = session.name
          .replaceAll(RegExp(r'[^\w\-]'), '_')
          .substring(0, session.name.length < 40 ? session.name.length : 40);
      final savedPath = await file_io.saveBytes('$safeName.zip', zipBytes);
      if (mounted) setState(() => _savedPath = savedPath);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Save failed: $e'),
              backgroundColor: Theme.of(context).colorScheme.error),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _formatDuration(int secs) {
    final h = secs ~/ 3600;
    final m = (secs % 3600) ~/ 60;
    final s = secs % 60;
    if (h > 0) {
      return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Recording',
            style: TextStyle(fontWeight: FontWeight.bold)),
        centerTitle: true,
      ),
      body: ListenableBuilder(
        listenable: _streaming,
        builder: (context, _) {
          final isRecording = _streaming.isMultiStemRecording;
          final consent = _streaming.recordingConsent;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _buildStatusCard(isRecording),
              const SizedBox(height: 16),
              _buildConsentCard(consent),
              if (_lastSession != null) ...[
                const SizedBox(height: 16),
                _buildSessionCard(_lastSession!),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _buildStatusCard(bool isRecording) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Icon(
              isRecording ? MdiIcons.radioboxMarked : MdiIcons.radioboxBlank,
              size: 48,
              color: isRecording
                  ? theme.colorScheme.error
                  : theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(
              isRecording ? 'Recording' : 'Ready',
              style: theme.textTheme.headlineSmall
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            if (isRecording) ...[
              const SizedBox(height: 4),
              Text(
                _formatDuration(_elapsedSeconds),
                style: theme.textTheme.displaySmall?.copyWith(
                  fontFamily: 'monospace',
                  color: theme.colorScheme.error,
                  fontWeight: FontWeight.w300,
                ),
              ),
            ],
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: isRecording ? _stopRecording : _startRecording,
                icon: Icon(isRecording ? MdiIcons.stop : MdiIcons.record),
                label: Text(isRecording ? 'Stop Recording' : 'Start Recording'),
                style: FilledButton.styleFrom(
                  backgroundColor: isRecording
                      ? theme.colorScheme.error
                      : theme.colorScheme.primary,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
            if (!isRecording) ...[
              const SizedBox(height: 8),
              Text(
                'Captures a master-mix stem of the live audio. '
                'Export includes Reaper .rpp and Ableton .als projects.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildConsentCard(RecordingConsent consent) {
    final theme = Theme.of(context);
    final participants = consent.participants.toList();
    final canRecord = consent.canStartRecording;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  canRecord ? Icons.check_circle : Icons.pending,
                  color: canRecord
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Text(
                  'Recording Consent',
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              participants.isEmpty
                  ? 'No clients connected. Connect a device to begin.'
                  : canRecord
                      ? 'All ${participants.length} client(s) have consented.'
                      : '${consent.blockers.length} client(s) have not yet consented.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            if (participants.isNotEmpty) ...[
              const SizedBox(height: 12),
              ...participants.map((id) {
                final state = consent.stateOf(id) ?? ConsentState.unknown;
                return _ConsentTile(
                  clientId: id,
                  state: state,
                  onGrant: () => _streaming.setClientConsent(id, true),
                  onDeny: () => _streaming.setClientConsent(id, false),
                );
              }),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSessionCard(RecordedSession session) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(MdiIcons.checkCircle,
                    color: theme.colorScheme.primary, size: 20),
                const SizedBox(width: 8),
                Text(
                  'Session Ready',
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _InfoRow('Name', session.name),
            _InfoRow(
              'Duration',
              '${session.durationSeconds.toStringAsFixed(1)}s',
            ),
            _InfoRow(
              'Stems',
              '${session.stems.length} (${session.stems.map((s) => s.spec.name).join(', ')})',
            ),
            _InfoRow('Sample rate', '${session.sampleRate} Hz'),
            const SizedBox(height: 16),
            if (_savedPath != null) ...[
              Row(
                children: [
                  Icon(MdiIcons.folderOpen,
                      size: 16, color: theme.colorScheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _savedPath!,
                      style: theme.textTheme.bodySmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
            ],
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _saving ? null : _saveBundle,
                icon: _saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(MdiIcons.download),
                label: Text(_saving
                    ? 'Saving…'
                    : _savedPath != null
                        ? 'Save Again'
                        : 'Export Bundle (.zip)'),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Exports FLAC stems + Reaper .rpp + Ableton .als + manifest.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConsentTile extends StatelessWidget {
  final String clientId;
  final ConsentState state;
  final VoidCallback onGrant;
  final VoidCallback onDeny;

  const _ConsentTile({
    required this.clientId,
    required this.state,
    required this.onGrant,
    required this.onDeny,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final icon = switch (state) {
      ConsentState.granted =>
        Icon(Icons.check_circle, color: theme.colorScheme.primary, size: 18),
      ConsentState.denied =>
        Icon(Icons.cancel, color: theme.colorScheme.error, size: 18),
      ConsentState.unknown => Icon(Icons.help_outline,
          color: theme.colorScheme.onSurfaceVariant, size: 18),
    };
    final label = switch (state) {
      ConsentState.granted => 'Granted',
      ConsentState.denied => 'Denied',
      ConsentState.unknown => 'Pending',
    };

    return ListTile(
      dense: true,
      leading: icon,
      title: Text(clientId, style: theme.textTheme.bodyMedium),
      subtitle: Text(label, style: theme.textTheme.bodySmall),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextButton(
            onPressed: state == ConsentState.granted ? null : onGrant,
            child: const Text('Grant'),
          ),
          TextButton(
            onPressed: state == ConsentState.denied ? null : onDeny,
            child: const Text('Deny'),
          ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  const _InfoRow(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 90,
            child: Text(label,
                style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600)),
          ),
          Expanded(child: Text(value, style: theme.textTheme.bodySmall)),
        ],
      ),
    );
  }
}
