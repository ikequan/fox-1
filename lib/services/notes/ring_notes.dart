import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../ring/ring_audio.dart';
import '../ring/ring_ble.dart';
import '../ring/ring_protocol.dart';
import '../ring/ring_service.dart';
import 'note_store.dart';
import 'notes_pipeline.dart';
import 'recording_puller.dart';

/// Quadruple-tap recordings, from the ring to a note — with nobody asking.
///
/// ```
/// ring: "a recording is finished" (audio state 0x40, not 0x10)
///   → RecordingPuller moves it to the device, then acks (the ring deletes it)
///   → NoteStore keeps the packets and a pending note
///   → NotesPipeline decodes and transcribes it with Gemini, retrying
/// ```
///
/// The ring reports its audio state on every connect and whenever a recording
/// stops, so recordings made out of range come over on the next connect.
class RingNotes {
  RingNotes({
    required this.ring,
    required this.store,
    required this.pipeline,
  }) {
    puller = RecordingPuller(
      send: ring.send,
      messages: ring.messages,
      audio: ring.audio,
      save: _save,
      log: _log,
    );
    // A sync and a transfer interleaved on the ring's one command channel is
    // untested ground; the sync waits for the next round instead.
    ring.transferring = () => puller.busy;
  }

  final RingService ring;
  final NoteStore store;
  final NotesPipeline pipeline;
  late final RecordingPuller puller;

  StreamSubscription? _messageSub, _linkSub;
  bool _started = false;
  bool _pullQueued = false;

  static void _log(String s) => debugPrint('[NOTES] $s');

  Future<void> start() async {
    if (_started) return;
    _started = true;
    _messageSub = ring.messages.listen(_onMessage);
    _linkSub = ring.changes.listen((_) {
      if (!ring.ready) puller.abandon();
    });
    await _importHarnessRecordings();
    unawaited(pipeline.run());
  }

  void _onMessage(RingMessage m) {
    if (m.opcode != RingOp.queryAudioState) return;
    final s = decodeRingMessage(m)?.fields['state'] as int? ?? 0;
    // 0x40: the ring holds a finished recording. 0x10: one is still being
    // made — wait for it to stop, which the ring reports too.
    if (s & 0x40 != 0 && s & 0x10 == 0) unawaited(pullSoon());
  }

  /// Moves whatever the ring holds, once the link is quiet. The first sync
  /// starts three seconds after a connect, so give it that and let it finish.
  Future<void> pullSoon() async {
    if (_pullQueued || puller.busy) return;
    _pullQueued = true;
    try {
      await Future<void>.delayed(const Duration(seconds: 5));
      for (var i = 0; i < 60 && ring.syncing; i++) {
        await Future<void>.delayed(const Duration(seconds: 2));
      }
      if (ring.ready) await puller.pullAll();
    } finally {
      _pullQueued = false;
    }
  }

  Future<bool> _save(OfflinePull p) async {
    await store.addRecording(
      id: p.baseName,
      frames: p.frames,
      recordedAt: p.recordedAt ?? p.startedAt,
      duration: p.audio,
    );
    unawaited(pipeline.run());
    return true;
  }

  /// The ring's packets → WAV, through the platform's Opus decoder.
  static Future<Uint8List> wavOf(Uint8List frames) async {
    final d = await RingBle.decodeOpus(frames);
    return wavFromPcm16(d.pcm, d.rate);
  }

  /// Recordings the Ring test screen pulled before this existed sit in the
  /// external files dir, where any app with the storage permission can read
  /// them. Move them in, so they are private and get transcribed too.
  Future<void> _importHarnessRecordings() async {
    List<File> files;
    try {
      files = await RingBle.recordings();
    } catch (e) {
      _log('could not look for older recordings: $e');
      return;
    }
    var moved = 0;
    for (final f in files) {
      if (!f.path.endsWith('.opus40')) continue;
      final id = f.uri.pathSegments.last.replaceAll('.opus40', '');
      try {
        final frames = await f.readAsBytes();
        await store.addRecording(
          id: id,
          frames: frames,
          recordedAt: recordedAtFromName(id) ?? await f.lastModified(),
          duration: Duration(
              milliseconds: frames.length ~/ ringOpusFrameBytes * ringOpusFrameMs),
        );
        await f.delete();
        final wav = File(f.path.replaceAll('.opus40', '.wav'));
        if (await wav.exists()) await wav.delete();
        moved++;
      } catch (e) {
        _log('!! could not move $id in: $e — left where it was');
      }
    }
    if (moved > 0) _log('moved $moved earlier recording(s) into the notes');
  }

  void dispose() {
    _messageSub?.cancel();
    _linkSub?.cancel();
    puller.dispose();
    pipeline.dispose();
  }
}

/// `ring_20260911_194621` → 2026-09-11 19:46:21, as OfflinePull names files.
DateTime? recordedAtFromName(String id) {
  final m = RegExp(r'(\d{4})(\d{2})(\d{2})_(\d{2})(\d{2})(\d{2})').firstMatch(id);
  if (m == null) return null;
  final v = [for (var i = 1; i <= 6; i++) int.parse(m.group(i)!)];
  return DateTime(v[0], v[1], v[2], v[3], v[4], v[5]);
}
