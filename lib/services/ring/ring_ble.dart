import 'dart:io';

import 'package:flutter/services.dart';

/// The ring's BLE link — Android's own GATT API behind `RingBleChannel.kt`.
///
/// Bytes only. Framing and every reply layout live in `ring_protocol.dart`.
///
/// Events arrive as maps with a `type`:
///
/// | type        | fields                                              |
/// |-------------|-----------------------------------------------------|
/// | `scanState` | `scanning`                                          |
/// | `scan`      | `id`, `name`, `rssi`, `has56ff`                     |
/// | `state`     | `state` (`connected`/`disconnected`), `status`      |
/// | `mtu`       | `mtu`, `status`                                     |
/// | `services`  | `services` [{uuid, chars:[{uuid, props}]}], `cmd`, `notify`, `battery` |
/// | `ready`     | `mtu`, `cmd` — notifications are on, commands can go |
/// | `notify`    | `char` (`33f4`/`2a19`), `value` (bytes)             |
/// | `read`      | `char`, `value`                                     |
/// | `error`     | `message`                                           |
class RingBle {
  RingBle._();

  static const _method = MethodChannel('ai.fox1/ring_ble');
  static const _events = EventChannel('ai.fox1/ring_ble/events');

  /// One stream for the life of the app. Each `receiveBroadcastStream()` call
  /// makes a new stream over the same native sink, and cancelling any one of
  /// them cancels the sink under the others — the "No active stream to
  /// cancel" crash PhoneRingService already hit.
  static final Stream<Map<String, dynamic>> events = _events
      .receiveBroadcastStream()
      .map((e) => (e as Map).map((k, v) => MapEntry(k.toString(), v)));

  /// Paired and system-connected devices, before any scan.
  static Future<List<Map<String, dynamic>>> known() async {
    final list = await _method.invokeListMethod<Map>('known') ?? const [];
    return [for (final m in list) m.map((k, v) => MapEntry(k.toString(), v))];
  }

  static Future<bool> startScan({int seconds = 10}) async =>
      await _method.invokeMethod<bool>('startScan', {'seconds': seconds}) ??
      false;

  static Future<void> stopScan() => _method.invokeMethod('stopScan');

  /// Starts connecting; progress arrives as events, ending in `ready`.
  static Future<bool> connect(String id) async =>
      await _method.invokeMethod<bool>('connect', {'id': id}) ?? false;

  /// Queues a write to `33F3`. False when there is no link to write to.
  static Future<bool> write(List<int> bytes) async =>
      await _method.invokeMethod<bool>(
          'write', {'data': Uint8List.fromList(bytes)}) ??
      false;

  static Future<void> disconnect() => _method.invokeMethod('disconnect');

  static Future<bool> isConnected() async =>
      await _method.invokeMethod<bool>('isConnected') ?? false;

  /// Bare Opus packets → PCM16 mono, via the platform's own decoder.
  static Future<({Uint8List pcm, int rate, String decoder, int decodedRate})>
      decodeOpus(Uint8List frames, {int frameBytes = 40}) async {
    final r = await _method.invokeMapMethod<String, dynamic>(
        'decodeOpus', {'frames': frames, 'frameBytes': frameBytes});
    if (r == null) throw StateError('decoder returned nothing');
    return (
      pcm: r['pcm'] as Uint8List,
      rate: r['rate'] as int,
      decoder: r['decoder']?.toString() ?? '?',
      decodedRate: r['decodedRate'] as int,
    );
  }

  /// Health history — internal storage, private to the app.
  static Future<Directory?> healthDir() async {
    final p = await _method.invokeMethod<String>('healthDir');
    return p == null ? null : Directory(p);
  }

  /// RingLinkService: keeps the process up while a ring is paired, with
  /// [text] in the notification. Calling again updates the text.
  static Future<void> keepAlive({required bool on, String text = ''}) =>
      _method.invokeMethod('keepAlive', {'on': on, 'text': text});

  /// Where pulled recordings are kept — the app's external files dir, so they
  /// are reachable over `adb pull` as well as the web server.
  static Future<Directory?> recordingsDir() async {
    final p = await _method.invokeMethod<String>('recordingsDir');
    return p == null ? null : Directory(p);
  }

  /// Saved recordings, newest first.
  static Future<List<File>> recordings() async {
    final dir = await recordingsDir();
    if (dir == null || !await dir.exists()) return const [];
    final files = <File>[
      await for (final e in dir.list())
        if (e is File) e,
    ];
    files.sort((a, b) => b.path.compareTo(a.path));
    return files;
  }
}
