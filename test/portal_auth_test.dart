import 'package:flutter_test/flutter_test.dart';
import 'package:fox1/services/web/portal_auth.dart';

void main() {
  late DateTime now;
  late PortalAuth auth;

  setUp(() {
    now = DateTime(2026, 9, 13, 20);
    auth = PortalAuth(pin: '482913', now: () => now);
  });

  test('the right PIN opens a session; a wrong one does not', () {
    final bad = auth.signIn('000000');
    expect(bad.ok, isFalse);
    expect(bad.locked, isFalse);
    final good = auth.signIn(' 482913 ');
    expect(good.ok, isTrue);
    expect(auth.valid(good.token), isTrue);
    expect(auth.valid('something else'), isFalse);
    expect(auth.valid(null), isFalse);
  });

  test('five wrong lock the door for a minute — even to the right PIN', () {
    for (var i = 0; i < 4; i++) {
      expect(auth.signIn('111111').locked, isFalse);
    }
    final fifth = auth.signIn('111111');
    expect(fifth.locked, isTrue);
    expect(fifth.retryIn, 60);
    expect(auth.signIn('482913').ok, isFalse, reason: 'still locked');

    now = now.add(const Duration(seconds: 61));
    expect(auth.signIn('482913').ok, isTrue);
  });

  test('each further lockout is twice as long', () {
    for (var i = 0; i < 5; i++) {
      auth.signIn('111111');
    }
    now = now.add(const Duration(minutes: 1));
    for (var i = 0; i < 4; i++) {
      auth.signIn('111111');
    }
    expect(auth.signIn('111111').retryIn, 120);
  });

  test('signing out ends that session only', () {
    final a = auth.signIn('482913').token, b = auth.signIn('482913').token;
    auth.signOut(a);
    expect(auth.valid(a), isFalse);
    expect(auth.valid(b), isTrue);
  });

  test('a new portal has a new six-digit PIN and none of the old sessions', () {
    final token = auth.signIn('482913').token;
    final next = PortalAuth();
    expect(next.pin, matches(RegExp(r'^\d{6}$')));
    expect(next.valid(token), isFalse);
  });

  test('the session is read from the cookie header', () {
    expect(PortalAuth.tokenIn('theme=dark; cp_session=abc123; other=1'), 'abc123');
    expect(PortalAuth.tokenIn('theme=dark'), isNull);
    expect(PortalAuth.tokenIn(null), isNull);
  });
}
