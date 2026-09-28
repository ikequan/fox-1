import 'package:flutter_test/flutter_test.dart';
import 'package:fox1/config/constants.dart';

/// The built-in prompt carries rules learned on hardware; each line here is
/// a failure that came back when the rule was missing.
void main() {
  final p = GeminiConfig.defaultPrompt;

  test('app work goes to the helper, in the app the wearer named', () {
    expect(p, contains('do_on_device'));
    expect(p, contains('Use only the app the user named'));
    expect(p, contains('Never tell the user an app task cannot be done'));
  });

  test('no second attempt, and the relay only on request', () {
    expect(p, contains('Do not start another attempt'));
    expect(p, contains('ONLY when the user explicitly asks'));
  });

  test('no screen tools the voice model no longer has', () {
    expect(p, isNot(contains('get_screen')));
    expect(p, isNot(contains('wait_for_screen')));
    expect(p, isNot(contains('app_shortcut')));
  });
}
