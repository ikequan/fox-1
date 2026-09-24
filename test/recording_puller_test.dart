import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fox1/services/notes/recording_puller.dart';
import 'package:fox1/services/ring/ring_audio.dart';
import 'package:fox1/services/ring/ring_protocol.dart';

RingMessage msg(int op, List<int> p) => RingMessage(op, Uint8List.fromList(p));

/// One 0x34 packet: the ring's timestamp, then three 40-byte Opus packets.
RingFrame packet(DateTime t, int n, int of) => RingFrame(
      opcode: RingOp.audioOffline,
      totalPackets: of,
      currentPacket: n,
      payload: Uint8List.fromList(
          [...ringTimestampBytes(t), ...List.filled(3 * ringOpusFrameBytes, n)]),
    );

Future<void> settle() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late StreamController<RingMessage> messages;
  late StreamController<RingFrame> audio;
  late List<List<int>> sent;
  late List<String> saved;
  late RecordingPuller puller;
  late bool saveResult;
  Completer<void>? saveGate;

  final t1 = DateTime(2026, 9, 11, 19, 46, 21), t2 = DateTime(2026, 9, 11, 20, 1, 5);

  Future<bool> send(int op, [List<int> payload = const [], bool quiet = false]) async {
    sent.add([op, ...payload]);
    return true;
  }

  Iterable<List<int>> acks() => sent.where((s) => s.first == RingOp.offlineUploadDone);

  setUp(() {
    messages = StreamController.broadcast();
    audio = StreamController.broadcast();
    sent = [];
    saved = [];
    saveResult = true;
    saveGate = null;
    puller = RecordingPuller(
      send: send,
      messages: messages.stream,
      audio: audio.stream,
      save: (p) async {
        if (saveGate != null) await saveGate!.future;
        saved.add(p.baseName);
        return saveResult;
      },
      stallAfter: const Duration(milliseconds: 200),
    );
  });

  tearDown(() {
    puller.dispose();
    messages.close();
    audio.close();
  });

  test('moves each file, and acknowledges it only once it is saved', () async {
    saveGate = Completer();
    await puller.pullAll();
    expect(sent.last, [RingOp.offlineFileCount]);
    messages.add(msg(RingOp.offlineFileCount, [2, 0]));
    await settle();
    expect(sent.last, [RingOp.audioOffline]);

    audio
      ..add(packet(t1, 1, 2))
      ..add(packet(t1, 2, 2));
    messages.add(msg(RingOp.offlineUploadDone, [2, 0]));
    await settle();
    // Not on disk yet, so nothing may tell the ring to delete it.
    expect(acks(), isEmpty);

    saveGate!.complete();
    await settle();
    expect(saved, ['ring_20260911_194621']);
    expect(acks().single, [RingOp.offlineUploadDone, 2, 0]);
    expect(sent.last, [RingOp.audioOffline], reason: 'then asks for the next');

    audio.add(packet(t2, 1, 1));
    messages.add(msg(RingOp.offlineUploadDone, [1, 0]));
    await settle();
    expect(saved, hasLength(2));
    expect(puller.busy, isFalse);
    expect(puller.moved, 2);
  });

  test('a file with packets missing stays on the ring', () async {
    await puller.pullAll();
    messages.add(msg(RingOp.offlineFileCount, [1, 0]));
    await settle();
    audio
      ..add(packet(t1, 1, 3))
      ..add(packet(t1, 3, 3));
    messages.add(msg(RingOp.offlineUploadDone, [1, 0]));
    await settle();
    expect(saved, isEmpty);
    expect(acks(), isEmpty);
    expect(puller.busy, isFalse);
  });

  test('a save that fails leaves the file on the ring', () async {
    saveResult = false;
    await puller.pullAll();
    messages.add(msg(RingOp.offlineFileCount, [1, 0]));
    await settle();
    audio.add(packet(t1, 1, 1));
    messages.add(msg(RingOp.offlineUploadDone, [1, 0]));
    await settle();
    expect(acks(), isEmpty);
  });

  test('the same recording twice means the delete did not take: stop', () async {
    await puller.pullAll();
    messages.add(msg(RingOp.offlineFileCount, [2, 0]));
    await settle();
    audio.add(packet(t1, 1, 1));
    messages.add(msg(RingOp.offlineUploadDone, [2, 0]));
    await settle();
    audio.add(packet(t1, 1, 1));
    await settle();
    expect(sent.last, [RingOp.stopOfflineTransfer]);
    expect(saved, hasLength(1));
    expect(puller.busy, isFalse);
  });

  test('a transfer that stalls is given up, and the file stays on the ring', () async {
    await puller.pullAll();
    messages.add(msg(RingOp.offlineFileCount, [1, 0]));
    await settle();
    audio.add(packet(t1, 1, 2));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(sent.last, [RingOp.stopOfflineTransfer]);
    expect(acks(), isEmpty);
    expect(puller.busy, isFalse);
  });

  test('a 0x36 with no transfer running acknowledges nothing', () async {
    messages.add(msg(RingOp.offlineUploadDone, [3, 0]));
    await settle();
    expect(sent, isEmpty);
    expect(puller.onRing, 3);
  });

  test('an empty ring: nothing is asked for', () async {
    await puller.pullAll();
    messages.add(msg(RingOp.offlineFileCount, [0, 0]));
    await settle();
    expect(sent, [
      [RingOp.offlineFileCount]
    ]);
    expect(puller.busy, isFalse);
  });
}
