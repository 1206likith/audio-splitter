/// Role-based access control for the ASP-2 control plane (Phase 8 security).
///
/// The plan calls for "permission roles (listener / dj / moderator / admin)".
/// Every privileged control-plane action — taking the decks, approving a track
/// request, re-routing a zone, kicking a client, starting a recording, changing
/// roles — is gated by a [Capability]. Each connected client is assigned a
/// [Role]; the host checks [AccessControl.can] (or [AccessControl.require])
/// before honouring a control message, so a plain listener cannot forge a
/// `zoneRoute` or a recording-start by sending the bytes directly.
///
/// Roles are strictly ordered — each higher role inherits every capability of
/// the roles below it — plus a few role-specific grants. This is intentionally
/// a pure, side-effect-free policy object so it is exhaustively unit-testable;
/// the host wiring (mapping a connection → role, rejecting denied messages) and
/// any operator UI sit on top of it.
library;

/// Who a client is, in increasing order of privilege.
enum Role {
  /// Default for anyone who joins: can hear audio and react.
  listener,

  /// May drive the decks / transport and shape zone routing.
  dj,

  /// May approve crowd requests, kick clients, and start recordings.
  moderator,

  /// Full control, including changing other clients' roles.
  admin,
}

/// A single gated action on the control plane.
enum Capability {
  /// Receive the audio streams (the baseline everyone has).
  listen,

  /// Send a crowd reaction (feeds the energy meter).
  react,

  /// Submit a track request to the queue.
  requestTrack,

  /// Operate the decks: play/cue/crossfade/EQ-kill (Phase 5 `dj_deck`).
  djControl,

  /// Create / edit / tear down zone routes (Phase 3 `zoneRoute`).
  manageZones,

  /// Approve or reject a pending track request.
  approveRequest,

  /// Remove a client from the session.
  kickClient,

  /// Begin a multi-stem session recording (gated again by [RecordingConsent]).
  startRecording,

  /// Reassign another client's role.
  manageRoles,
}

/// The capabilities granted *specifically* at each role (not counting what it
/// inherits from lower roles). [AccessControl.capabilitiesOf] accumulates these
/// up the [Role] order.
const Map<Role, Set<Capability>> _grants = {
  Role.listener: {
    Capability.listen,
    Capability.react,
    Capability.requestTrack,
  },
  Role.dj: {
    Capability.djControl,
    Capability.manageZones,
  },
  Role.moderator: {
    Capability.approveRequest,
    Capability.kickClient,
    Capability.startRecording,
  },
  Role.admin: {
    Capability.manageRoles,
  },
};

/// Pure policy: answers "may this [Role] perform this [Capability]?".
class AccessControl {
  const AccessControl();

  /// Roles from least to most privileged; capability inheritance walks this.
  static const List<Role> order = [
    Role.listener,
    Role.dj,
    Role.moderator,
    Role.admin,
  ];

  /// Every capability [role] holds, including those inherited from lower roles.
  Set<Capability> capabilitiesOf(Role role) {
    final caps = <Capability>{};
    for (final r in order) {
      caps.addAll(_grants[r] ?? const <Capability>{});
      if (r == role) break;
    }
    return caps;
  }

  /// Whether [role] is permitted to perform [cap].
  bool can(Role role, Capability cap) => capabilitiesOf(role).contains(cap);

  /// Enforce [cap] for [role], throwing [PermissionDenied] when not allowed.
  /// Call this at the control-plane boundary to reject forged privileged
  /// messages with a clear, loggable error instead of silently proceeding.
  void require(Role role, Capability cap) {
    if (!can(role, cap)) throw PermissionDenied(role, cap);
  }
}

/// Thrown by [AccessControl.require] when a role lacks a capability.
class PermissionDenied implements Exception {
  final Role role;
  final Capability capability;
  const PermissionDenied(this.role, this.capability);

  @override
  String toString() =>
      'PermissionDenied: role "${role.name}" cannot "${capability.name}"';
}
