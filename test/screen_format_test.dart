import 'package:flutter_test/flutter_test.dart';
import 'package:fox1/services/platform/screen_automation_service.dart';

void main() {
  test('the package is read from a compact screen header', () {
    expect(ScreenAutomationService.packageOf('com.whatsapp/HomeActivity\n[1] tap "Chats"'), 'com.whatsapp');
    expect(ScreenAutomationService.packageOf('com.android.messaging · "MTN"\n"Hi"'), 'com.android.messaging');
    expect(ScreenAutomationService.packageOf('com.spotify.music'), 'com.spotify.music');
  });
}
