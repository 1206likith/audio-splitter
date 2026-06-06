/// Mesh relay planning — Phase 4 of the v2 plan.
///
/// v1 fanned every frame out from the host to every client directly: the host's
/// upload scales O(N) with the audience and saturates fast (a phone hosting 30
/// listeners must upload 30× the stream). The mesh relay breaks that ceiling by
/// turning some peers into **relays**: the host serves a small set of direct
/// children, and those children re-broadcast to grandchildren, forming a
/// **spanning tree** rooted at the host.
///
/// The tree is built from a measured **RTT matrix** (the round-trip time between
/// every pair of reachable nodes, gathered on the control plane — see
/// [RttMatrix]). The objective is a low-latency tree under a hard cap on how many
/// children any node may serve (its upload-fanout budget). This is the classic
/// *degree-constrained minimum-latency spanning tree* — NP-hard to optimize
/// exactly, so we use a **greedy capacitated shortest-path-tree** heuristic
/// (Prim-like): repeatedly attach the not-yet-connected peer reachable at the
/// lowest accumulated host→peer latency, through any in-tree node that still has
/// spare fanout. Ties break deterministically (lowest latency, then node id), so
/// the same matrix always yields the same plan — no [Math.random]/wall-clock.
///
/// The planner is pure data in → pure data out; wiring an actual relay socket
/// graph onto a live transport is deferred to the on-device path (same
/// discipline as Phases 0–3). What ships here is the algorithm and its
/// guarantees, fully unit-testable.
library;

/// Conventional id of the broadcast root in an [RttMatrix] / [RelayPlan].
const String kMeshHostId = 'host';

/// A symmetric matrix of measured round-trip times (milliseconds) between nodes.
///
/// A missing pair means "no usable link" (treated as infinite cost — never a
/// candidate edge). Links are stored symmetrically by default since RTT is a
/// round trip, but [addLink] accepts an explicit value for each direction if the
/// caller has asymmetric measurements (the larger is used as the conservative
/// cost).
class RttMatrix {
  final Map<String, Map<String, double>> _rtt = {};
  final Set<String> _nodes = {};

  /// Every node that appears in any link (including [kMeshHostId]).
  Set<String> get nodes => Set.unmodifiable(_nodes);

  /// Record a bidirectional link [a]↔[b] with round-trip time [rttMs].
  ///
  /// If a link already exists, the larger RTT is kept (conservative: a relay
  /// plan should not assume the optimistic direction of an asymmetric path).
  void addLink(String a, String b, double rttMs) {
    assert(rttMs >= 0, 'rtt must be non-negative');
    assert(a != b, 'a node cannot link to itself');
    _nodes
      ..add(a)
      ..add(b);
    _put(a, b, rttMs);
    _put(b, a, rttMs);
  }

  void _put(String from, String to, double rttMs) {
    final row = _rtt.putIfAbsent(from, () => {});
    final existing = row[to];
    row[to] = existing == null ? rttMs : (rttMs > existing ? rttMs : existing);
  }

  /// Round-trip time between [a] and [b], or [double.infinity] if no link.
  double rttBetween(String a, String b) =>
      a == b ? 0 : (_rtt[a]?[b] ?? double.infinity);

  /// One-way delay estimate (half the round trip), [double.infinity] if no link.
  double owdBetween(String a, String b) {
    final rtt = rttBetween(a, b);
    return rtt.isFinite ? rtt / 2 : double.infinity;
  }

  /// True when a finite link exists between [a] and [b].
  bool hasLink(String a, String b) => rttBetween(a, b).isFinite;
}

/// The result of [MeshRelayPlanner.plan]: a relay spanning tree rooted at the
/// host, plus the per-node metrics needed to drive playout scheduling.
class RelayPlan {
  /// `node → its parent` in the tree. The host has no entry.
  final Map<String, String> parent;

  /// `node → hop count from the host` (host = 0).
  final Map<String, int> depth;

  /// `node → accumulated one-way latency from the host` (milliseconds), summed
  /// along the tree path. The host is 0.
  final Map<String, double> latencyMs;

  /// `node → its direct children`, in attachment order.
  final Map<String, List<String>> children;

  /// Peers that could not be attached (no spare fanout anywhere, or no link
  /// path) — surfaced rather than silently dropped, so the caller can fall back
  /// to a direct/SFU/HLS path for them.
  final Set<String> unreached;

  const RelayPlan({
    required this.parent,
    required this.depth,
    required this.latencyMs,
    required this.children,
    required this.unreached,
  });

  /// Number of peers the host serves directly — the metric the
  /// host-saturation gate caps.
  int get hostChildCount => children[kMeshHostId]?.length ?? 0;

  /// Deepest hop count in the tree (0 if only the host is present).
  int get maxDepth =>
      depth.values.isEmpty ? 0 : depth.values.reduce((a, b) => a > b ? a : b);

