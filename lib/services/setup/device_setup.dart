import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../platform/in_call_service.dart';
import '../platform/notification_service.dart';
import '../platform/quick_settings_service.dart';
import '../platform/screen_automation_service.dart';
import '../platform/system_actions_service.dart';

/// How Android asks for it: a pop-up on the device ("Allow"), or a Settings
/// screen the wearer has to switch FOX-1 on in.
enum AskedBy { prompt, screen }

/// Everything first-time setup asks Android for, in the order the FOX-1 Hub
/// shows it. Only the microphone is required — without it there is nothing
/// to talk to — and the rest each turn one feature on.
enum SetupPermission {
  microphone('Microphone', 'So FOX-1 can hear you.', AskedBy.prompt, required: true),
  camera('Camera', 'So FOX-1 can see what you show it.', AskedBy.prompt),
  phone('Phone', 'Calls: dialling, answering, and knowing when the phone rings.', AskedBy.prompt),
  contacts('Contacts', 'Calling people by name.', AskedBy.prompt),
  sms('Text messages', 'Sending a text for you without opening Messages.', AskedBy.prompt),
  location('Location', 'Android needs it to find the smart ring and to start the device’s own Wi‑Fi hotspot.', AskedBy.prompt),
  accessibility('Accessibility', 'On-screen tasks: opening apps, tapping and typing for you.', AskedBy.screen),
  notifications('Notification access', 'Reading your notifications.', AskedBy.screen),
  dialer('Default phone app', 'The call agent: answering and managing calls.', AskedBy.screen),
  systemSettings('Modify system settings', 'Changing the brightness.', AskedBy.screen),
  battery('Run in the background', 'Waking from the ring while the screen is off.', AskedBy.screen),
  overlay('Display over other apps', 'Showing the call hand-over prompt over the phone app.', AskedBy.screen);

  const SetupPermission(this.label, this.why, this.askedBy, {this.required = false});

  final String label;
  final String why;
  final AskedBy askedBy;
  final bool required;

  static SetupPermission? byName(String? name) {
    for (final p in values) {
      if (p.name == name) return p;
    }
    return null;
  }
}

/// First-time setup: done from the FOX-1 Hub on a phone, while the device
/// shows only a QR code and a PIN (`OnboardingScreen`).
class DeviceSetup {
  /// Whether setup is finished. A device that already has an API key was set
  /// up before this flag existed, so it is not sent back through setup.
  static bool isDone({required bool? saved, required String apiKey}) =>
      saved ?? apiKey.trim().isNotEmpty;

  /// The Hub's view of setup (`GET /api/setup`). Pure, so its shape is tested.
  static Map<String, Object?> json({
    required bool done,
    required bool hasKey,
    required String profile,
    required String mascot,
    String name = 'FOX-1',
    required bool ringPaired,
    required Map<SetupPermission, bool> granted,
    bool keepsAccessibility = false,
  }) =>
      {
        'done': done,
        'hasKey': hasKey,
        'profile': profile,
        'mascot': mascot,
        'name': name,
        'ringPaired': ringPaired,
        'permissions': [
          for (final p in SetupPermission.values)
            {
              'id': p.name,
              'label': p.label,
              'why': p.why,
              'askedBy': p.askedBy.name,
              'required': p.required,
              'granted': granted[p] ?? false,
            },
        ],
        'keepsAccessibility': keepsAccessibility,
        // Setup can finish once the device can hold a conversation.
        'canFinish': hasKey && (granted[SetupPermission.microphone] ?? false),
      };

  static const _screenAutomation = MethodChannel('ai.fox1/screen_automation');

  final _notifications = NotificationService();
  final _inCall = InCallStateService();
  final _quick = QuickSettingsService();
  final _automation = ScreenAutomationService();

  /// Whether accessibility is kept on automatically (see [check]).
  bool keepsAccessibility = false;

  Future<Map<SetupPermission, bool>> check() async {
    // Puts accessibility back first if Android dropped it and FOX-1 may.
    final keep = await _automation.keepStatus();
    keepsAccessibility = keep.granted;
    final out = <SetupPermission, bool>{};
    for (final p in SetupPermission.values) {
      try {
        out[p] = await _granted(p);
      } catch (e) {
        debugPrint('[SETUP] checking ${p.name}: $e');
        out[p] = false;
      }
    }
    return out;
  }

  Future<bool> _granted(SetupPermission p) async => switch (p) {
        SetupPermission.microphone => Permission.microphone.isGranted,
        SetupPermission.camera => Permission.camera.isGranted,
        SetupPermission.phone => Permission.phone.isGranted,
        SetupPermission.contacts => Permission.contacts.isGranted,
        SetupPermission.sms => Permission.sms.isGranted,
        SetupPermission.location => Permission.location.isGranted,
        SetupPermission.accessibility => _automation.isServiceEnabled(),
        SetupPermission.notifications => _notifications.isListenerEnabled(),
        SetupPermission.dialer => _inCall.isDefaultDialer(),
        SetupPermission.systemSettings => _quick.canWriteSettings(),
        SetupPermission.battery => SystemActionsService.backgroundAllowed(),
        SetupPermission.overlay => SystemActionsService.canOverlay(),
      };

  /// Puts Android's own prompt or Settings screen for [p] on the device.
  /// The wearer answers it there; the Hub polls [check] to see the result.
  Future<void> ask(SetupPermission p) async {
    debugPrint('[SETUP] asking for ${p.name}');
    switch (p) {
      case SetupPermission.microphone:
        await Permission.microphone.request();
      case SetupPermission.camera:
        await Permission.camera.request();
      case SetupPermission.phone:
        await Permission.phone.request();
      case SetupPermission.contacts:
        await Permission.contacts.request();
      case SetupPermission.sms:
        await Permission.sms.request();
      case SetupPermission.location:
        await Permission.location.request();
      case SetupPermission.accessibility:
        await _screenAutomation.invokeMethod('openAccessibilitySettings');
      case SetupPermission.notifications:
        await _notifications.requestListenerPermission();
      case SetupPermission.dialer:
        await _inCall.requestDefaultDialer();
      case SetupPermission.systemSettings:
        await _quick.openWriteSettings();
      case SetupPermission.battery:
        await SystemActionsService.allowBackground();
      case SetupPermission.overlay:
        await SystemActionsService.requestOverlay();
    }
  }
}
