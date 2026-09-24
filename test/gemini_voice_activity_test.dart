import 'package:flutter_test/flutter_test.dart';
import 'package:fox1/services/gemini/gemini_live_client.dart';

void main() {
  test('voice activity, as the Live API sent it on hardware', () {
    // RX#5 at 10:31:46 and RX#8 at 10:31:50.
    expect(
        GeminiLiveClient.speechActivityOf({
          'serverContent': {},
          'voiceActivity': {'type': 'ACTIVITY_START', 'audioOffset': '3.640s'},
        }),
        'start');
    expect(
        GeminiLiveClient.speechActivityOf({
          'voiceActivity': {'type': 'ACTIVITY_END', 'audioOffset': '7s'},
        }),
        'end');
  });

  test('messages without it, or with something new, are not speech', () {
    expect(GeminiLiveClient.speechActivityOf({'serverContent': {}}), isNull);
    expect(
        GeminiLiveClient.speechActivityOf({
          'voiceActivity': {'type': 'SOMETHING_ELSE'},
        }),
        isNull);
  });
}
