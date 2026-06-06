/// # Audio Splitter Plugin SDK v1
///
/// The public, stable surface third-party plugins build against. A plugin
/// implements the same three pipeline contracts the engine uses internally —
/// [IAudioSource] (produce audio), [IEffect] (transform audio), [IAudioSink]
/// (consume audio) — and advertises them through a [PluginManifest]. The host
/// discovers plugins via a [PluginRegistry] and instantiates their nodes into
/// the source-router DAG exactly like built-in nodes.
///
/// This file re-exports the contracts so a plugin author imports a single,
/// versioned entry point (`package:audio_splitter_app/plugin_sdk/plugin_sdk.dart`)
/// rather than reaching into engine internals.
library plugin_sdk;

import '../core/contracts/audio_format.dart';
import '../core/contracts/i_audio_sink.dart';
import '../core/contracts/i_audio_source.dart';
import '../core/contracts/i_effect.dart';
import '../core/pipeline/audio_chunk.dart';

export '../core/contracts/audio_format.dart';
export '../core/contracts/i_audio_sink.dart';
export '../core/contracts/i_audio_source.dart';
export '../core/contracts/i_effect.dart';
export '../core/pipeline/audio_chunk.dart';

/// SDK ABI version. The host refuses to load a plugin built against a major
/// version it does not support.
const int kPluginSdkVersion = 1;

/// The node kinds a plugin can provide.
enum PluginCapability { source, effect, sink }

/// Static metadata a plugin publishes about itself.
class PluginManifest {
  /// Reverse-DNS-style unique id, e.g. `com.example.reverb`.
  final String id;
  final String name;
  final String version;
  final String author;

  /// SDK major version this plugin targets.
  final int sdkVersion;

  /// Which node kinds [AudioPlugin] can build.
  final Set<PluginCapability> capabilities;

  const PluginManifest({
    required this.id,
    required this.name,
    required this.version,
    required this.author,
    required this.capabilities,
    this.sdkVersion = kPluginSdkVersion,
  });

  /// Whether this plugin is loadable under host SDK major [hostSdkVersion].
  bool isCompatibleWith(int hostSdkVersion) => sdkVersion == hostSdkVersion;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'version': version,
        'author': author,
        'sdkVersion': sdkVersion,
        'capabilities': [for (final c in capabilities) c.name],
      };
}

/// Base class a plugin extends. Override only the factory methods for the
/// capabilities the manifest advertises; the rest return null. `nodeId` is the
/// DAG node id the host assigns; `params` are user-config values.
abstract class AudioPlugin {
  const AudioPlugin();

  PluginManifest get manifest;

  IAudioSource? createSource(String nodeId, Map<String, dynamic> params) =>
      null;

  IEffect? createEffect(String nodeId, Map<String, dynamic> params) => null;

  IAudioSink? createSink(String nodeId, Map<String, dynamic> params) => null;
}

/// Host-side plugin registry: register plugins, then query by capability or id.
/// Incompatible-SDK plugins are rejected at registration (never silently
/// loaded) and recorded in [rejected] with a reason.
class PluginRegistry {
  final int hostSdkVersion;
  final Map<String, AudioPlugin> _byId = {};
  final List<String> rejected = [];

  PluginRegistry({this.hostSdkVersion = kPluginSdkVersion});

  /// Register [plugin]; returns false (and appends to [rejected]) if its SDK
  /// version is incompatible or its id is already taken.
  bool register(AudioPlugin plugin) {
    final m = plugin.manifest;
    if (!m.isCompatibleWith(hostSdkVersion)) {
      rejected.add('${m.id}: targets SDK ${m.sdkVersion}, '
          'host is $hostSdkVersion');
      return false;
    }
    if (_byId.containsKey(m.id)) {
      rejected.add('${m.id}: duplicate plugin id');
      return false;
    }
    _byId[m.id] = plugin;
    return true;
  }

  AudioPlugin? byId(String id) => _byId[id];

  Iterable<AudioPlugin> get plugins => _byId.values;

  /// Plugins that advertise [capability].
  Iterable<AudioPlugin> providing(PluginCapability capability) =>
      _byId.values.where((p) => p.manifest.capabilities.contains(capability));
}

/// Marker mixin documenting that an effect is a one-shot pure transform with no
/// retained state (so the host may run it off the audio thread or cache it).
/// Optional; plugins need not use it.
mixin StatelessEffect on IEffect {}

// ---------------------------------------------------------------------------
// Re-exported aliases so plugin authors can name the contracts without the
// engine-internal path showing up in their code.
// ---------------------------------------------------------------------------

typedef PluginFormat = AudioFormat;
typedef PluginChunk = PcmChunk;
