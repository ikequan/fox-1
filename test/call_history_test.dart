import 'package:flutter_test/flutter_test.dart';

import 'package:fox1/config/constants.dart';
import 'package:fox1/services/call/call_briefing.dart';
import 'package:fox1/services/call/call_history.dart';
import 'package:fox1/services/call/call_report.dart';

/// The parts that need no platform channel: number matching, what a briefing
/// says, and pulling an identity out of the wearer's prompt.
void main() {
  group('keyFor', () {
    test('collapses local and international forms of one number', () {
      expect(CallHistory.keyFor('0200000001'),
          CallHistory.keyFor('+233200000001'));
      expect(CallHistory.keyFor('024 575 3283'),
          CallHistory.keyFor('+233 24 575 3283'));
    });

    test('keeps different numbers apart', () {
      expect(CallHistory.keyFor('0200000001') ==
          CallHistory.keyFor('0200000002'), isFalse);
    });

    test('an unknown caller has no key, so nothing is filed under one', () {
      expect(CallHistory.keyFor(''), '');
      expect(CallHistory.keyFor('withheld'), '');
    });
  });

  group('briefing', () {
    CallHistory withCalls(List<CallEntry> calls) {
      final h = CallHistory();
      h.seed(CallerThread(
          key: CallHistory.keyFor('0200000001'),
          display: '0200000001',
          calls: calls));
      return h;
    }

    CallEntry entry({
      String summary = 'Asked about the invoice.',
      List<String> commitments = const [],
      List<String> asserted = const [],
      int minutesAgo = 60,
    }) =>
        CallEntry(
          at: DateTime.now().subtract(Duration(minutes: minutesAgo)),
          seconds: 90,
          summary: summary,
          commitments: commitments,
          callerAsserted: asserted,
        );

    test('is empty for someone who has never called', () {
      expect(withCalls([]).briefing('0555000111'), '');
    });

    test('recognises the caller through a different number format', () {
      final b = withCalls([entry()]).briefing('+233200000001');
      expect(b, contains('spoken with this caller 1 time before'));
      expect(b, contains('Asked about the invoice.'));
    });

    test('carries commitments, because the caller will ask about them', () {
      final b = withCalls([
        entry(commitments: ['call them back on Friday'])
      ]).briefing('0200000001');
      expect(b, contains('you promised them: call them back on Friday'));
    });

    test('claims stay marked as claims, on every call, forever', () {
      final b = withCalls([
        entry(asserted: ['he already paid the deposit'], minutesAgo: 6000),
        entry(minutesAgo: 30),
      ]).briefing('0200000001');
      expect(b, contains('CLAIMED'));
      expect(b, contains('they said: he already paid the deposit'));
      // The claim must not be restated anywhere as though settled.
      expect(b.split('he already paid the deposit').length - 1, 1);
    });

    test('newest first, and says how many it left out', () {
      final calls = [
        for (var i = 20; i > 0; i--)
          entry(summary: 'call number $i', minutesAgo: i * 60)
      ];
      final b = withCalls(calls).briefing('0200000001', budget: 200);
      expect(b, contains('call number 1')); // the most recent
      expect(b, contains('not shown'));
      expect(b, isNot(contains('call number 20')));
    });

    test('always shows at least one call, even past the budget', () {
      final b = withCalls([entry(summary: 'x' * 4000)])
          .briefing('0200000001', budget: 50);
      expect(b, contains('xxx'));
    });
  });

  group('composeCallPrompt', () {
    const persona = 'You are {name}, an AI assistant. You are warm and brief.';

    String compose({String profile = 'Name: Alex Mensah. A tech innovator.', String name = 'Nova'}) =>
        composeCallPrompt(
          persona: persona,
          userProfile: profile,
          callInstructions: GeminiConfig.defaultCallPrompt,
          name: name,
        );

    test('the name the wearer chose is used everywhere, never a hard-coded one', () {
      final p = compose();
      expect(p, contains('Your name is Nova.'));
      expect(p, contains('You are Nova, an AI assistant.'));
      expect(p, contains("Hello, I'm Nova,"), reason: 'the call greeting takes it too');
      expect(p, isNot(contains('{name}')));
    });

    test('no name set means FOX-1', () {
      final p = compose(name: '  ');
      expect(p, contains('Your name is FOX-1.'));
      expect(p, isNot(contains('{name}')));
    });

    test('names the assistant and the owner, and separates the caller', () {
      final p = compose();
      expect(p, contains('Nova'));
      expect(p, contains('Alex Mensah'));
      expect(p, contains('not your owner'));
    });

    test('the greeting is a natural introduction, not a switchboard', () {
      final p = compose();
      expect(p, contains("personal AI assistant"));
      expect(p, contains('FIRST NAME'));
    });

    test('never invents an owner when the profile is blank', () {
      final p = compose(profile: '   ');
      expect(p, isNot(contains('Who you answer the phone for')));
      expect(p, contains('Never invent a fact about your owner'));
    });

    test('takes no system prompt at all, so none can leak', () {
      // The signature is the guarantee: there is no parameter to pass watch
      // instructions through. If someone adds one, this test stops compiling,
      // which is the point.
      final p = compose();
      for (final watchOnly in [
        'get_screen',
        'launch_app',
        'stand_down',
        'node_id',
      ]) {
        expect(p, isNot(contains(watchOnly)),
            reason: '\$watchOnly is watch-only and must not reach a call');
      }
    });

    test('an empty persona still leaves the agent its name, and nothing guessed', () {
      final p = composeCallPrompt(
        persona: '',
        userProfile: 'Alex',
        callInstructions: GeminiConfig.defaultCallPrompt,
      );
      // It once invented an owner called "Todd" for want of an identity; a
      // name is now always given — FOX-1 until the wearer chooses one.
      expect(p, contains('[Who you are]\nYour name is FOX-1.'));
      expect(p, contains('Who you answer the phone for'));
    });

    test('wearer-edited instructions replace the defaults verbatim', () {
      final p = composeCallPrompt(
        persona: persona,
        userProfile: 'Alex',
        callInstructions: 'Answer in Twi. Say nothing else.',
      );
      expect(p, contains('Answer in Twi'));
      expect(p, isNot(contains('FIRST NAME')));
    });

    test('an emptied field falls back rather than shipping no call rules', () {
      final p = composeCallPrompt(
          persona: persona, userProfile: 'Alex', callInstructions: '  ');
      expect(p, contains('[This call]'));
    });
  });

  group('record', () {
    test('files under the caller and reads back as history', () async {
      final h = CallHistory();
      await h.record(const CallReport(
        number: '+233200000001',
        durationS: 120,
        summary: 'Booked a service for Tuesday.',
        commitments: ['confirm the time by text'],
      ));
      final b = h.briefing('0200000001');
      expect(b, contains('Booked a service for Tuesday.'));
      expect(b, contains('confirm the time by text'));
    });

    test('an unknown caller is dropped, not merged into one bucket', () async {
      final h = CallHistory();
      await h.record(const CallReport(number: '', summary: 'anonymous'));
      await h.record(const CallReport(number: '', summary: 'also anonymous'));
      expect(h.callerCount, 0);
    });
  });
}
