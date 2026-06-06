import 'dart:typed_data';

/// Galois Field GF(2^8) arithmetic for Reed-Solomon erasure coding.
///
/// Uses the standard primitive polynomial 0x11D (x^8 + x^4 + x^3 + x^2 + 1),
/// the same field klauspost/reedsolomon and the Backblaze reference use, so the
/// generated parity is interoperable with mainstream implementations. The log /
/// antilog tables are precomputed once at class-load time, making multiply a
/// table lookup rather than a carry-less multiply.
class Gf256 {
  Gf256._();

  static const int _primitive = 0x11D;

  /// antilog (exp) table, length 512 (doubled so `mul` needs no modulo).
  static final Uint8List _exp = _buildTables().$1;

  /// log table, length 256 (`_log[0]` is unused / 0).
  static final Uint8List _log = _buildTables().$2;

  static (Uint8List, Uint8List) _buildTables() {
    final exp = Uint8List(512);
    final log = Uint8List(256);
    int x = 1;
    for (int i = 0; i < 255; i++) {
      exp[i] = x;
      log[x] = i;
      x <<= 1;
      if (x & 0x100 != 0) x ^= _primitive;
    }
    // Duplicate so indices up to 510 wrap without a modulo in `mul`.
    for (int i = 255; i < 512; i++) {
      exp[i] = exp[i - 255];
    }
    return (exp, log);
  }

  /// Multiply two field elements.
  static int mul(int a, int b) {
    if (a == 0 || b == 0) return 0;
    return _exp[_log[a] + _log[b]];
  }

  /// Divide [a] by [b] (b must be non-zero).
  static int div(int a, int b) {
    if (a == 0) return 0;
    if (b == 0) throw ArgumentError('division by zero in GF(256)');
    return _exp[_log[a] + 255 - _log[b]];
  }

  /// Multiplicative inverse of [a] (a must be non-zero).
  static int inverse(int a) {
    if (a == 0) throw ArgumentError('zero has no inverse in GF(256)');
    return _exp[255 - _log[a]];
  }
}

/// A dense matrix of GF(256) elements, with just enough linear algebra for
/// Reed-Solomon: multiply, sub-matrix, and Gauss-Jordan inversion.
class Gf256Matrix {
  final int rows;
  final int cols;
  final List<Uint8List> data;

  Gf256Matrix(this.rows, this.cols)
      : data = List.generate(rows, (_) => Uint8List(cols));

  Gf256Matrix.from(this.data)
      : rows = data.length,
        cols = data.isEmpty ? 0 : data[0].length;

  /// Identity matrix of order [n].
  factory Gf256Matrix.identity(int n) {
    final m = Gf256Matrix(n, n);
    for (int i = 0; i < n; i++) {
      m.data[i][i] = 1;
    }
    return m;
  }

  /// Vandermonde matrix V[r][c] = r^c in GF(256), `rows` x `cols`.
  factory Gf256Matrix.vandermonde(int rows, int cols) {
    final m = Gf256Matrix(rows, cols);
    for (int r = 0; r < rows; r++) {
      int v = 1; // r^0
      for (int c = 0; c < cols; c++) {
        m.data[r][c] = v;
        v = Gf256.mul(v, r);
      }
    }
    return m;
  }

  Gf256Matrix multiply(Gf256Matrix other) {
    if (cols != other.rows) {
      throw ArgumentError('matrix size mismatch ${cols}x vs x${other.rows}');
    }
    final result = Gf256Matrix(rows, other.cols);
    for (int r = 0; r < rows; r++) {
      final rowR = result.data[r];
      final rowA = data[r];
      for (int c = 0; c < other.cols; c++) {
        int acc = 0;
        for (int i = 0; i < cols; i++) {
          acc ^= Gf256.mul(rowA[i], other.data[i][c]);
        }
        rowR[c] = acc;
      }
    }
    return result;
  }

  /// Rows [start, start+count) as a new matrix (deep copy).
  Gf256Matrix subMatrixRows(List<int> rowIndices) {
    final m = Gf256Matrix(rowIndices.length, cols);
    for (int i = 0; i < rowIndices.length; i++) {
      m.data[i] = Uint8List.fromList(data[rowIndices[i]]);
    }
    return m;
  }

  /// Gauss-Jordan inverse of this square matrix. Throws if singular.
  Gf256Matrix invert() {
    if (rows != cols) throw StateError('only square matrices are invertible');
    final n = rows;
    // Work on a copy augmented with the identity.
    final work = List.generate(n, (r) => Uint8List.fromList(data[r]));
    final inv = Gf256Matrix.identity(n).data;

    for (int col = 0; col < n; col++) {
      // Find a pivot row with a non-zero entry in `col`.
      int pivot = col;
      while (pivot < n && work[pivot][col] == 0) {
        pivot++;
      }
      if (pivot == n) {
        throw StateError('matrix is singular; cannot invert');
      }
      if (pivot != col) {
        final t = work[pivot];
        work[pivot] = work[col];
        work[col] = t;
        final ti = inv[pivot];
        inv[pivot] = inv[col];
        inv[col] = ti;
      }
      // Normalize the pivot row so work[col][col] == 1.
      final pv = work[col][col];
      if (pv != 1) {
        final invPv = Gf256.inverse(pv);
        for (int c = 0; c < n; c++) {
          work[col][c] = Gf256.mul(work[col][c], invPv);
          inv[col][c] = Gf256.mul(inv[col][c], invPv);
        }
      }
      // Eliminate `col` from every other row.
      for (int r = 0; r < n; r++) {
        if (r == col) continue;
        final factor = work[r][col];
        if (factor == 0) continue;
        for (int c = 0; c < n; c++) {
          work[r][c] ^= Gf256.mul(factor, work[col][c]);
          inv[r][c] ^= Gf256.mul(factor, inv[col][c]);
        }
      }
    }
    return Gf256Matrix.from(inv);
  }
}

