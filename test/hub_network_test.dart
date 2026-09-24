import 'package:flutter_test/flutter_test.dart';
import 'package:fox1/services/web/settings_server.dart';

void main() {
  test('the Hub offers only addresses a phone beside the device can reach', () {
    for (final ok in ['wlan0', 'wlan1', 'eth0', 'ap0', 'swlan0', 'softap0', 'rndis0', 'usb0']) {
      expect(SettingsServer.isLocalInterface(ok), isTrue, reason: ok);
    }
    // Mobile data: once advertised after a restart, before Wi-Fi was back.
    for (final no in ['seth_lte0', 'rmnet_data0', 'rmnet0', 'ccmni0', 'pdp0', 'lo', 'dummy0', 'tun0']) {
      expect(SettingsServer.isLocalInterface(no), isFalse, reason: no);
    }
  });
}
