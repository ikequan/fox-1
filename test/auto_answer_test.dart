import 'package:flutter_test/flutter_test.dart';

import 'package:fox1/services/call/auto_answer.dart';
import 'package:fox1/services/call/call_history.dart';

/// Whether the device picks up someone else's call. Every wrong answer here is
/// the device taking a call it had no business taking, so the rules are tested
/// rather than read.
void main() {
  const known = '0200000001';
  const stranger = '0209999999';

  group('off by default', () {
    test('an untouched policy answers nothing', () {
      const p = AutoAnswerPolicy();
      expect(p.mode, AutoAnswerMode.off);
      expect(p.decide(known, onFile: true), AnswerDecision.ring);
      expect(p.decide(stranger, onFile: false), AnswerDecision.ring);
    });

    test('it always rings for a beat first', () {
      // Instant pickup denies the wearer their own call.
      expect(const AutoAnswerPolicy().ringFirst.inSeconds, greaterThan(0));
    });
  });

  group('known-only', () {
    const p = AutoAnswerPolicy(mode: AutoAnswerMode.known);

    test('answers someone on file', () {
      expect(p.decide(known, onFile: true), AnswerDecision.answer);
    });

    test('rings through for a stranger', () {
      expect(p.decide(stranger, onFile: false), AnswerDecision.ring);
    });

    test('matches a number through a different format', () {
      const withAlways =
          AutoAnswerPolicy(mode: AutoAnswerMode.known, always: {'+233200000001'});
      expect(withAlways.decide('0200000001', onFile: false),
          AnswerDecision.answer);
    });
  });

  group('everyone', () {
    const p = AutoAnswerPolicy(mode: AutoAnswerMode.everyone);

    test('answers a stranger', () {
      expect(p.decide(stranger, onFile: false), AnswerDecision.answer);
    });

    test('still rings through a withheld number', () {
      // Nothing to file the conversation against, and they chose not to say
      // who they are.
      expect(p.decide('', onFile: false), AnswerDecision.ring);
    });
  });

  group('blocking wins', () {
    test('over everyone', () {
      const p = AutoAnswerPolicy(
          mode: AutoAnswerMode.everyone, blocked: {stranger});
      expect(p.decide(stranger, onFile: false), AnswerDecision.ignore);
    });

    test('over the always list, which is the whole point of a block list', () {
      const p = AutoAnswerPolicy(
        mode: AutoAnswerMode.everyone,
        blocked: {known},
        always: {known},
      );
      expect(p.decide(known, onFile: true), AnswerDecision.ignore);
    });

    test('even when auto-answer is off, so the agent stays away from it', () {
      const p = AutoAnswerPolicy(blocked: {known});
      expect(p.decide(known, onFile: true), AnswerDecision.ignore);
    });
  });

  group('parseList', () {
    test('splits on commas, newlines and semicolons, trimming', () {
      final l = AutoAnswerPolicy.parseList(' 0200000004 , 0209999999\n0200000003; ');
      expect(l.length, 3);
      expect(l, contains('0209999999'));
    });

    test('an empty field blocks nothing', () {
      expect(AutoAnswerPolicy.parseList('  \n , ; '), isEmpty);
    });
  });

  group('the first ring has no caller ID', () {
    test('an empty number is not decided on yet', () {
      // The board reports ringing a millisecond before the CALLER-ID frame.
      // Deciding on that first emission logged "not answering an unknown
      // number" immediately before the real decision for the same call.
      final c = AutoAnswerController(history: CallHistory());
      c.onRinging('', const AutoAnswerPolicy(mode: AutoAnswerMode.everyone));
      expect(c.isPending, isFalse);
      c.onRinging('0200000001',
          const AutoAnswerPolicy(mode: AutoAnswerMode.everyone));
      expect(c.isPending, isTrue);
      c.dispose();
    });

    test('answering is cancelled when someone else picks up', () {
      final c = AutoAnswerController(history: CallHistory());
      c.onRinging('0200000001',
          const AutoAnswerPolicy(mode: AutoAnswerMode.everyone));
      expect(c.isPending, isTrue);
      c.cancel('the call was answered');
      expect(c.isPending, isFalse);
    });
  });
}
