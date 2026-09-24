import 'package:flutter_test/flutter_test.dart';
import 'package:fox1/services/call/dialed_numbers.dart';

void main() {
  group('an errand does not outlive its call', () {
    test('taskFor goes stale on the same clock as recent', () {
      final d = DialedNumbers();
      d.note('0200000001', task: 'bridge test dispatch');
      expect(d.taskFor('0200000001'), 'bridge test dispatch');
      // The call that errand was for is long over; a later call from the same
      // person is not a dispatched callback.
      expect(d.taskFor('0200000001', within: Duration.zero), '');
    });

    test('the errand is spent when its call ends', () {
      final d = DialedNumbers();
      d.note('0200000001', task: 'chase the printer');
      d.noteCallEnded('0200000001');
      expect(d.taskFor('0200000001'), '');
      expect(d.recent(), '');
    });

    test('a finished errand blocks an immediate repeat to the same number', () {
      final d = DialedNumbers();
      d.note('0200000001', task: 'ask about the game');
      expect(d.completedFor('0200000001'), isNull, reason: 'still in progress');
      d.noteCallEnded('0200000001');
      final done = d.completedFor('0200000001');
      expect(done, isNotNull);
      expect(done!.task, 'ask about the game');
      // Someone else is not blocked, and neither is the same person later.
      expect(d.completedFor('0201111111'), isNull);
      expect(d.completedFor('0200000001', within: Duration.zero), isNull);
    });

    test('the wearer speaking lifts the block, whatever the new errand', () {
      final d = DialedNumbers();
      d.note('0200000001', task: 'bring his PS5 controller');
      d.noteCallEnded('0200000001');
      // The agent chasing its own finished errand, unprompted: refused.
      expect(d.completedFor('0200000001'), isNotNull);
      // The wearer asks for something else. A different errand to the same
      // person is not a duplicate, and was wrongly refused as one.
      d.allowRedial();
      expect(d.completedFor('0200000001'), isNull);
    });

    test('someone else ending a call does not discard the errand', () {
      final d = DialedNumbers();
      d.note('0200000001', task: 'chase the printer');
      d.noteCallEnded('0201111111');
      expect(d.taskFor('0200000001'), 'chase the printer');
    });
  });
}
