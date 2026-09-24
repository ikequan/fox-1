import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fox1/services/backup/backup.dart';

void main() {
  group('settings in a backup', () {
    final prefs = <String, Object?>{
      'gemini_api_key': 'AIza-test',
      'openclaw_token': 'tok',
      'gemini_voice': 'Kore',
      'watch_font_size_factor': 0.36,
      'openclaw_port': 18789,
      'call_agent_on_duty': true,
      'setup_done': true,
      'developer_mode': true,
      'ring_device': 'AA:BB',
    };

    test('keys and tokens only when asked for', () {
      final without = BackupFormat.prefsJson(prefs, includeKeys: false);
      expect(without.keys, isNot(contains('gemini_api_key')));
      expect(without.keys, isNot(contains('openclaw_token')));
      final with_ = BackupFormat.prefsJson(prefs, includeKeys: true);
      expect(with_['gemini_api_key'], {'t': 's', 'v': 'AIza-test'});
    });

    test('never this install\'s own state; the ring pairing does come across', () {
      final j = BackupFormat.prefsJson(prefs, includeKeys: true);
      expect(j.keys, isNot(contains('setup_done')));
      expect(j.keys, isNot(contains('developer_mode')));
      expect(j.keys, contains('ring_device'));
    });

    test('every type comes back as it was', () {
      final manifest = {'prefs': BackupFormat.prefsJson(prefs, includeKeys: true)};
      final back = BackupFormat.prefsFrom(jsonDecode(jsonEncode(manifest)) as Map);
      expect(back['watch_font_size_factor'], 0.36);
      expect(back['openclaw_port'], 18789);
      expect(back['openclaw_port'], isA<int>());
      expect(back['call_agent_on_duty'], true);
      expect(back['gemini_voice'], 'Kore');
    });

    test('a double that JSON wrote as a whole number is still a double', () {
      final back = BackupFormat.prefsFrom({
        'prefs': {'watch_time_x': {'t': 'd', 'v': 1}},
      });
      expect(back['watch_time_x'], isA<double>());
    });

    test('a backup cannot set setup_done, and bad entries are dropped', () {
      final back = BackupFormat.prefsFrom({
        'prefs': {
          'setup_done': {'t': 'b', 'v': true},
          'mascot': {'t': 'b', 'v': 'fox'},
          'x': 'not a map',
        },
      });
      expect(back, isEmpty);
    });
  });

  group('where a zip entry may be written', () {
    test('the wearer\'s data folders and files', () {
      expect(BackupFormat.target('internal/notes/ring_1.opus40'), (internal: true, path: 'notes/ring_1.opus40'));
      expect(BackupFormat.target('internal/health/days/2026-09-01.json')?.path, 'health/days/2026-09-01.json');
      expect(BackupFormat.target('external/memory.json'), (internal: false, path: 'memory.json'));
    });

    test('nothing else — no escape, no other files, no bare folder', () {
      for (final bad in [
        'internal/notes/../../shared_prefs/x.xml',
        '../evil',
        '/etc/passwd',
        'internal/app_flutter/x',
        'internal/notes',
        'internal/notes/',
        'external/in_flight_call.json',
        'external/session-1.log',
        'manifest.json',
        'internal\\..\\x',
      ]) {
        expect(BackupFormat.target(bad), isNull, reason: bad);
      }
    });
  });

  group('reading a backup', () {
    Archive zipWith(Object? manifest) {
      final a = Archive();
      if (manifest != null) a.addFile(ArchiveFile.string('manifest.json', jsonEncode(manifest)));
      return a;
    }

    test('ours, from FOX-1 or ClawPin', () {
      for (final app in ['fox1', 'clawpin']) {
        final m = BackupFormat.manifestOf(zipWith({'format': 'fox1-backup', 'version': 1, 'app': app}));
        expect(m.error, isNull);
        expect(m.manifest!['app'], app);
      }
    });

    test('says plainly what is wrong', () {
      expect(BackupFormat.manifestOf(zipWith(null)).error, 'This is not a FOX-1 backup');
      expect(BackupFormat.manifestOf(zipWith({'format': 'other'})).error, 'This is not a FOX-1 backup');
      expect(BackupFormat.manifestOf(zipWith({'format': 'fox1-backup', 'version': 99})).error,
          contains('newer FOX-1'));
    });

    test('survives a round trip through a real zip', () {
      final a = zipWith({'format': 'fox1-backup', 'version': 1, 'app': 'fox1'})
        ..addFile(ArchiveFile.bytes('internal/notes/n.json', utf8.encode('{}')));
      final back = ZipDecoder().decodeBytes(ZipEncoder().encodeBytes(a));
      expect(BackupFormat.manifestOf(back).error, isNull);
      expect(back.findFile('internal/notes/n.json'), isNotNull);
    });
  });

  test('the file is named for the app and the day', () {
    expect(BackupFormat.fileName('fox1', DateTime(2026, 9, 5)), 'fox1-backup-2026-09-05.zip');
  });
}
