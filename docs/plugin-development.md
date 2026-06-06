# Plugin Development Guide (Plugin SDK v1)

The Audio Splitter Plugin SDK lets third parties add **sources** (audio
generators / capture), **effects** (per-sample/per-block transforms), and
**sinks** (outputs) without touching engine internals. A plugin builds against
the public contracts re-exported from `package:audio_splitter_app/plugin_sdk/plugin_sdk.dart`
only — the same surface the bundled `SampleTonePlugin` uses, so that reference
plugin doubles as your template.

> SDK version: **1** (`kPluginSdkVersion`). A plugin declares the SDK major it
> targets; the host rejects a plugin built against an incompatible major.

---

## 1. The three node contracts

| Contract       | You implement                                   | Used as           |
|----------------|-------------------------------------------------|-------------------|
| `IAudioSource` | `id`, `format`, `chunks` (Stream), `isActive`, `start()`, `stop()` | a source node |
| `IEffect`      | `id`, `process(PcmChunk) → PcmChunk`, `dispose()` | an effect node  |
| `IAudioSink`   | `id`, `open()`, `write(PcmChunk)`, `close()`     | an output node    |

All three exchange `PcmChunk` (`pcm` bytes + `presentationTsUs` + `format`).
`AudioFormat` defaults: `cdStereo` (48 kHz / 2ch / 16-bit) and `voiceMono`.

**Determinism:** nodes must not call `Math.random`, `DateTime.now()`, or read
the wall clock. Timestamps are passed in via the chunk. This keeps the whole
pipeline replayable and testable — the same rule the engine follows.

---

## 2. Anatomy of a plugin

```dart
import 'package:audio_splitter_app/plugin_sdk/plugin_sdk.dart';

class MyPlugin extends AudioPlugin {
  const MyPlugin();

  @override
  PluginManifest get manifest => const PluginManifest(
        id: 'com.example.my',           // globally unique, reverse-DNS
        name: 'My Plugin',
        version: '1.0.0',
        author: 'you',
        capabilities: {PluginCapability.effect},
        // sdkVersion defaults to the current kPluginSdkVersion
      );

  @override
  IEffect createEffect(String nodeId, Map<String, dynamic> params) =>
      MyEffect(id: nodeId, amount: (params['amount'] as num?)?.toDouble() ?? 1.0);
}
```

`AudioPlugin` provides `createSource` / `createEffect` / `createSink` that
return `null` by default; override only the ones your `capabilities` advertise.

See the full worked example in
`lib/plugin_sdk/sample_plugin.dart` (`ToneSource` + `GainEffect`).

---

## 3. Registering and using plugins

```dart
final registry = PluginRegistry();              // hostSdkVersion = kPluginSdkVersion
if (!registry.register(const MyPlugin())) {
  // rejected — inspect registry.rejected for the reason
}
final plugin = registry.byId('com.example.my')!;
final effect = plugin.createEffect('trim', {'amount': 0.5})!;
final out = effect.process(chunk);
```

`register` returns `false` (and appends a reason to `registry.rejected`) when:

* the plugin targets an **incompatible SDK major** (`"targets SDK N"`), or
* a plugin with the same `id` is already registered (`"duplicate"`).

`registry.providing(PluginCapability.effect)` lists everything that can supply a
given node kind.

---

## 4. Effect authoring notes

* `process` should return a **new** `PcmChunk` (use `chunk.copyWith(pcm: out)`)
  and must preserve length and format unless the effect is explicitly a
  resampler/format converter.
* Return the input chunk unchanged for an identity/no-op (e.g. gain at 0 dB) to
  avoid an allocation — `GainEffect` does this.
* Clamp to the 16-bit range when writing samples back
  (`value.clamp(-32768, 32767)`).
* If you carry filter state, keep it **per channel** and reset it in `dispose`.

---

## 5. Source authoring notes

* Emit on the `chunks` stream after `start()`; complete the stream in `stop()`.
* Keep generation phase-continuous across chunk boundaries (carry a global
  sample index), as `ToneSource` does.
* Stamp `presentationTsUs` from a passed-in base, never the clock.

---

## 6. Packaging & distribution

Plugin SDK v1 ships as in-tree Dart (compile-time linked). A dynamic
load-from-disk plugin host (isolate-sandboxed, capability-scoped) is planned for
a later SDK major; the contracts here are forward-stable so a v1 plugin's node
classes carry forward unchanged. Until then, vendor your plugin as a Dart
package and register it at app start.

The conformance test your plugin should pass mirrors
`test/asp2/plugin_sdk_test.dart`: register cleanly, expose the right
capabilities, and run a chunk through your node end-to-end.
