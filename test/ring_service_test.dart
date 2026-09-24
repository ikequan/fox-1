import 'package:flutter_test/flutter_test.dart';
import 'package:fox1/services/ring/ring_service.dart';

void main() {
  final now = DateTime(2026, 9, 10, 14);

  test('the first sync takes all seven days the ring keeps', () {
    expect(syncOffsets(null, now), [0, 1, 2, 3, 4, 5, 6]);
  });

  test('later syncs take the days since, plus one — never fewer than two', () {
    // Last night's sleep starts on yesterday's page, so even a sync an hour
    // ago asks for yesterday.
    expect(syncOffsets(DateTime(2026, 9, 10, 9), now), [0, 1]);
    expect(syncOffsets(DateTime(2026, 9, 9, 23), now), [0, 1, 2]);
    expect(syncOffsets(DateTime(2026, 8, 1), now), hasLength(7));
  });

  test('reconnecting backs off to once a minute and never stops', () {
    expect([for (var i = 0; i < 6; i++) reconnectDelay(i).inSeconds],
        [5, 15, 30, 60, 60, 60]);
  });
}
