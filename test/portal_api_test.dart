import 'package:flutter/painting.dart' show Color;
import 'package:flutter_test/flutter_test.dart';
import 'package:fox1/services/call/call_history.dart';
import 'package:fox1/services/memory/memory_store.dart';
import 'package:fox1/services/notes/note_store.dart';
import 'package:fox1/services/web/portal_api.dart';
import 'package:fox1/watch_avatar/watch_avatar.dart';

/// The shapes docs/HUB_API.md promises the frontend.
void main() {
  final at = DateTime(2026, 9, 13, 20, 8, 16);

  test('a note: every field the list needs, and the transcript only in full', () {
    final n = Note(
      id: 'ring_20260913_200816',
      recordedAt: at,
      pulledAt: at,
      duration: const Duration(milliseconds: 21800),
      status: NoteStatus.done,
      title: 'Ring Recording Test and HR Follow-Up',
      summary: 'Testing the ring.',
      transcript: 'Testing, testing.',
      language: 'English',
      actionItems: ['Call HR to finalize the recruitment process'],
    );
    final brief = PortalApi.noteJson(n);
    expect(brief['id'], 'ring_20260913_200816');
    expect(brief['recordedAt'], '2026-09-13T20:08:16.000');
    expect(brief['duration'], 21);
    expect(brief['status'], 'done');
    expect(brief['silent'], isFalse);
    expect(brief['actionItems'], ['Call HR to finalize the recruitment process']);
    expect(brief['people'], isEmpty);
    expect(brief.containsKey('transcript'), isFalse);
    expect(PortalApi.noteJson(n, full: true)['transcript'], 'Testing, testing.');

    n.transcript = '';
    expect(PortalApi.noteJson(n)['silent'], isTrue);
  });

  test('a fact says how far it can be trusted', () {
    final f = Fact(
      id: 'f3',
      text: 'said he already paid',
      subject: '200000001',
      subjectLabel: 'Kofi',
      trust: Trust.claimed,
      source: 'a caller',
      at: at,
    );
    expect(PortalApi.factJson(f), {
      'id': 'f3',
      'text': 'said he already paid',
      'subject': '200000001',
      'subjectLabel': 'Kofi',
      'trust': 'claimed',
      'source': 'a caller',
      'at': '2026-09-13T20:08:16.000',
    });
  });

  test('a caller: calls newest first, every field present even when empty', () {
    final t = CallerThread(key: '200000001', display: '0200000001', calls: [
      CallEntry(at: at.subtract(const Duration(days: 1)), seconds: 40, summary: 'first'),
      CallEntry(
          at: at, seconds: 95, summary: 'second', callerAsserted: ['I paid'], abrupt: true),
    ]);
    final j = PortalApi.callerJson(t);
    expect(j['contactName'], isNull);
    final calls = (j['calls'] as List).cast<Map>();
    expect([for (final c in calls) c['summary']], ['second', 'first']);
    expect(calls.first['callerAsserted'], ['I paid']);
    expect(calls.first['abrupt'], isTrue);
    expect(calls.last['commitments'], isEmpty);
    expect(calls.last['callbackRequested'], isFalse);
  });

  group('the mascot design, from the portal', () {
    test('settings arrive in the web tool\'s JSON form and apply at once', () {
      final p = PortalApi.applyAvatarChanges(const AvatarParams(), {
        'body': '#ffb457',
        'eyeShape': 'round',
        'speed': 1.5,
        'clock24': false,
      });
      expect(p.body, const Color(0xFFFFB457));
      expect(p.eyeShape, EyeShape.round);
      expect(p.speed, 1.5);
      expect(p.clock24, isFalse);
    });

    test('unknown keys and empty values are skipped, not fatal', () {
      final p = PortalApi.applyAvatarChanges(const AvatarParams(), {'nope': 3, 'speed': null});
      expect(p, const AvatarParams());
    });

    test('switching character takes its colours, as the web tool does', () {
      final p = PortalApi.applyAvatarChanges(const AvatarParams(), {'character': 'fox'});
      expect(p.character, Character.fox);
      expect(p.body, AvatarParams.fox.body);
    });

    test('the page gets every setting but the character, with what it needs to draw it', () {
      final j = PortalApi.avatarSpecsJson();
      final specs = (j['specs'] as List).cast<Map>();
      expect(specs.map((s) => s['key']), isNot(contains('character')));
      expect(specs.length, kParamSpecs.length - 1);
      final speed = specs.firstWhere((s) => s['key'] == 'speed');
      expect(speed['kind'], 'number');
      expect(speed['min'], isA<double>());
      final shape = specs.firstWhere((s) => s['key'] == 'eyeShape');
      expect((shape['choices'] as List).map((c) => (c as Map)['value']), contains('round'));
      expect(specs.firstWhere((s) => s['key'] == 'clock')['help'], contains('watch face'));
      expect((j['palettes'] as List).length, kPalettes.length);
      expect((j['palettes'] as List).first, containsPair('body', startsWith('#')));
    });
  });
}
