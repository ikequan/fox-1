import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ring/ring_ble.dart';

/// A FOX-1 backup: one zip with everything the device knows that cannot be
/// recreated — voice notes and their recordings, health history, chats,
/// memory, call history — plus the settings. ClawPin (the app FOX-1 was
/// before) writes the same format, which is how a wearer moves across.
///
/// ```
/// manifest.json               format, version, app, createdAt, includesKeys, prefs
/// internal/health/…           day files and summaries   (app's private files dir)
/// internal/notes/…            <id>.opus40 + <id>.json
/// internal/conversations/…    <day>.jsonl
/// internal/episodes/…         <day>.json (remembered key points)
/// external/memory.json        (app's external files dir)
/// external/call_history.json
/// external/pending_reports.json
/// ```
///
/// Restoring adds the backup's notes, health days and chats to what is
/// there, and replaces memory, call history and the settings.
class BackupFormat {
  static const format = 'fox1-backup';
  static const version = 1;

  /// Folders under the app's private files dir that are the wearer's data.
  static const internalDirs = ['health', 'notes', 'conversations', 'episodes'];

  /// Files in the app's external files dir that are the wearer's data. Logs,
  /// cached audio and an in-flight call's journal are not.
  static const externalFiles = ['memory.json', 'call_history.json', 'pending_reports.json'];

  /// Only in a backup the wearer asked to include them in.
  static const secretKeys = {'gemini_api_key', 'openclaw_token', 'agent_relay_token'};

  /// Never carried across: about this install, not the wearer. Setup is
  /// worked out again from whether a key came across.
  static const deviceOnlyKeys = {'setup_done', 'developer_mode', 'accessibility_wanted'};

  /// Settings as JSON, with their types, so they come back as they were.
  static Map<String, Object?> prefsJson(Map<String, Object?> prefs, {required bool includeKeys}) => {
        for (final e in prefs.entries)
          if (!deviceOnlyKeys.contains(e.key) &&
              (includeKeys || !secretKeys.contains(e.key)) &&
              _type(e.value) != null)
            e.key: {'t': _type(e.value), 'v': e.value},
      };

  static String? _type(Object? v) => switch (v) {
        bool _ => 'b',
        int _ => 'i',
        double _ => 'd',
        String _ => 's',
        List _ => 'l',
        _ => null,
      };

  /// The settings a backup would restore, checked. Unknown types are dropped.
  static Map<String, Object> prefsFrom(Map manifest) {
    final raw = manifest['prefs'];
    if (raw is! Map) return {};
    final out = <String, Object>{};
    for (final e in raw.entries) {
      final k = '${e.key}', v = e.value;
      if (deviceOnlyKeys.contains(k) || v is! Map) continue;
      final val = v['v'];
      switch (v['t']) {
        case 'b' when val is bool:
          out[k] = val;
        case 'i' when val is num:
          out[k] = val.toInt();
        case 'd' when val is num:
          out[k] = val.toDouble();
        case 's' when val is String:
          out[k] = val;
        case 'l' when val is List:
          out[k] = [for (final x in val) '$x'];
      }
    }
    return out;
  }

  /// Where a zip entry may be written, relative to its root — or null for an
  /// entry a backup has no business holding (including any `..` escape).
  static ({bool internal, String path})? target(String name) {
    final n = name.replaceAll('\\', '/');
    if (n.startsWith('/') || n.split('/').any((p) => p == '..' || p == '.')) return null;
    if (n.startsWith('internal/')) {
      final rest = n.substring('internal/'.length);
      final top = rest.split('/').first;
      if (internalDirs.contains(top) && rest.length > top.length + 1) {
        return (internal: true, path: rest);
      }
      return null;
    }
    if (n.startsWith('external/')) {
      final rest = n.substring('external/'.length);
      return externalFiles.contains(rest) ? (internal: false, path: rest) : null;
    }
    return null;
  }

  /// Reads a backup's manifest, or says why it is not one.
  static ({Map? manifest, String? error}) manifestOf(Archive zip) {
    final f = zip.findFile('manifest.json');
    if (f == null) return (manifest: null, error: 'This is not a FOX-1 backup');
    try {
      final m = jsonDecode(utf8.decode(f.content)) as Map;
      if (m['format'] != format) return (manifest: null, error: 'This is not a FOX-1 backup');
      if ((m['version'] as num? ?? 0) > version) {
        return (manifest: null, error: 'This backup is from a newer FOX-1. Update this device first.');
      }
      return (manifest: m, error: null);
    } catch (_) {
      return (manifest: null, error: 'The backup is damaged');
    }
  }

