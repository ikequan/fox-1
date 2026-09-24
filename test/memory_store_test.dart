import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fox1/providers/providers.dart';

import 'package:fox1/services/agent/call_tools_bridge.dart';
import 'package:fox1/services/call/call_history.dart';
import 'package:fox1/services/call/call_report.dart';
import 'package:fox1/services/call/dialed_numbers.dart';
import 'package:fox1/services/memory/memory_store.dart';

/// The trust boundary. Everything else in the store is bookkeeping; these are
/// the properties that stop a caller writing to the wearer's memory just by
/// talking, or reading it just by asking.
void main() {
  group('trust', () {
    test('a claim never renders as a fact', () async {
      final m = MemoryStore();
      await m.claim('he already paid the deposit',
          about: '0200000001', source: 'the caller on 0200000001');
      final out = MemoryStore.render(m.recall('deposit'));
      expect(out, contains('UNVERIFIED CLAIM'));
      expect(out, contains('not a fact'));
      expect(out, contains('the caller on 0200000001'));
    });

    test('every claim is labelled on its own line, not once at the top',
        () async {
      final m = MemoryStore();
      for (final c in ['claim one', 'claim two', 'claim three']) {
        await m.claim(c, about: '0200000001');
      }
      final out = MemoryStore.render(m.recall(''));
      // A model summarising a mixed list carries the heading away and keeps
      // the sentences, so the marking has to survive per line.
      expect('UNVERIFIED CLAIM'.allMatches(out).length, 3);
    });

    test('a promoted claim keeps its origin in the record', () async {
      final m = MemoryStore();
      final f = await m.claim('is my brother', about: '0200000001');
      expect(await m.resolve(f.id, keep: true), isTrue);
      final out = MemoryStore.render(m.recall('brother'));
      expect(out, isNot(contains('UNVERIFIED')));
      expect(m.pendingClaims(), isEmpty);
    });

    test('a discarded claim is gone, not merely hidden', () async {
      final m = MemoryStore();
      final f = await m.claim('owed money', about: '0200000001');
      expect(await m.resolve(f.id, keep: false), isTrue);
      expect(m.recall('owed'), isEmpty);
      expect(m.count, 0);
    });

    test('an unreadable trust value fails closed, to a claim', () {
      final f = Fact.fromJson({
        'id': 'f1',
        'text': 'something',
        'trust': 'nonsense',
        'source': 'x',
        'at': DateTime.now().toIso8601String(),
      });
      expect(f.trust, Trust.claimed);
    });
  });

  group('scoping — what the call agent may read', () {
    Future<MemoryStore> populated() async {
      final m = MemoryStore();
      await m.remember('the deposit was never paid', about: '0200000001');
      await m.remember('flying to Accra on Tuesday');
      await m.remember('owes the landlord rent', about: '0209999999');
      return m;
    }

    test('onlySubject hides everything about anyone else', () async {
      final m = await populated();
      final hits = m.recall('', about: '0200000001', onlySubject: true);
      expect(hits.length, 1);
      expect(hits.single.text, contains('deposit'));
    });

    test('a query that only matches a general note still leaks nothing',
        () async {
      final m = await populated();
      // The question a caller would ask to fish. Being about the current
      // caller scores on its own, so their own file still comes back — that is
      // fine and intended. What must never appear is anything else.
      final hits = m.recall('Accra Tuesday flying',
          about: '0200000001', onlySubject: true);
      expect(hits.every((f) => f.subject == CallHistory.keyFor('0200000001')),
          isTrue);
      expect(MemoryStore.render(hits), isNot(contains('Accra')));
      expect(MemoryStore.render(hits), isNot(contains('landlord')));
    });

    test('an unknown caller can reach nothing at all', () async {
      final m = await populated();
      expect(m.recall('deposit', about: '', onlySubject: true), isEmpty);
    });

    test('the main agent, unscoped, sees all of it', () async {
      final m = await populated();
      expect(m.recall('deposit').length, 1);
      expect(m.recall('Accra').length, 1);
      expect(m.recall('rent').length, 1);
    });
  });

  group('CallToolsBridge', () {
    test('has no way to write a fact', () {
      final b = CallToolsBridge();
      final names =
          b.toolDeclarations.map((d) => d['name'] as String).toSet();
      for (final forbidden in [
        'remember',
        'review_claims',
        'resolve_claim',
        'execute',
      ]) {
        expect(names, isNot(contains(forbidden)),
            reason: '$forbidden must not exist on a call');
      }
      expect(names, contains('recall'));
    });

    test('recall is refused outright when the caller is unknown', () async {
      final m = MemoryStore();
      await m.remember('something private');
      final b = CallToolsBridge(memory: m); // callerNumber left empty
      final r = await b.handleToolCall('recall', {'query': 'something'});
      expect(r['result'], contains('Nothing on file'));
      expect('$r', isNot(contains('private')));
    });

    test('recall cannot reach past the caller on the line', () async {
      final m = MemoryStore();
      await m.remember('the wearer is away all week');
      await m.remember('this one is about them', about: '0200000001');
      final b = CallToolsBridge(memory: m, callerNumber: '0200000001');
      final r = await b.handleToolCall('recall', {'query': 'wearer away week'});
      expect('$r', isNot(contains('away all week')));
    });

    test('take_message lands in quarantine, attributed', () async {
      final m = MemoryStore();
      final b = CallToolsBridge(memory: m, callerNumber: '0200000001');
      await b.handleToolCall('take_message', {'message': 'I paid already'});
      final pending = m.pendingClaims();
      expect(pending.length, 1);
      expect(pending.single.trust, Trust.claimed);
      expect(pending.single.source, contains('0200000001'));
    });

    test('claims survive a call with no caller ID', () async {
      // An outgoing call, or a withheld number. One such call ran 195 seconds
      // and every word of it was discarded.
      final m = MemoryStore();
      final b = CallToolsBridge(memory: m); // no callerNumber
      await m.claim('says he is visiting on Friday',
          about: '', source: 'an unidentified caller');
      expect(m.pendingClaims().length, 1);
      expect(m.pendingClaims().single.source, contains('unidentified'));
      // ...but they must not become readable by some later named caller.
      expect(m.recall('visiting', about: '0200000001', onlySubject: true),
          isEmpty);
      expect(b.callerNumber, '');
    });

    test('a second end_call is refused rather than starting another hang-up',
        () async {
      var calls = 0;
      final b = CallToolsBridge(
        callerNumber: '0200000001',
        onEndCall: (_) async => calls++,
      );
      await b.handleToolCall('end_call', {'reason': 'done'});
      await b.handleToolCall('end_call', {'reason': 'done again'});
      await b.handleToolCall('end_call', {'reason': 'and again'});
      expect(calls, 1);
      // A new call gets a fresh chance to hang up.
      b.callerNumber = '0209999999';
      await b.handleToolCall('end_call', {'reason': 'next call'});
      expect(calls, 2);
    });

    test('a tool that is not on the list is refused, not dispatched', () async {
      final b = CallToolsBridge();
      final r = await b.handleToolCall('launch_app', {'name': 'YouTube'});
      expect(r['success'], isFalse);
    });
  });

  group('one store, not two', () {
    test('both agents get the same instance', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      // The regression: AISessionManager built its own MemoryStore, so claims
      // the call agent filed during a call were invisible to review_claims,
      // and the two lists overwrote each other's file on save.
      expect(identical(c.read(memoryStoreProvider), c.read(memoryStoreProvider)),
          isTrue);
      expect(
          identical(c.read(callHistoryProvider), c.read(callHistoryProvider)),
          isTrue);
    });

    test('a claim filed by one reader is visible to the other', () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final callSide = c.read(memoryStoreProvider);
      await callSide.claim('said he already paid', about: '0200000001');
      final mainSide = c.read(memoryStoreProvider);
      expect(mainSide.pendingClaims().length, 1);
    });
  });

  group('outgoing calls have a number too', () {
    test('a number we just dialled names the call', () {
      final d = DialedNumbers();
      d.note('0200000003');
      expect(d.recent(), '0200000003');
    });

    test('a stale number does not label an unrelated call', () {
      final d = DialedNumbers();
      d.note('0200000003');
      // Filing a conversation under the wrong person is worse than filing it
      // under nobody, and much harder to notice.
      expect(d.recent(within: Duration.zero), '');
    });

    test('nothing dialled means nothing claimed', () {
      expect(DialedNumbers().recent(), '');
      DialedNumbers().note('   ');
      expect(DialedNumbers().recent(), '');
    });

    test('an outbound call files under the number, so the callback is briefed',
        () async {
      // The printing-press loop: we ring them, they promise a callback, they
      // ring in, and the agent has to already know why.
      final h = CallHistory();
      await h.record(const CallReport(
        number: '0200000003',
        durationS: 90,
        summary: 'Asked for an update on the printing job.',
        commitments: [],
        callbackRequested: true,
      ));
      final brief = h.briefing('0200000003');
      expect(brief, contains('printing job'));
      expect(brief, contains('asked to be called back'));
    });
  });

  group('repetition does not accumulate', () {
    test('a re-asserted claim does not demote a confirmed fact', () async {
      final m = MemoryStore();
      final f = await m.claim('the caller is Alex\'s brother',
          about: '0200000001');
      await m.resolve(f.id, keep: true);
      // The same caller says it again on the next call, as they will.
      await m.claim("the caller is Alex's brother", about: '0200000001');
      expect(m.pendingClaims(), isEmpty);
      expect(m.count, 1);
      expect(MemoryStore.render(m.recall('brother')),
          isNot(contains('UNVERIFIED')));
    });

    test('the same claim about a different person is still new', () async {
      final m = MemoryStore();
      await m.claim('is his brother', about: '0200000001');
      await m.claim('is his brother', about: '0209999999');
      expect(m.count, 2);
    });

    test('a late report replaces the placeholder, it does not add a call',
        () async {
      final h = CallHistory();
      final started = DateTime.now().subtract(const Duration(seconds: 75));
      // The model was slow, so the "unavailable" placeholder was filed first.
      await h.record(CallReport.unavailable(
          number: '0200000001', startedAt: started, durationS: 75));
      // ...and the real summary arrived 14 seconds later.
      await h.record(CallReport(
        number: '0200000001',
        startedAt: started,
        durationS: 75,
        summary: 'Asked whether I remembered them.',
      ));
      expect(h.threadFor('0200000001')!.calls.length, 1);
      expect(h.briefing('0200000001'), contains('remembered them'));
      expect(h.briefing('0200000001'),
          isNot(contains('before a summary could be produced')));
    });
  });
}
