import 'package:audio_splitter_app/asp2/security/permissions.dart';
import 'package:audio_splitter_app/asp2/security/recording_consent.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AccessControl — role/capability RBAC', () {
    const ac = AccessControl();

    test('listener has only the baseline capabilities', () {
      expect(ac.can(Role.listener, Capability.listen), isTrue);
      expect(ac.can(Role.listener, Capability.react), isTrue);
      expect(ac.can(Role.listener, Capability.requestTrack), isTrue);
      // …and nothing privileged.
      expect(ac.can(Role.listener, Capability.djControl), isFalse);
      expect(ac.can(Role.listener, Capability.startRecording), isFalse);
      expect(ac.can(Role.listener, Capability.manageRoles), isFalse);
    });

    test('roles inherit every lower role capability (strict ordering)', () {
      // Each higher role is a superset of the one below it.
      for (var i = 1; i < AccessControl.order.length; i++) {
        final lower = ac.capabilitiesOf(AccessControl.order[i - 1]);
        final higher = ac.capabilitiesOf(AccessControl.order[i]);
        expect(higher.containsAll(lower), isTrue,
            reason: '${AccessControl.order[i].name} must include '
                '${AccessControl.order[i - 1].name}');
        expect(higher.length, greaterThan(lower.length));
      }
    });

    test('dj can drive decks/zones but cannot moderate or record', () {
      expect(ac.can(Role.dj, Capability.djControl), isTrue);
      expect(ac.can(Role.dj, Capability.manageZones), isTrue);
      expect(ac.can(Role.dj, Capability.kickClient), isFalse);
      expect(ac.can(Role.dj, Capability.startRecording), isFalse);
    });

    test('moderator can record + kick; only admin manages roles', () {
      expect(ac.can(Role.moderator, Capability.startRecording), isTrue);
      expect(ac.can(Role.moderator, Capability.kickClient), isTrue);
      expect(ac.can(Role.moderator, Capability.manageRoles), isFalse);
      expect(ac.can(Role.admin, Capability.manageRoles), isTrue);
    });

    test('admin holds every capability', () {
      final admin = ac.capabilitiesOf(Role.admin);
      expect(admin, containsAll(Capability.values));
    });

    test('require() throws PermissionDenied for a forbidden action', () {
      expect(() => ac.require(Role.listener, Capability.startRecording),
          throwsA(isA<PermissionDenied>()));
      // …and is silent when allowed.
      expect(() => ac.require(Role.admin, Capability.startRecording),
          returnsNormally);
    });
  });

  group('RecordingConsent — all-party gate', () {
    test('no participants → cannot record (nothing to capture)', () {
      final c = RecordingConsent();
      expect(c.canStartRecording, isFalse);
    });

    test('a present-but-unanswered participant blocks recording', () {
      final c = RecordingConsent()..join('a');
      expect(c.canStartRecording, isFalse);
      expect(c.blockers, ['a']);
    });

    test('recording arms only once everyone present has granted', () {
      final c = RecordingConsent()
        ..join('a')
        ..join('b');
      c.setConsent('a', true);
      expect(c.canStartRecording, isFalse); // b still unknown
      c.setConsent('b', true);
      expect(c.canStartRecording, isTrue);
      expect(c.blockers, isEmpty);
    });

    test('a denial immediately gates recording back off', () {
      final c = RecordingConsent()
        ..join('a')
        ..join('b');
      c.setConsent('a', true);
      c.setConsent('b', true);
      expect(c.canStartRecording, isTrue);
      c.setConsent('b', false);
      expect(c.canStartRecording, isFalse);
      expect(c.blockers, ['b']);
    });

    test('a new un-consented joiner gates an in-progress recording off', () {
      final c = RecordingConsent()..join('a');
      c.setConsent('a', true);
      expect(c.canStartRecording, isTrue);
      c.join('late'); // someone walks in mid-session
      expect(c.canStartRecording, isFalse);
      expect(c.blockers, ['late']);
    });

    test('leaving drops a blocker from the tally', () {
      final c = RecordingConsent()
        ..join('a')
        ..join('b');
      c.setConsent('a', true);
      expect(c.canStartRecording, isFalse); // b blocks
      c.leave('b');
      expect(c.canStartRecording, isTrue); // only a remains, and a granted
    });

    test('re-join keeps a prior answer (network blip is not a reset)', () {
      final c = RecordingConsent()..join('a');
      c.setConsent('a', true);
      c.join('a'); // idempotent
      expect(c.stateOf('a'), ConsentState.granted);
    });
  });
}
