import 'dart:math';

/// Who may use the portal: a six-digit PIN, new each time the portal is
/// turned on, and the sessions it has handed out — all of which die with it.
///
/// A million PINs is a small space to someone on the same Wi-Fi, so five
/// wrong in a row lock the door for a minute, twice as long on each further
/// lockout. Pure, so the rules are tested without a server.
class PortalAuth {
  PortalAuth({String? pin, Random? random, DateTime Function()? now})
      : _random = random ?? Random.secure(),
        _now = now ?? DateTime.now {
    this.pin = pin ?? List.generate(6, (_) => _random.nextInt(10)).join();
  }

  static const cookieName = 'cp_session';
  static const maxWrong = 5;
  static const firstLockout = Duration(minutes: 1);

  final Random _random;
  final DateTime Function() _now;
  late final String pin;

  final _sessions = <String>{};
  int _wrong = 0, _lockouts = 0;
  DateTime? _lockedUntil;

  /// Seconds until another try is allowed; 0 when one is.
  int get retryIn {
    final until = _lockedUntil;
    if (until == null) return 0;
    final ms = until.difference(_now()).inMilliseconds;
    return ms <= 0 ? 0 : (ms / 1000).ceil();
  }

  SignIn signIn(String attempt) {
    if (retryIn > 0) return SignIn._(locked: true, retryIn: retryIn);
    if (_same(attempt.trim(), pin)) {
      _wrong = 0;
      _lockouts = 0;
      final token = _token();
      _sessions.add(token);
      return SignIn._(token: token);
    }
    if (++_wrong < maxWrong) return const SignIn._();
    _wrong = 0;
    _lockedUntil = _now().add(firstLockout * (1 << min(_lockouts++, 5)));
    return SignIn._(locked: true, retryIn: retryIn);
  }

  bool valid(String? token) => token != null && _sessions.contains(token);

  void signOut(String? token) => _sessions.remove(token);

  /// The session token in a `Cookie` header, if it carries one.
  static String? tokenIn(String? cookieHeader) {
    if (cookieHeader == null) return null;
    for (final part in cookieHeader.split(';')) {
      final i = part.indexOf('=');
      if (i > 0 && part.substring(0, i).trim() == cookieName) {
        return part.substring(i + 1).trim();
      }
    }
    return null;
  }

  String _token() => [
        for (var i = 0; i < 32; i++) _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ].join();

  /// Looks at every character, so the time taken says nothing about how much
  /// of a guess was right.
  static bool _same(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}

class SignIn {
  const SignIn._({this.token, this.locked = false, this.retryIn = 0});

  /// The session, on a right PIN.
  final String? token;
  final bool locked;

  /// Seconds until another try, when [locked].
  final int retryIn;

  bool get ok => token != null;
}
