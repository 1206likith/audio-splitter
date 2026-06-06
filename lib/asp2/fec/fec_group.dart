import 'dart:typed_data';

import 'reed_solomon.dart';

/// Result of FEC-encoding one group of media payloads.
class FecEncodeResult {
  /// The group id stamped into each frame's `fec_group_id` header byte (1..255).
  final int groupId;

  /// The padded shard length the parity was computed over. The receiver needs
  /// this to repad surviving data shards before a solve; it equals the byte
  /// length of every parity payload, so it can also be read off any parity frame.
  final int shardLen;

  /// One payload per parity shard. Parity shard `p` travels in a frame with
  /// `fec_index = dataShards + p` and the parity flag set.
  final List<Uint8List> parityPayloads;

  const FecEncodeResult({
    required this.groupId,
    required this.shardLen,
    required this.parityPayloads,
  });
}

/// FEC grouping for ASP-2: turns `k` media payloads into `m` parity payloads so
/// the receiver can rebuild up to `m` lost packets without a retransmit.
///
/// Real Opus/PCM payloads vary in length, but Reed-Solomon needs equal-length
/// shards. Each payload is therefore packed as `[uint16 len][payload][zero pad]`
/// out to the group's max length *before* parity is computed — so the original
/// length rides inside the FEC-protected data and a recovered shard can be
/// trimmed exactly. `fec_group_id = 0` is reserved for the low-latency no-FEC
/// path and is never produced here (group ids cycle 1..255).
class FecGroup {
  /// Doc default: k=8 data shards, m=2 parity (survives a 2-of-10 = 20% loss).
  static const int defaultDataShards = 8;
  static const int defaultParityShards = 2;

  /// `fec_group_id = 0` means "this frame is not part of a FEC group".
  static const int noFecGroupId = 0;

  /// Two length-prefix bytes are prepended to each payload before padding.
  static const int _lenPrefix = 2;

  final int dataShards;
  final int parityShards;
  final ReedSolomon _rs;

  FecGroup({
    this.dataShards = defaultDataShards,
    this.parityShards = defaultParityShards,
  }) : _rs = ReedSolomon(dataShards, parityShards);

  int get totalShards => dataShards + parityShards;

  /// Pack a payload into a fixed [shardLen] shard: 2-byte LE length + bytes + pad.
  Uint8List _pack(Uint8List payload, int shardLen) {
    final out = Uint8List(shardLen);
    ByteData.view(out.buffer).setUint16(0, payload.length, Endian.little);
    out.setRange(_lenPrefix, _lenPrefix + payload.length, payload);
    return out;
  }

  /// Recover the original payload from a packed shard by reading its prefix.
  ///
  /// Returns null when the embedded length prefix overruns the shard — a
  /// corrupt or hostile peer can put any 16-bit value there, and a recovered
  /// (solved) shard whose prefix is garbage must drop the group, never throw a
  /// [RangeError] up through [recover]. (Phase 8 hardening.)
  Uint8List? _unpack(Uint8List shard) {
    if (shard.length < _lenPrefix) return null;
    final len = ByteData.view(shard.buffer, shard.offsetInBytes, shard.length)
        .getUint16(0, Endian.little);
    if (_lenPrefix + len > shard.length) return null;
    return Uint8List.fromList(shard.sublist(_lenPrefix, _lenPrefix + len));
  }

