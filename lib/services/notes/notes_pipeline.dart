import 'dart:async';
import 'dart:typed_data';

import 'note_store.dart';
import 'transcriber.dart';

/// Turns waiting recordings into notes, one at a time, and keeps at it.
///
/// A recording is on the device before any of this runs, so nothing here can
/// lose one. What can fail is decoding (the raw packets stay for another go)
/// or Gemini (no network, quota, a reply it could not shape). Each failure
/// backs off; failures that are not the recording's fault never count toward
/// giving up, so a day offline still ends with everything transcribed.
class NotesPipeline {
  NotesPipeline({
    required this.store,
    required this.transcribe,
    required this.toWav,
    this.keepAwake,
    this.log = _noLog,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final NoteStore store;
  final Future<NoteTranscript> Function(Uint8List wav, DateTime recordedAt) transcribe;

  /// The ring's Opus packets → a WAV Gemini can read.
  final Future<Uint8List> Function(Uint8List frames) toWav;

  /// Keeps the CPU up for one transcription — the screen is usually off.
  final Future<void> Function()? keepAwake;
  final void Function(String) log;
  final DateTime Function() _now;

  static void _noLog(String _) {}

  /// Failed tries a recording gets when the fault may be its own.
  static const maxStrikes = 5;

  static Duration backoff(int tries) => const [
        Duration(minutes: 1),
        Duration(minutes: 5),
        Duration(minutes: 15),
        Duration(hours: 1),
        Duration(hours: 3),
      ][(tries - 1).clamp(0, 4)];

  bool _running = false;
  bool _again = false;
  Timer? _retry;

  bool get running => _running;

  /// Transcribes everything due. Single-flight: a call while running makes it
  /// go round once more instead of starting a second.
  Future<void> run() async {
    if (_running) {
      _again = true;
      return;
    }
    _running = true;
    try {
      do {
        _again = false;
        for (final n in await store.due(_now())) {
          await _one(n);
        }
      } while (_again);
    } finally {
      _running = false;
      await _schedule();
    }
  }

  Future<void> _one(Note n) async {
    final frames = await store.frames(n.id);
    if (frames == null) {
      n
        ..status = NoteStatus.failed
        ..error = 'the recording is missing from the device';
      await store.save(n);
      return;
    }
    await keepAwake?.call();
    try {
      final t = await transcribe(await toWav(frames), n.recordedAt);
      n
        ..status = NoteStatus.done
        ..title = t.title
        ..summary = t.summary
        ..transcript = t.transcript
        ..language = t.language
        ..actionItems = t.actionItems
        ..people = t.people
        ..dates = t.dates
        ..error = null
        ..nextTryAt = null;
      log('transcribed ${n.id}: "${t.title}"');
    } on TranscribeError catch (e) {
      _failed(n, e.message, counts: !e.network, final_: !e.retryable);
    } catch (e) {
      // Decoding, most likely. The packets are kept, so try again later.
      _failed(n, 'could not decode: $e', counts: true, final_: false);
    }
    await store.save(n);
  }

  void _failed(Note n, String why, {required bool counts, required bool final_}) {
    n
      ..tries += 1
      ..error = why;
    if (counts) n.strikes += 1;
    if (final_ || n.strikes >= maxStrikes) {
      n
        ..status = NoteStatus.failed
        ..nextTryAt = null;
      log('!! gave up on ${n.id}: $why — the recording is kept');
    } else {
      n.nextTryAt = _now().add(backoff(n.tries));
      log('${n.id} not transcribed yet ($why) — trying again in '
          '${backoff(n.tries).inMinutes} min');
    }
  }

  Future<void> _schedule() async {
    _retry?.cancel();
    final next = await store.nextRetry();
    if (next == null) return;
    var wait = next.difference(_now());
    if (wait < const Duration(seconds: 5)) wait = const Duration(seconds: 5);
    _retry = Timer(wait, () => unawaited(run()));
  }

  void dispose() => _retry?.cancel();
}
