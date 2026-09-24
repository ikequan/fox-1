import 'package:flutter_test/flutter_test.dart';

import 'package:fox1/services/call/crash_journal.dart';

/// What happens when the process dies mid-call. The decision is separated from
/// the doing precisely so it can be tested here: getting it wrong means either
/// abandoning a caller who is still on the line, or seizing a call that has
/// nothing to do with us.
void main() {
  CrashSnapshot snap({Duration age = Duration.zero, String number = '0200000001'}) =>
      CrashSnapshot(
        number: number,
        startedAt: DateTime.now().subtract(age + const Duration(seconds: 30)),
        writtenAt: DateTime.now().subtract(age),
        deviceAddress: '34:5F:45:04:FB:1E',
      );

  group('decide', () {
    test('nothing journalled means nothing to do', () {
      expect(CrashJournal.decide(null, callLive: true), Recovery.nothing);
      expect(CrashJournal.decide(null, callLive: false), Recovery.nothing);
    });

    test('a live call is re-adopted', () {
      expect(CrashJournal.decide(snap(), callLive: true), Recovery.readopt);
    });

    test('a finished call is filed rather than lost', () {
      expect(CrashJournal.decide(snap(), callLive: false), Recovery.fileOnly);
    });

    test('a stale snapshot is discarded even when a call is up', () {
      // Otherwise an unrelated call the wearer is having right now gets seized
      // on the strength of a journal entry nobody cleared.
      final old = snap(age: const Duration(minutes: 30));
      expect(old.isFresh, isFalse);
      expect(CrashJournal.decide(old, callLive: true), Recovery.nothing);
    });

    test('a restart-sized gap is still fresh', () {
      // A kill-and-relaunch takes seconds, and the whole point is to be back
      // before the caller gives up.
      expect(snap(age: const Duration(seconds: 20)).isFresh, isTrue);
    });
  });

  group('snapshot', () {
    test('survives a round trip through the file format', () {
      final a = CrashSnapshot(
        number: '0200000001',
        startedAt: DateTime.parse('2026-08-28T22:45:04Z'),
        writtenAt: DateTime.parse('2026-08-28T22:45:14Z'),
        resumeHandle: 'db14f67f-a20f-4797-b5a0-1060c4e77e74',
        deviceAddress: '34:5F:45:04:FB:1E',
        stage: 7,
      );
      final b = CrashSnapshot.fromJson(a.toJson());
      expect(b.number, a.number);
      expect(b.startedAt, a.startedAt);
      // The handle is what turns a re-adoption into a continued conversation
      // rather than a stranger picking up halfway through.
      expect(b.resumeHandle, a.resumeHandle);
      expect(b.deviceAddress, a.deviceAddress);
      expect(b.stage, 7);
    });

    test('a corrupt entry does not throw', () {
      final b = CrashSnapshot.fromJson({'number': '024', 'startedAt': 'junk'});
      expect(b.number, '024');
      expect(b.resumeHandle, '');
      expect(b.stage, 7);
    });

    test('duration is measured from the start, not the last write', () {
      final s = CrashSnapshot(
        number: '024',
        startedAt: DateTime.now().subtract(const Duration(seconds: 90)),
        writtenAt: DateTime.now(),
      );
      expect(s.durationS, greaterThanOrEqualTo(89));
    });
  });
}