  /// FEC-encode exactly [dataShards] media [payloads] under [groupId].
  ///
  /// The data frames are still sent verbatim by the caller (systematic code);
  /// this only returns the extra parity payloads to transmit alongside them.
  FecEncodeResult encode(List<Uint8List> payloads, {required int groupId}) {
    if (payloads.length != dataShards) {
      throw ArgumentError(
          'expected $dataShards payloads, got ${payloads.length}');
    }
    if (groupId < 1 || groupId > 255) {
      throw ArgumentError('groupId must be 1..255 (0 is the no-FEC sentinel)');
    }
    var maxLen = 0;
    for (final p in payloads) {
      if (p.length + _lenPrefix > maxLen) maxLen = p.length + _lenPrefix;
      if (p.length > 0xFFFF) {
        throw ArgumentError('payload too long for a FEC shard (>65535 bytes)');
      }
    }
    final packed = [for (final p in payloads) _pack(p, maxLen)];
    final parity = _rs.encodeParity(packed);
    return FecEncodeResult(
      groupId: groupId,
      shardLen: maxLen,
      parityPayloads: parity,
    );
  }

  /// Attempt to reconstruct all [dataShards] original payloads from whatever
  /// survived the network.
  ///
  /// [dataByIndex] maps a surviving data shard's index (0..dataShards-1) to its
  /// **raw** payload (exactly as it was sent). [parityByIndex] maps a surviving
  /// parity shard's index (0..parityShards-1) to its parity payload. [shardLen]
  /// is the padded length from the encode side (read off any received parity
  /// frame, or carried in the group's control metadata).
  ///
  /// Returns the full list of [dataShards] payloads, or `null` when fewer than
  /// [dataShards] shards survived (unrecoverable — caller falls back to PLC).
  List<Uint8List>? recover({
    required Map<int, Uint8List> dataByIndex,
    required Map<int, Uint8List> parityByIndex,
    required int shardLen,
  }) {
    // Phase 8 hardening: recover() is on the receive path and is fed indices,
    // lengths, and a shardLen that all come off the wire — a corrupt or hostile
    // peer controls every one of them. An unrecoverable / malformed group must
    // return null (caller falls back to Opus PLC), never throw. Each guard
    // below closes a path that previously raised a RangeError or null-assert.

    // A shardLen smaller than the length prefix can't hold even an empty
    // payload; anything from there packs/unpacks safely.
    if (shardLen < _lenPrefix) return null;

    // Indices must address real shard slots. Out-of-range keys would otherwise
    // null-assert on the fast path or write past the shard vector below.
    for (final i in dataByIndex.keys) {
      if (i < 0 || i >= dataShards) return null;
    }
    for (final i in parityByIndex.keys) {
      if (i < 0 || i >= parityShards) return null;
    }

    final present = dataByIndex.length + parityByIndex.length;
    if (present < dataShards) return null;

    // Fast path: every data shard arrived — nothing to solve. Keys are already
    // validated to 0..dataShards-1 and there are dataShards distinct ones, so
    // every slot 0..dataShards-1 is present.
    if (dataByIndex.length == dataShards) {
      return [for (int i = 0; i < dataShards; i++) dataByIndex[i]!];
    }

    // Assemble the shard vector the RS coder expects: packed data shards in
    // slots 0..k-1, parity shards in slots k..k+m-1, null for the missing ones.
    final shards = List<Uint8List?>.filled(totalShards, null);
    for (final entry in dataByIndex.entries) {
      // A surviving data payload longer than the padded shard means a corrupt
      // shardLen/payload pairing — unrecoverable, not a crash (_pack would
      // RangeError on setRange).
      if (entry.value.length + _lenPrefix > shardLen) return null;
      shards[entry.key] = _pack(entry.value, shardLen);
    }
    for (final entry in parityByIndex.entries) {
      // Parity shards travel at exactly shardLen; a different length is
      // corruption and would desync the matrix solve.
      if (entry.value.length != shardLen) return null;
      shards[dataShards + entry.key] = entry.value;
    }

    final List<Uint8List> recoveredPacked;
    try {
      recoveredPacked = _rs.reconstructData(shards);
    } catch (_) {
      return null;
    }
    final out = <Uint8List>[];
    for (final s in recoveredPacked) {
      final unpacked = _unpack(s);
      if (unpacked == null) return null; // corrupt prefix in a recovered shard
      out.add(unpacked);
    }
    return out;
  }
}
