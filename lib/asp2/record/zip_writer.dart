import 'dart:convert';
import 'dart:typed_data';

/// One file destined for a [ZipWriter] archive.
class ZipEntry {
  /// Archive-relative path (forward slashes), e.g. `stems/source_mic.wav`.
  final String path;
  final Uint8List data;

  const ZipEntry(this.path, this.data);

  /// Convenience for a UTF-8 text entry (manifests, DAW projects).
  factory ZipEntry.text(String path, String text) =>
      ZipEntry(path, Uint8List.fromList(utf8.encode(text)));
}

/// Pure-Dart **ZIP** writer in *store* mode (no compression) — enough to bundle
/// recorded stems plus DAW project files and a manifest into one downloadable
/// `.zip` (the plan's "multitrack zip"). Store mode keeps it dependency-free and
/// the audio is already WAV/FLAC; a DEFLATE stage can slot in later behind the
/// same API.
///
/// **Deterministic:** the project bans `DateTime.now`, so every entry uses a
/// fixed DOS timestamp (1980-01-01). The same inputs always yield byte-identical
/// archives, which makes the bundle testable.
class ZipWriter {
  ZipWriter._();

  // Fixed DOS date/time = 1980-01-01 00:00:00 (the DOS epoch). Deterministic.
  static const int _dosTime = 0;
  static const int _dosDate = 0x21; // year 1980, month 1, day 1

  /// Build a ZIP archive from [entries].
  static Uint8List build(List<ZipEntry> entries) {
    final out = BytesBuilder();
    final central = BytesBuilder();
    final offsets = <int>[];
    final crcs = <int>[];

    for (final e in entries) {
      final nameBytes = utf8.encode(e.path);
      final crc = _crc32(e.data);
      offsets.add(out.length);
      crcs.add(crc);

      // Local file header.
      final lh = ByteData(30);
      lh.setUint32(0, 0x04034b50, Endian.little); // signature
      lh.setUint16(4, 20, Endian.little); // version needed
      lh.setUint16(6, 0, Endian.little); // flags
      lh.setUint16(8, 0, Endian.little); // method 0 = store
      lh.setUint16(10, _dosTime, Endian.little);
      lh.setUint16(12, _dosDate, Endian.little);
      lh.setUint32(14, crc, Endian.little);
      lh.setUint32(18, e.data.length, Endian.little); // compressed size
      lh.setUint32(22, e.data.length, Endian.little); // uncompressed size
      lh.setUint16(26, nameBytes.length, Endian.little);
      lh.setUint16(28, 0, Endian.little); // extra length
      out.add(lh.buffer.asUint8List());
      out.add(nameBytes);
      out.add(e.data);
    }

    // Central directory.
    for (var i = 0; i < entries.length; i++) {
      final e = entries[i];
      final nameBytes = utf8.encode(e.path);
      final ch = ByteData(46);
      ch.setUint32(0, 0x02014b50, Endian.little); // signature
      ch.setUint16(4, 20, Endian.little); // version made by
      ch.setUint16(6, 20, Endian.little); // version needed
      ch.setUint16(8, 0, Endian.little); // flags
      ch.setUint16(10, 0, Endian.little); // method
      ch.setUint16(12, _dosTime, Endian.little);
      ch.setUint16(14, _dosDate, Endian.little);
      ch.setUint32(16, crcs[i], Endian.little);
      ch.setUint32(20, e.data.length, Endian.little);
      ch.setUint32(24, e.data.length, Endian.little);
      ch.setUint16(28, nameBytes.length, Endian.little);
      ch.setUint16(30, 0, Endian.little); // extra
      ch.setUint16(32, 0, Endian.little); // comment
      ch.setUint16(34, 0, Endian.little); // disk number
      ch.setUint16(36, 0, Endian.little); // internal attrs
      ch.setUint32(38, 0, Endian.little); // external attrs
      ch.setUint32(42, offsets[i], Endian.little); // local header offset
      central.add(ch.buffer.asUint8List());
      central.add(nameBytes);
    }

    final centralBytes = central.toBytes();
    final centralOffset = out.length;
    out.add(centralBytes);

    // End of central directory.
    final eocd = ByteData(22);
    eocd.setUint32(0, 0x06054b50, Endian.little);
    eocd.setUint16(4, 0, Endian.little); // disk
    eocd.setUint16(6, 0, Endian.little); // central dir disk
    eocd.setUint16(8, entries.length, Endian.little);
    eocd.setUint16(10, entries.length, Endian.little);
    eocd.setUint32(12, centralBytes.length, Endian.little);
    eocd.setUint32(16, centralOffset, Endian.little);
    eocd.setUint16(20, 0, Endian.little); // comment length
    out.add(eocd.buffer.asUint8List());

    return out.toBytes();
  }

  static final Uint32List _crcTable = _makeCrcTable();

  static Uint32List _makeCrcTable() {
    final t = Uint32List(256);
    for (var n = 0; n < 256; n++) {
      var c = n;
      for (var k = 0; k < 8; k++) {
        c = (c & 1) != 0 ? 0xedb88320 ^ (c >> 1) : c >> 1;
      }
      t[n] = c;
    }
    return t;
  }

  static int _crc32(Uint8List data) {
    var crc = 0xffffffff;
    for (final b in data) {
      crc = _crcTable[(crc ^ b) & 0xff] ^ (crc >> 8);
    }
    return (crc ^ 0xffffffff) & 0xffffffff;
  }
}
