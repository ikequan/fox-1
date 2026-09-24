# Contributing to FOX-1

Thanks for helping. FOX-1 runs on real, odd hardware, so a report of what
happened on *your* device is as valuable as code.

## Reporting a bug

Open an issue with:

- your device model and Android version, and your ring if one is involved;
- what you did, what you expected and what happened;
- the log around it. With FOX-1 Hub on, open `http://<device-ip>:8080/logs`,
  or run `adb logcat` if you have ADB. **Check the log for anything private
  before you paste it.**

## Making a change

1. Fork, then branch from `main`.
2. Keep to the style of the code around your change, and read *Codebase
   notes* below. Many odd-looking choices come from failures seen on real
   hardware, so ask in an issue before "simplifying" one.
3. Before you open the pull request:
   ```bash
   flutter analyze   # must report no issues
   flutter test      # must pass
   ```
4. Describe what you tested and on which hardware.

## Codebase notes

- **A setting lives in four places.** Add it to:
  - `lib/providers/providers.dart`: the provider, plus its load line in
    `settingsInitProvider`;
  - the device's Settings screen;
  - `lib/services/web/settings_server.dart`: GET and the partial POST;
  - FOX-1 Hub's Settings page (`assets/portal/portal.js`).

  Save it to `SharedPreferences` under the same key everywhere.
- **A tool the assistant can call lives in three places**, all in
  `native_tools_bridge.dart`: its name in `_nativeToolNames`, a `case` in
  `_handleNative`, and its JSON schema in `_nativeDeclarations`.
- **Riverpod 2.x.**
  - Never call `ref.read()` in `dispose()`; capture what you need in
    `initState`.
  - Never hand a `WidgetRef` to anything that outlives the widget. Use
    `globalContainer` or a provider's own `Ref` instead.
- **Cancel every `StreamSubscription`** a widget opens.
- **The live mascot is expensive to draw on these GPUs.** Never wrap
  `LiveMascot` in `Opacity`, `ShaderMask`, `BackdropFilter` or animated clips.
- **FOX-1 Hub makes no external requests.** Phones are often on the device's
  hotspot with no internet, so the Hub is plain JS and CSS with no CDN.
- **First-time setup** is `lib/services/setup/device_setup.dart` (what it asks
  Android for) and `OnboardingScreen` (the device's QR code). A new permission
  a feature needs belongs in `SetupPermission`, so setup asks for it.
- **A new kind of the wearer's data goes into backups.** Add its folder or
  file to `BackupFormat` (`lib/services/backup/backup.dart`), or a backup
  silently leaves it behind.
- **Keep `docs/HUB_API.md` in step** with `lib/services/web/portal_api.dart`.

## Ground rules

- **No secrets, ever.** API keys are entered on the device at runtime. Never
  put them in code, tests, docs or logs.
- **No private data** in tests or examples. Use fake numbers like
  `0200000001` and made-up names.
- **Check a dependency's licence before adding it.** It must be compatible
  with Apache-2.0 and free for commercial use. Prefer the Android SDK through
  a Kotlin platform channel over a plugin with strings attached.
- **Hardware protocols are described in our own words.** Don't paste code
  from other vendors' apps.
- Leave `lib/watch_avatar/src/rig.dart` and the painters' shapes and colours
  alone unless the change comes with updated reference images
  (`docs/watch_avatar/reference/`).

By contributing, you agree that your contribution is licensed under the
[Apache License 2.0](LICENSE).
