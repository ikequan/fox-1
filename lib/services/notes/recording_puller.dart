import 'dart:async';

import '../ring/ring_audio.dart';
import '../ring/ring_protocol.dart';

/// Moves quadruple-tap recordings off the ring, oldest first, in LoraFit's
/// order: ask how many, take one file, put it on the device's storage,
/// THEN acknowledge its 0x36 — which deletes it from the ring — and ask for
/// the next. The acknowledgement has to follow the file at once: sent minutes
/// later, the ring ignores it and serves the same file again.
///
/// This was the Ring test screen's "Move all"; the screen is now a view onto
/// it. Everything hardware-shaped is injected, so the rules are tested without
/// a ring.
class RecordingPuller {
  RecordingPuller({
    required this.send,
    required Stream<RingMessage> messages,
    required Stream<RingFrame> audio,
    required this.save,
    this.log = _noLog,
    this.stallAfter = const Duration(seconds: 20),
  }) {
    _subs = [messages.listen(_onMessage), audio.listen(_onAudio)];
  }

  final Future<bool> Function(int op, [List<int> payload, bool quiet]) send;

  /// Puts one file on the device. True only once it is safely on disk: the
  /// ring is told to delete its copy on that.
  final Future<bool> Function(OfflinePull file) save;
  final void Function(String) log;

  /// No packets for this long and the transfer is given up; the file stays on
  /// the ring for next time.
  final Duration stallAfter;

  static void _noLog(String _) {}

  late final List<StreamSubscription> _subs;
  final _changes = StreamController<void>.broadcast();
  OfflinePull? _pull;
  bool _wanted = false;
  int _total = 0, _index = 0;
  DateTime? _lastMoved;
  Timer? _stall;

  /// What the ring last said it holds.
  int? onRing;

  /// Plain-words progress, or null when idle.
  String? status;

  /// Recordings moved since the app started.
  int moved = 0;

  Stream<void> get changes => _changes.stream;
  bool get busy => _wanted || _pull != null;

  /// Moves everything on the ring to the device. Does nothing while a pull is
  /// already running.
  Future<void> pullAll() async {
    if (busy) return;
    _wanted = true;
    _setStatus('asking the ring what it holds');
    if (!await send(RingOp.offlineFileCount)) _finish();
  }

  /// The link dropped: whatever was in flight stays on the ring.
  void abandon([String why = 'link lost']) {
    if (!busy) return;
    if (_pull != null) log('pull stopped ($why) — that recording stays on the ring');
    _finish();
  }

  void _onMessage(RingMessage m) {
    switch (m.opcode) {
      case RingOp.offlineFileCount:
        _onCount(decodeRingMessage(m)?.fields['count'] as int? ?? 0);
      case RingOp.offlineUploadDone:
        final remaining = decodeRingMessage(m)?.fields['remaining'] as int? ?? 0;
        // Messages and audio are two async streams, each delivering one event
        // per microtask. When one notification carries the last packets and
        // the 0x36 together, the 0x36 overtakes every packet but the first and
        // reads as "mid-file". A timer runs only once they have all landed.
        unawaited(Future<void>(() => _onFileSent(remaining)));
      case RingOp.offlineAudioEmpty:
        if (_pull != null) {
          log('the ring says it has nothing to send');
          _finish();
        }
    }
  }

  void _onCount(int n) {
    onRing = n;
    if (!_wanted) {
      _changed();
      return;
    }
    _wanted = false;
    if (n == 0) {
      _finish();
      return;
    }
    _total = n;
    _index = 0;
    log('$n recording(s) on the ring — moving them to the device, oldest first');
    _requestNext();
  }

  void _requestNext() {
    _index++;
    _pull = OfflinePull(DateTime.now());
    _setStatus('recording $_index of $_total');
    _armStall();
    unawaited(send(RingOp.audioOffline).then((ok) {
      if (!ok) abandon('request not sent');
    }));
  }

  void _armStall() {
    _stall?.cancel();
    _stall = Timer(stallAfter, () {
      log('!! no audio for ${stallAfter.inSeconds} s — stopping the transfer');
      unawaited(send(RingOp.stopOfflineTransfer));
      abandon('stalled');
    });
  }

  void _onAudio(RingFrame f) {
    if (f.opcode != RingOp.audioOffline) return;
    final p = _pull;
    if (p == null) return;
    final first = p.packets == 0;
    p.add(f);
    _armStall();
    if (first && p.recordedAt != null && p.recordedAt == _lastMoved) {
      log('!! the ring sent the same recording again — the delete did not take. '
          'Stopping; nothing more is deleted.');
      unawaited(send(RingOp.stopOfflineTransfer));
      abandon('repeat');
      return;
    }
    _setStatus('recording $_index of $_total · '
        '${(p.audio.inMilliseconds / 1000).toStringAsFixed(0)} s');
  }

  Future<void> _onFileSent(int remaining) async {
    final p = _pull;
    // The ring may answer our acknowledgement with a 0x36 of its own. LoraFit
    // ignores any 0x36 that does not close a complete file, and so does this.
    if (p == null || p.packets == 0) {
      onRing = remaining;
      _changed();
      return;
    }
    if (!p.complete) {
      log('0x36 mid-file (packet ${p.lastPacket}/${p.totalPackets}) — ignored');
      return;
    }
    _stall?.cancel();
    _pull = null;
    if (p.missing > 0) {
      log('!! ${p.missing} packets missing from ${p.baseName} — NOT deleting it from the ring');
      _finish();
      return;
    }
    bool saved;
    try {
      saved = await save(p);
    } catch (e) {
      log('!! could not save ${p.baseName}: $e');
      saved = false;
    }
    if (!saved) {
      log('!! ${p.baseName} was not saved — it stays on the ring');
      _finish();
      return;
    }
    // On the device's storage now; only at this point may the ring delete it.
    if (!await send(RingOp.offlineUploadDone,
        [remaining & 0xff, (remaining >> 8) & 0xff], true)) {
      log('!! could not acknowledge ${p.baseName} — the ring keeps its copy too');
      _finish();
      return;
    }
    _lastMoved = p.recordedAt;
    moved++;
    onRing = remaining > 0 ? remaining - 1 : 0;
    log('moved ${p.baseName} (${(p.audio.inMilliseconds / 1000).toStringAsFixed(1)} s) '
        '— the ring deletes its copy');
    if (remaining - 1 > 0) {
      _requestNext();
    } else {
      log('all recordings moved to the device');
      _finish();
    }
  }

  void _finish() {
    _stall?.cancel();
    _stall = null;
    _pull = null;
    _wanted = false;
    _setStatus(null);
  }

  void _setStatus(String? s) {
    status = s;
    _changed();
  }

  void _changed() {
    if (!_changes.isClosed) _changes.add(null);
  }

  void dispose() {
    _stall?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    _changes.close();
  }
}
