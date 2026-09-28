import 'package:flutter/foundation.dart';

/// How big each screen read is — what the model gets from `get_screen`,
/// which stays in the Live conversation and is billed again on every later
/// turn. Logged as `[SCREEN]`; during a developer measurement
/// (`/api/dev/task`) the reads themselves are kept too.
class ScreenCapture {
  ScreenCapture._();

  static bool capturing = false;
  static final List<String> captured = [];
  static int _count = 0;

  static void record(String screen) {
    _count++;
    final ids = RegExp(r'^\[\d+\]', multiLine: true).allMatches(screen).length;
    debugPrint('[SCREEN] read $_count: ${screen.length} chars ≈ ${screen.length ~/ 4} tokens, $ids to act on');
    if (capturing && captured.length < 300) captured.add(screen);
  }

  static void start() {
    captured.clear();
    capturing = true;
  }
}
