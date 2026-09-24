import 'dart:async';

/// Lets the web server drive the ring — the device is too small to type hex
/// on, so `/ring` offers every command as a button in a phone or laptop
/// browser.
///
/// RingService attaches at boot, so commands work whether or not the Smart
/// Ring screen is open. The screen adds the actions only it can do (moving
/// recordings) while it is open, and removes them in `dispose`.
class RingConsole {
  RingConsole._();

  static Future<String> Function(int op, List<int> payload)? _send;
  static bool Function()? _connected;
  static Map<String, Future<void> Function()> _actions = const {};
  static Map<String, Future<void> Function()> _screenActions = const {};

  static const notOpen = 'the ring service is not running on the device';

  /// What a successful [send] returns; anything else explains the failure.
  static const sent = 'sent';

  static void attach({
    required Future<String> Function(int op, List<int> payload) send,
    required bool Function() connected,
    Map<String, Future<void> Function()> actions = const {},
  }) {
    _send = send;
    _connected = connected;
    _actions = actions;
  }

  static void detach() {
    _send = null;
    _connected = null;
    _actions = const {};
    _screenActions = const {};
  }

  /// Actions the Smart Ring screen offers while open; null to remove them.
  static void setScreenActions(Map<String, Future<void> Function()>? actions) =>
      _screenActions = actions ?? const {};

  /// The ring service is running.
  static bool get attached => _send != null;

  /// …and its ring link is up.
  static bool get connected => _connected?.call() ?? false;

  static Future<String> send(int op, List<int> payload) async {
    final s = _send;
    return s == null ? notOpen : s(op, payload);
  }

  /// Starts a named action and returns at once — a seven-day sync takes
  /// ~20 s, far longer than a browser should wait on a button.
  static Future<String> action(String name) async {
    if (_send == null) return notOpen;
    final a = _actions[name] ?? _screenActions[name];
    if (a == null) {
      return 'no such action: $name (some need Settings → Smart Ring open)';
    }
    unawaited(a());
    return 'started — watch the log';
  }
}
