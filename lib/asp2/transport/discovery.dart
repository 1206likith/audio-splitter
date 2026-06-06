/// Dual-stack discovery — Phase 4 of the v2 plan.
///
/// v1 found hosts two ways: an mDNS browse and a brute-force IPv4 subnet scan
/// (see `WsTransport.scanSubnet`). Phase 4 generalizes discovery to **dual-stack
/// IPv4 + IPv6** so the app works on IPv6-only and mixed networks, while keeping
/// the IPv4 subnet scan as a last-resort fallback.
///
/// This file is the **pure, testable** half of discovery: the service identity
/// constants, the address-family model, and the [HostDescriptor] that a host
/// advertises and a client resolves — with the dual-stack **endpoint preference
/// order** (IPv6 first, then IPv4) that a client should dial. The actual mDNS
/// socket (binding the multicast groups, sending/parsing DNS-SD records) is
/// platform I/O and is deferred to the on-device path, same discipline as the
/// rest of Phase 4; it consumes exactly the model defined here.
library;

/// DNS-SD service type the app advertises/browses (`_asplitter._tcp`).
const String kServiceType = '_asplitter._tcp';

/// Link-local multicast group + port for **IPv6** mDNS (RFC 6762).
const String kMdnsIPv6Group = 'ff02::fb';

/// Link-local multicast group for **IPv4** mDNS (RFC 6762).
const String kMdnsIPv4Group = '224.0.0.251';

/// Standard mDNS port.
const int kMdnsPort = 5353;

/// Default ASP-2 host service port (kept from v1's WebSocket default).
const int kDefaultHostPort = 8080;

/// Which IP stack an [HostEndpoint] belongs to.
enum AddressFamily {
  ipv4,
  ipv6;

  String get label => this == AddressFamily.ipv4 ? 'IPv4' : 'IPv6';
}

/// One reachable network address for a host, tagged with its family so the
/// client can apply the dual-stack preference order.
class HostEndpoint {
  final String address;
  final AddressFamily family;

  const HostEndpoint(this.address, this.family);

  /// Infer the family from the textual form (a `:` means IPv6). Convenience for
  /// callers that only have the address string.
  factory HostEndpoint.infer(String address) => HostEndpoint(
        address,
        address.contains(':') ? AddressFamily.ipv6 : AddressFamily.ipv4,
      );

  Map<String, dynamic> toJson() => {'address': address, 'family': family.name};

  factory HostEndpoint.fromJson(Map<String, dynamic> json) => HostEndpoint(
        json['address'] as String,
        AddressFamily.values.byName(json['family'] as String),
      );

  @override
  bool operator ==(Object other) =>
      other is HostEndpoint &&
      other.address == address &&
      other.family == family;

  @override
  int get hashCode => Object.hash(address, family);

  @override
  String toString() => '${family.label}($address)';
}

/// Everything a client needs to dial a discovered host: identity, every
/// reachable endpoint (across both stacks), the service port, the protocol
/// version, and a capability set (so a client can tell which Phase-4 transports
/// a host offers before connecting).
class HostDescriptor {
  final String id;
  final String name;
  final List<HostEndpoint> endpoints;
  final int port;
  final int protocolVersion;

  /// Free-form capability tags a host advertises, e.g. `ws`, `quic`, `webrtc`,
  /// `mesh`, `hls`, `asp2`. Lets a client negotiate the best shared transport.
  final Set<String> capabilities;

  const HostDescriptor({
    required this.id,
    required this.name,
    required this.endpoints,
    this.port = kDefaultHostPort,
    this.protocolVersion = 2,
    this.capabilities = const {},
  });

  /// Endpoints in **dial preference order: IPv6 first, then IPv4**. Within a
  /// family the advertised order is preserved. This is the dual-stack policy —
  /// prefer the modern stack, fall back to IPv4.
  List<HostEndpoint> get preferredEndpoints {
    final v6 = endpoints.where((e) => e.family == AddressFamily.ipv6);
    final v4 = endpoints.where((e) => e.family == AddressFamily.ipv4);
    return [...v6, ...v4];
  }

  /// True when the host advertised at least one IPv6 endpoint (i.e. the
  /// IPv4-subnet-scan fallback is not the only way to reach it).
  bool get hasIPv6 => endpoints.any((e) => e.family == AddressFamily.ipv6);

  bool supports(String capability) => capabilities.contains(capability);

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'endpoints': [for (final e in endpoints) e.toJson()],
        'port': port,
        'protocolVersion': protocolVersion,
        'capabilities': capabilities.toList(),
      };

  factory HostDescriptor.fromJson(Map<String, dynamic> json) => HostDescriptor(
        id: json['id'] as String,
        name: json['name'] as String,
        endpoints: [
          for (final e in (json['endpoints'] as List))
            HostEndpoint.fromJson((e as Map).cast<String, dynamic>()),
        ],
        port: (json['port'] as num?)?.toInt() ?? kDefaultHostPort,
        protocolVersion: (json['protocolVersion'] as num?)?.toInt() ?? 2,
        capabilities: {
          for (final c in (json['capabilities'] as List? ?? const []))
            c as String,
        },
      );

  @override
  String toString() =>
      'HostDescriptor($name#$id, ${endpoints.length} endpoints, '
      'caps=${capabilities.join(",")})';
}
