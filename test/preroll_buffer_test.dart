import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fox1/services/session/preroll_buffer.dart';

/// 100 ms of 16 kHz PCM16.
Uint8List chunk([int fill = 1]) => Uint8List.fromList(List.filled(3200, fill));

void main() {
  test('holds what was said before the socket was up, in order', () {
    final b = PrerollBuffer();
    b.add(chunk(1));
    b.add(chunk(2));
    expect(b.chunks, 2);
    expect(b.duration, const Duration(milliseconds: 200));
    final out = b.takeAll();
    expect(out.map((c) => c.first), [1, 2]);
    expect(b.isEmpty, isTrue, reason: 'taking empties it — no audio sent twice');
  });

  test('a connection that never comes does not queue minutes of stale speech', () {
    final b = PrerollBuffer(limitBytes: 3200 * 3);
    for (var i = 1; i <= 10; i++) {
      b.add(chunk(i));
    }
    expect(b.chunks, 3);
    expect(b.takeAll().map((c) => c.first), [8, 9, 10],
        reason: 'the newest speech is the speech worth sending');
  });

  test('eight seconds by default', () {
    expect(PrerollBuffer().limitBytes, 16000 * 2 * 8);
  });
}
