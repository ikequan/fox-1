import 'package:flutter_test/flutter_test.dart';
import 'package:fox1/services/ring/ring_console.dart';

void main() {
  tearDown(RingConsole.detach);

  test('with the Smart Ring screen closed, the console says so', () async {
    expect(RingConsole.attached, isFalse);
    expect(RingConsole.connected, isFalse);
    expect(await RingConsole.send(0x06, [0, 0]), RingConsole.notOpen);
    expect(await RingConsole.action('moveAll'), RingConsole.notOpen);
  });

  test('commands and actions reach the attached screen', () async {
    final sent = <List<int>>[];
    var moved = false;
    RingConsole.attach(
      send: (op, p) async {
        sent.add([op, ...p]);
        return RingConsole.sent;
      },
      connected: () => true,
      actions: {
        'moveAll': () async {
          moved = true;
        },
      },
    );
    expect(await RingConsole.send(0x0F, [2, 1]), RingConsole.sent);
    expect(sent.single, [0x0F, 2, 1]);
    expect(await RingConsole.action('moveAll'), contains('started'));
    await Future<void>.delayed(Duration.zero);
    expect(moved, isTrue);
    expect(await RingConsole.action('nope'), startsWith('no such'));
  });

  test('the screen\'s actions come and go with the screen', () async {
    var moved = false;
    RingConsole.attach(send: (_, _) async => RingConsole.sent, connected: () => true);
    RingConsole.setScreenActions({
      'moveAll': () async {
        moved = true;
      },
    });
    expect(await RingConsole.action('moveAll'), contains('started'));
    await Future<void>.delayed(Duration.zero);
    expect(moved, isTrue);
    RingConsole.setScreenActions(null);
    expect(await RingConsole.action('moveAll'), startsWith('no such'));
  });

  test('detaching leaves nothing behind to call', () async {
    RingConsole.attach(send: (_, _) async => RingConsole.sent, connected: () => true);
    RingConsole.detach();
    expect(await RingConsole.send(0x06, []), RingConsole.notOpen);
  });
}
