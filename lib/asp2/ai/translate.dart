import '../party/karaoke.dart';

/// Translates caption text from one language to another while preserving the
/// caption's timing. The live, no-network implementation is the deterministic
/// [DictionaryTranslator] (a small built-in glossary for demos/tests); a real
/// on-device MT model or a cloud API is [needs-service]/[needs-model] and
/// deferred ([CloudTranslator]).
abstract class Translator {
  const Translator();

  bool get isAvailable;

  /// Translate [text] from [from] to [to] (BCP-47 tags). Returns the original
  /// text when no translation is possible (graceful degrade).
  String translate(String text, {required String from, required String to});

  /// Translate a [CaptionLine], keeping its timestamp and duration so the
  /// translated line lands on screen exactly when the original would.
  CaptionLine translateCaption(CaptionLine line,
          {required String from, required String to}) =>
      CaptionLine(
        tsUs: line.tsUs,
        text: translate(line.text, from: from, to: to),
        durationMs: line.durationMs,
      );
}

/// No-op translator: returns text unchanged. The right choice when source and
/// target language match, or as the always-safe fallback.
class IdentityTranslator extends Translator {
  const IdentityTranslator();

  @override
  bool get isAvailable => true;

  @override
  String translate(String text, {required String from, required String to}) =>
      text;

  @override
  CaptionLine translateCaption(CaptionLine line,
          {required String from, required String to}) =>
      line;
}

/// **Deterministic dictionary translator** — the live offline path. It looks up
/// each whitespace token in a per-direction glossary (case-insensitive,
/// punctuation-preserving) and passes through anything it doesn't know. Not a
/// real MT engine, but it makes the caption→translation→control-plane pipeline
/// fully testable with zero network, the same spirit as the simulated STT.
class DictionaryTranslator extends Translator {
  // Inherits the default translateCaption (preserves timing).

  /// `"en>es" → { "hello": "hola", ... }`. Keys are lowercase source tokens.
  final Map<String, Map<String, String>> glossaries;

  const DictionaryTranslator(this.glossaries);

  /// A tiny built-in en→es / en→fr glossary for demos and tests.
  factory DictionaryTranslator.demo() => const DictionaryTranslator({
        'en>es': {
          'hello': 'hola',
          'everyone': 'todos',
          'welcome': 'bienvenidos',
          'thank': 'gracias',
          'you': 'a ti',
          'music': 'música',
          'tonight': 'esta noche',
        },
        'en>fr': {
          'hello': 'bonjour',
          'everyone': 'tout le monde',
          'welcome': 'bienvenue',
          'music': 'musique',
          'tonight': 'ce soir',
        },
      });

  @override
  bool get isAvailable => true;

  @override
  String translate(String text, {required String from, required String to}) {
    if (from == to) return text;
    final glossary = glossaries['$from>$to'];
    if (glossary == null) return text;
    return text.split(' ').map((token) {
      final lead = RegExp(r'^\W*').firstMatch(token)?.group(0) ?? '';
      final trail = RegExp(r'\W*$').firstMatch(token)?.group(0) ?? '';
      final core = token.substring(lead.length, token.length - trail.length);
      final hit = glossary[core.toLowerCase()];
      if (hit == null) return token;
      // Preserve a leading-capital on the source word.
      final cased = core.isNotEmpty && core[0].toUpperCase() == core[0]
          ? '${hit[0].toUpperCase()}${hit.substring(1)}'
          : hit;
      return '$lead$cased$trail';
    }).join(' ');
  }
}

/// **[needs-service]** real machine translation scaffold — an on-device MT model
/// (e.g. a small seq2seq) or a cloud translation API. Network/model I/O is
/// deferred; reports unavailable so callers fall back to [DictionaryTranslator]
/// or [IdentityTranslator].
class CloudTranslator extends Translator {
  final String endpoint;

  const CloudTranslator({this.endpoint = ''});

  @override
  bool get isAvailable => false;

  String get unavailableReason =>
      'No translation backend configured on this build; '
      'use DictionaryTranslator (offline) on the device path.';

  @override
  String translate(String text, {required String from, required String to}) =>
      text; // graceful degrade until a backend is wired

  @override
  CaptionLine translateCaption(CaptionLine line,
          {required String from, required String to}) =>
      line;
}
