import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import '../providers/app_state_provider.dart';
import '../services/audio_service.dart';
import '../models/audio_stream.dart';
import 'package:file_picker/file_picker.dart';

class AudioSourceSelector extends StatefulWidget {
  const AudioSourceSelector({super.key});

  @override
  State<AudioSourceSelector> createState() => _AudioSourceSelectorState();
}

class _AudioSourceSelectorState extends State<AudioSourceSelector> {
  final _streamingUrlController = TextEditingController();

  @override
  void dispose() {
    _streamingUrlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppStateProvider>(
      builder: (context, appState, child) {
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Audio Source',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
                const SizedBox(height: 16),

                Text(
                  'Select microphone to capture voice, or media file to stream local audio.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context)
                            .colorScheme
                            .onSurface
                            .withValues(alpha: 0.7),
                      ),
                ),

                const SizedBox(height: 12),

                // Audio source options
                Column(
                  children: AudioSource.values
                      .map((source) => _buildSourceOption(
                          source, appState.selectedAudioSource))
                      .toList(),
                ),

                const SizedBox(height: 16),

                // Additional options for selected source
                if (appState.selectedAudioSource == AudioSource.mediaFile) ...[
                  _buildMediaFileOptions(),
                ] else if (appState.selectedAudioSource ==
                    AudioSource.streaming) ...[
                  _buildStreamingOptions(),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildSourceOption(AudioSource source, AudioSource selectedSource) {
    final isSelected = selectedSource == source;
    final isEnabled = _isSourceEnabled(source);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: isEnabled ? () => _selectSource(source) : null,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: isSelected
                ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.1)
                : Colors.transparent,
            border: Border.all(
              color: isSelected
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context)
                      .colorScheme
                      .outline
                      .withValues(alpha: 0.3),
              width: isSelected ? 2 : 1,
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              // Radio button
              Radio<AudioSource>(
                value: source,
                groupValue: selectedSource,
                onChanged: isEnabled ? (_) => _selectSource(source) : null,
                activeColor: Theme.of(context).colorScheme.primary,
              ),

              // Source icon
              Icon(
                _getSourceIcon(source),
                size: 24,
                color: isEnabled
                    ? (isSelected
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).colorScheme.onSurface)
                    : Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.5),
              ),

              const SizedBox(width: 12),

              // Source info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      source.displayName,
                      style: TextStyle(
                        fontWeight:
                            isSelected ? FontWeight.bold : FontWeight.normal,
                        color: isEnabled
                            ? (isSelected
                                ? Theme.of(context).colorScheme.primary
                                : Theme.of(context).colorScheme.onSurface)
                            : Theme.of(context)
                                .colorScheme
                                .onSurface
                                .withValues(alpha: 0.5),
                      ),
                    ),
                    Text(
                      _getSourceDescription(source),
                      style: TextStyle(
                        fontSize: 12,
                        color: isEnabled
                            ? Theme.of(context)
                                .colorScheme
                                .onSurface
                                .withValues(alpha: 0.7)
                            : Theme.of(context)
                                .colorScheme
                                .onSurface
                                .withValues(alpha: 0.5),
                      ),
                    ),
                  ],
                ),
              ),

              // Status indicator
              if (!isEnabled) ...[
                Icon(
                  MdiIcons.lock,
                  size: 16,
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.5),
                ),
              ] else if (isSelected) ...[
                Icon(
                  MdiIcons.check,
                  size: 16,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMediaFileOptions() {
    final audioService = context.watch<AudioService>();
    final isPlaylist = audioService.isPlaylistMode;
    final trackName = audioService.currentTrackName ?? 'No file selected';
    final playlist = audioService.playlist;
    final idx = audioService.playlistIndex;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Media File',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
          const SizedBox(height: 8),

          // Current track display
          Row(
            children: [
              Icon(
                isPlaylist ? Icons.queue_music : Icons.music_note,
                size: 18,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  trackName,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                        color: audioService.selectedMediaFilePath != null
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),

          // Playlist position indicator
          if (isPlaylist) ...[
            const SizedBox(height: 4),
            Text(
              'Track ${idx + 1} of ${playlist.length}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ],

          const SizedBox(height: 12),

          // Playback controls (next/prev) — shown when playlist has multiple tracks
          if (isPlaylist && playlist.length > 1) ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton.outlined(
                  onPressed:
                      idx > 0 ? () => audioService.previousTrack() : null,
                  icon: const Icon(Icons.skip_previous),
                  tooltip: 'Previous track',
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: LinearProgressIndicator(
                    value: playlist.isEmpty ? 0 : (idx + 1) / playlist.length,
                    backgroundColor:
                        Theme.of(context).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.outlined(
                  onPressed: idx < playlist.length - 1
                      ? () => audioService.nextTrack()
                      : null,
                  icon: const Icon(Icons.skip_next),
                  tooltip: 'Next track',
                ),
              ],
            ),
            const SizedBox(height: 8),
          ],

          // File picker buttons
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _selectSingleMediaFile,
                  icon: const Icon(Icons.audio_file, size: 18),
                  label: const Text('Single File'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.icon(
                  onPressed: _selectMultipleMediaFiles,
                  icon: const Icon(Icons.queue_music, size: 18),
                  label: const Text('Playlist'),
                ),
              ),
            ],
          ),

          const SizedBox(height: 8),
          Text(
            'Supported: WAV (streams to clients) · MP3, AAC, FLAC (play locally)',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),

          // Playlist track list (collapsible if long)
          if (isPlaylist && playlist.isNotEmpty) ...[
            const SizedBox(height: 8),
            const Divider(),
            const SizedBox(height: 4),
            ...playlist.asMap().entries.take(5).map((entry) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      Icon(
                        entry.key == idx
                            ? Icons.play_arrow
                            : Icons.music_note_outlined,
                        size: 14,
                        color: entry.key == idx
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          entry.value.split(RegExp(r'[/\\]')).last,
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    fontWeight: entry.key == idx
                                        ? FontWeight.bold
                                        : FontWeight.normal,
                                    color: entry.key == idx
                                        ? Theme.of(context).colorScheme.primary
                                        : null,
                                  ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                )),
            if (playlist.length > 5)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '+ ${playlist.length - 5} more tracks',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _buildStreamingOptions() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Streaming Options',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _streamingUrlController,
            decoration: const InputDecoration(
              labelText: 'Stream URL',
              hintText: 'https://example.com/stream.m3u8',
              prefixIcon: Icon(Icons.link),
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.url,
            onChanged: (v) {
              context.read<AppStateProvider>().setStreamingUrl(v);
              context.read<AudioService>().setStreamingUrl(v);
            },
            onSubmitted: (v) {
              if (v.isNotEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text('Stream URL set: $v'),
                  behavior: SnackBarBehavior.floating,
                ));
              }
            },
          ),
          const SizedBox(height: 8),
          Text(
            'Supported: HTTP Live Streaming (HLS), RTMP, SHOUTcast',
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context)
                  .colorScheme
                  .onSurface
                  .withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }

  IconData _getSourceIcon(AudioSource source) {
    switch (source) {
      case AudioSource.microphone:
        return MdiIcons.microphone;
      case AudioSource.systemAudio:
        return MdiIcons.monitor;
      case AudioSource.musicPlayer:
        return MdiIcons.musicBox;
      case AudioSource.mediaFile:
        return MdiIcons.fileMusic;
      case AudioSource.streaming:
        return MdiIcons.webBox;
    }
  }

  String _getSourceDescription(AudioSource source) {
    switch (source) {
      case AudioSource.microphone:
        return 'Capture audio from device microphone';
      case AudioSource.systemAudio:
        return 'Capture all system audio output';
      case AudioSource.musicPlayer:
        return 'Stream from music player app';
      case AudioSource.mediaFile:
        return 'Play and stream audio files';
      case AudioSource.streaming:
        return 'Relay audio from online streams';
    }
  }

  bool _isSourceEnabled(AudioSource source) {
    if (source == AudioSource.streaming) {
      return context.read<AppStateProvider>().streamingUrl.isNotEmpty;
    }
    return context.read<AudioService>().isSourceSupported(source);
  }

  void _selectSource(AudioSource source) {
    if (!_isSourceEnabled(source)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.read<AudioService>().sourceSupportNote(source)),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    context.read<AppStateProvider>().setSelectedAudioSource(source);

    // Notify parent components about source change
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Selected audio source: ${source.displayName}'),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _selectSingleMediaFile() async {
    try {
      final result = await FilePicker.pickFiles(type: FileType.audio);
      if (result != null && result.files.single.path != null && mounted) {
        context
            .read<AudioService>()
            .setSelectedMediaFile(result.files.single.path);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Selected: ${result.files.single.name}'),
          behavior: SnackBarBehavior.floating,
        ));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Error: $e'),
        behavior: SnackBarBehavior.floating,
        backgroundColor: Theme.of(context).colorScheme.error,
      ));
    }
  }

  Future<void> _selectMultipleMediaFiles() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.audio,
        allowMultiple: true,
      );
      if (result != null && result.files.isNotEmpty && mounted) {
        final paths = result.files
            .where((f) => f.path != null)
            .map((f) => f.path!)
            .toList();
        context.read<AudioService>().setPlaylist(paths);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Playlist: ${paths.length} tracks loaded'),
          behavior: SnackBarBehavior.floating,
        ));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Error: $e'),
        behavior: SnackBarBehavior.floating,
        backgroundColor: Theme.of(context).colorScheme.error,
      ));
    }
  }
}