  /// Worst-case host→peer latency across the tree (milliseconds).
  double get maxLatencyMs => latencyMs.values.isEmpty
      ? 0
      : latencyMs.values.reduce((a, b) => a > b ? a : b);

  /// True when every requested peer was placed in the tree.
  bool get isComplete => unreached.isEmpty;

  /// The host→[node] path (inclusive of both ends), or `null` if unreachable.
  List<String>? pathTo(String node) {
    if (node == kMeshHostId) return [kMeshHostId];
    if (!parent.containsKey(node)) return null;
    final path = <String>[node];
    var cur = node;
    while (cur != kMeshHostId) {
      final p = parent[cur];
      if (p == null) return null; // defensive: broken chain
      path.add(p);
      cur = p;
    }
    return path.reversed.toList();
  }

  @override
  String toString() =>
      'RelayPlan(reached=${parent.length}, unreached=${unreached.length}, '
      'hostChildren=$hostChildCount, maxDepth=$maxDepth, '
      'maxLatency=${maxLatencyMs.toStringAsFixed(1)}ms)';
}

/// Builds a degree-constrained relay spanning tree from an [RttMatrix].
class MeshRelayPlanner {
  /// Maximum peers the **host** serves directly (its upload-fanout budget). The
  /// whole point of the mesh: keep this small so the host never saturates.
  final int hostFanout;

  /// Maximum children any **relay** peer serves (its upload-fanout budget).
  final int relayFanout;

  const MeshRelayPlanner({this.hostFanout = 8, this.relayFanout = 4})
      : assert(hostFanout >= 0, 'hostFanout must be non-negative'),
        assert(relayFanout >= 0, 'relayFanout must be non-negative');

  /// Plan a relay tree for [peers] (defaults to every non-host node in [matrix]).
  ///
  /// Greedy capacitated shortest-path tree: the tree starts as `{host}`; each
  /// round we attach the single unplaced peer reachable at the lowest
  /// accumulated host→peer latency through any in-tree node with spare fanout,
  /// decrement that parent's budget, and repeat until no attachable peer
  /// remains. Whatever is left is [RelayPlan.unreached].
  RelayPlan plan(RttMatrix matrix, {Iterable<String>? peers}) {
    final targets = <String>{
      ...(peers ?? matrix.nodes.where((n) => n != kMeshHostId)),
    }..remove(kMeshHostId);

    final parent = <String, String>{};
    final depth = <String, int>{kMeshHostId: 0};
    final latency = <String, double>{kMeshHostId: 0};
    final children = <String, List<String>>{kMeshHostId: []};
    final spare = <String, int>{kMeshHostId: hostFanout};

    final remaining = <String>{...targets};

    while (remaining.isNotEmpty) {
      String? bestChild;
      String? bestParent;
      var bestLatency = double.infinity;

      // Among all (in-tree parent with spare fanout) × (unplaced child) edges,
      // pick the one giving the child the lowest accumulated host latency.
      for (final p in latency.keys) {
        if ((spare[p] ?? 0) <= 0) continue;
        final pLatency = latency[p]!;
        for (final c in remaining) {
          final owd = matrix.owdBetween(p, c);
          if (!owd.isFinite) continue;
          final cand = pLatency + owd;
          if (cand < bestLatency - 1e-9 ||
              (_close(cand, bestLatency) &&
                  _better(c, p, bestChild, bestParent))) {
            bestLatency = cand;
            bestChild = c;
            bestParent = p;
          }
        }
      }

      if (bestChild == null || bestParent == null) break; // nothing attachable

      parent[bestChild] = bestParent;
      depth[bestChild] = depth[bestParent]! + 1;
      latency[bestChild] = bestLatency;
      children[bestParent]!.add(bestChild);
      children[bestChild] = [];
      spare[bestChild] = relayFanout;
      spare[bestParent] = spare[bestParent]! - 1;
      remaining.remove(bestChild);
    }

    // Trim the bookkeeping host=0 entries out of per-peer maps where helpful but
    // keep host in `children`/`depth`/`latency` (callers query hostChildCount).
    return RelayPlan(
      parent: parent,
      depth: depth,
      latencyMs: latency,
      children: children,
      unreached: remaining,
    );
  }

  static bool _close(double a, double b) => (a - b).abs() <= 1e-9;

  // Deterministic tie-break when two candidate edges yield equal latency:
  // prefer the lexicographically smaller child, then the smaller parent. This
  // makes the plan a pure function of the matrix.
  static bool _better(
      String child, String parent, String? bestChild, String? bestParent) {
    if (bestChild == null) return true;
    final byChild = child.compareTo(bestChild);
    if (byChild != 0) return byChild < 0;
    return parent.compareTo(bestParent!) < 0;
  }
}
