import 'package:flutter_test/flutter_test.dart';
import 'package:fox1/services/gemini/gemini_live_client.dart';

void main() {
  test('a handle is offered back only while Google still keeps it', () {
    // The refused resume on hardware: last handle 12:23, wake at 16:03.
    final issued = DateTime(2026, 9, 11, 12, 23, 22);
    expect(GeminiLiveClient.resumeHandleFresh(issued, DateTime(2026, 9, 11, 16, 3, 44)),
        isFalse);
    // A wake a few minutes after standing down resumes as before.
    expect(GeminiLiveClient.resumeHandleFresh(issued, DateTime(2026, 9, 11, 12, 30)),
        isTrue);
    expect(
        GeminiLiveClient.resumeHandleFresh(
            issued, issued.add(GeminiLiveClient.handleLifetime)),
        isFalse);
    expect(GeminiLiveClient.resumeHandleFresh(null, issued), isFalse);
  });

  test('refusals and outages say what happened', () {
    expect(
        GeminiSetupRefused('socket closed during setup', code: 1008, reason: 'not found')
            .toString(),
        'socket closed during setup, code 1008, "not found"');
    expect(GeminiUnreachable('timeout').toString(), contains('no network'));
  });
}