  static String fileName(String app, DateTime at) =>
      '$app-backup-${at.year}-${_pad(at.month)}-${_pad(at.day)}.zip';
  static String _pad(int n) => n.toString().padLeft(2, '0');
}

/// Writes and restores backups on the device.
class BackupService {
  BackupService({required this.app});

  /// Written into every backup, and its file name: `fox1`.
  final String app;

  static const _dataChannel = MethodChannel('ai.fox1/call_bridge');

  Future<Directory?> _internal() async => (await RingBle.healthDir())?.parent;

  Future<Directory?> _external() async {
    final p = await _dataChannel.invokeMethod<String>('dataDir');
    return p == null ? null : Directory(p);
  }

  Future<({Uint8List bytes, String name, Map<String, int> counts})> export(
      {required bool includeKeys}) async {
    final now = DateTime.now();
    final zip = Archive();
    final counts = <String, int>{};
    final internal = await _internal();
    if (internal != null) {
      for (final top in BackupFormat.internalDirs) {
        final d = Directory('${internal.path}/$top');
        if (!await d.exists()) continue;
        await for (final e in d.list(recursive: true)) {
          // A half-written file is only ever a .tmp; the real one is next to it.
          if (e is! File || e.path.endsWith('.tmp')) continue;
          final rel = e.path.substring(internal.path.length + 1);
          zip.addFile(ArchiveFile.bytes('internal/$rel', await e.readAsBytes()));
          counts[top] = (counts[top] ?? 0) + 1;
        }
      }
    }
    final external = await _external();
    if (external != null) {
      for (final name in BackupFormat.externalFiles) {
        final f = File('${external.path}/$name');
        if (!await f.exists()) continue;
        zip.addFile(ArchiveFile.bytes('external/$name', await f.readAsBytes()));
        counts[name.split('.').first] = 1;
      }
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final all = {for (final k in prefs.getKeys()) k: prefs.get(k)};
    final manifest = {
      'format': BackupFormat.format,
      'version': BackupFormat.version,
      'app': app,
      'createdAt': now.toIso8601String(),
      'includesKeys': includeKeys,
      'counts': counts,
      'prefs': BackupFormat.prefsJson(all, includeKeys: includeKeys),
    };
    zip.addFile(ArchiveFile.string('manifest.json', jsonEncode(manifest)));
    debugPrint('[BACKUP] written: $counts${includeKeys ? ' + keys' : ''}');
    return (
      bytes: ZipEncoder().encodeBytes(zip),
      name: BackupFormat.fileName(app, now),
      counts: counts,
    );
  }

  /// Restores [bytes]. Returns what came across, or throws a [FormatException]
  /// the Hub can show as it is. The app must restart afterwards: every store
  /// holds what it loaded at start.
  Future<Map<String, Object?>> restore(Uint8List bytes) async {
    final Archive zip;
    try {
      zip = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw const FormatException('That file is not a zip backup');
    }
    final m = BackupFormat.manifestOf(zip);
    if (m.manifest == null) throw FormatException(m.error!);
    final internal = await _internal();
    final external = await _external();
    var files = 0, skipped = 0;
    for (final f in zip.files) {
      if (!f.isFile || f.name == 'manifest.json') continue;
      final t = BackupFormat.target(f.name);
      final root = t == null ? null : (t.internal ? internal : external);
      if (t == null || root == null) {
        skipped++;
        continue;
      }
      final out = File('${root.path}/${t.path}');
      await out.parent.create(recursive: true);
      // Beside the real file first, then renamed over it: never half a file.
      final tmp = File('${out.path}.restoring');
      await tmp.writeAsBytes(f.content, flush: true);
      await tmp.rename(out.path);
      files++;
    }
    final restored = BackupFormat.prefsFrom(m.manifest!);
    final prefs = await SharedPreferences.getInstance();
    for (final e in restored.entries) {
      final v = e.value;
      switch (v) {
        case bool b:
          await prefs.setBool(e.key, b);
        case int i:
          await prefs.setInt(e.key, i);
        case double d:
          await prefs.setDouble(e.key, d);
        case String s:
          await prefs.setString(e.key, s);
        case List<String> l:
          await prefs.setStringList(e.key, l);
      }
    }
    // Setup is done again only if a key came across; without one the device
    // needs setup for that alone.
    await prefs.remove('setup_done');
    final summary = {
      'from': m.manifest!['app'],
      'createdAt': m.manifest!['createdAt'],
      'files': files,
      'settings': restored.length,
      'includesKeys': m.manifest!['includesKeys'] == true,
      if (skipped > 0) 'skipped': skipped,
    };
    debugPrint('[BACKUP] restored: $summary');
    return summary;
  }
}