/// Systematic Reed-Solomon erasure coder over GF(256).
///
/// Splits data into [dataShards] equal-length shards and computes [parityShards]
/// extra shards such that the originals can be recovered from **any**
/// `dataShards` of the `dataShards + parityShards` total. This is the FEC core:
/// in ASP-2, lost packets are *erasures at known positions* (the frame's
/// fec_index tells us which shard each packet is), which is the easy case —
/// recovery is a single matrix solve, never error-location search.
///
/// All shards must share one length; [FecGroup] handles the variable-length
/// padding that real Opus/PCM payloads need.
class ReedSolomon {
  final int dataShards;
  final int parityShards;
  int get totalShards => dataShards + parityShards;

  /// (data+parity) x data encoding matrix; top `dataShards` rows are identity
  /// (systematic), so encoding only computes the parity rows.
  final Gf256Matrix _matrix;

  ReedSolomon(this.dataShards, this.parityShards)
      : _matrix = _buildEncodingMatrix(dataShards, parityShards) {
    if (dataShards <= 0) throw ArgumentError('dataShards must be > 0');
    if (parityShards < 0) throw ArgumentError('parityShards must be >= 0');
    if (totalShards > 255) {
      throw ArgumentError('total shards must be <= 255 in GF(256)');
    }
  }

  /// Build a systematic encoding matrix: a (k+m) x k Vandermonde matrix
  /// transformed so its top k x k block is the identity. Multiplying the bottom
  /// m rows by the data vector yields the parity shards; any k rows of the full
  /// matrix are guaranteed invertible (Vandermonde property), which is exactly
  /// the recover-from-any-k guarantee.
  static Gf256Matrix _buildEncodingMatrix(int k, int m) {
    final total = k + m;
    final vander = Gf256Matrix.vandermonde(total, k);
    // Make systematic: multiply by the inverse of the top k x k block.
    final top = vander.subMatrixRows(List.generate(k, (i) => i));
    final topInv = top.invert();
    return vander.multiply(topInv);
  }

  /// Encode [data] shards into [parityShards] parity shards. All input shards
  /// must be the same length; returns that many parity shards of equal length.
  List<Uint8List> encodeParity(List<Uint8List> data) {
    if (data.length != dataShards) {
      throw ArgumentError(
          'expected $dataShards data shards, got ${data.length}');
    }
    final shardLen = data.isEmpty ? 0 : data[0].length;
    for (final s in data) {
      if (s.length != shardLen) {
        throw ArgumentError('all shards must be the same length');
      }
    }
    final parity = List.generate(parityShards, (_) => Uint8List(shardLen));
    // Parity rows are rows [dataShards, totalShards) of the encoding matrix.
    for (int p = 0; p < parityShards; p++) {
      final matRow = _matrix.data[dataShards + p];
      final out = parity[p];
      for (int d = 0; d < dataShards; d++) {
        final coeff = matRow[d];
        if (coeff == 0) continue;
        final src = data[d];
        for (int b = 0; b < shardLen; b++) {
          out[b] ^= Gf256.mul(coeff, src[b]);
        }
      }
    }
    return parity;
  }

  /// Reconstruct missing shards in place. [shards] holds all [totalShards]
  /// positions (data first, then parity); a `null` entry marks an erased shard.
  /// At least [dataShards] entries must be present. Returns the filled list of
  /// data shards (the first [dataShards] positions), or throws if too many are
  /// missing.
  List<Uint8List> reconstructData(List<Uint8List?> shards) {
    if (shards.length != totalShards) {
      throw ArgumentError(
          'expected $totalShards shard slots, got ${shards.length}');
    }
    // Fast path: all data shards present.
    if (!shards.sublist(0, dataShards).contains(null)) {
      return [for (int i = 0; i < dataShards; i++) shards[i]!];
    }

    // Collect the indices of the first `dataShards` present shards.
    final presentRows = <int>[];
    int shardLen = -1;
    for (int i = 0; i < totalShards && presentRows.length < dataShards; i++) {
      final s = shards[i];
      if (s != null) {
        presentRows.add(i);
        shardLen = s.length;
      }
    }
    if (presentRows.length < dataShards) {
      throw StateError(
          'not enough shards to reconstruct: have ${presentRows.length}, '
          'need $dataShards');
    }

    // Solve: decodeMatrix = (rows of encoding matrix for present shards)^-1.
    final sub = _matrix.subMatrixRows(presentRows);
    final decode = sub.invert();

    // Build the vector of present shard bytes and recover each missing data row.
    final result = List<Uint8List?>.filled(dataShards, null);
    for (int d = 0; d < dataShards; d++) {
      if (shards[d] != null) {
        result[d] = shards[d];
        continue;
      }
      final out = Uint8List(shardLen);
      final decRow = decode.data[d];
      for (int r = 0; r < dataShards; r++) {
        final coeff = decRow[r];
        if (coeff == 0) continue;
        final src = shards[presentRows[r]]!;
        for (int b = 0; b < shardLen; b++) {
          out[b] ^= Gf256.mul(coeff, src[b]);
        }
      }
      result[d] = out;
    }
    return [for (final s in result) s!];
  }
}
