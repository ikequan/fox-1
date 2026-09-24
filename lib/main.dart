import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'providers/providers.dart';
import 'services/logging/log_buffer.dart';
import 'screens/onboarding_screen.dart';
import 'screens/launcher_shell.dart';
import 'screens/bridge_test_screen.dart';
import 'screens/ring_test_screen.dart';
import 'screens/settings_screen.dart';
import 'widgets/transfer_prompt.dart';
import 'services/call/crash_journal.dart';
import 'services/call/call_report.dart';
import 'services/call/call_agent_duty.dart';
import 'services/platform/system_actions_service.dart';

/// Global container so non-widget code (e.g. HTTP server) can read/write providers.
late final ProviderContainer globalContainer;

void main() {
  // Everything inside the zone, so an async error anywhere reaches onError
  // below instead of vanishing.
  runZonedGuarded(() {
    WidgetsFlutterBinding.ensureInitialized();
    // Capture debugPrint before anything else runs — with no ADB on this device,
    // the in-app buffer served at /logs is the only way to read diagnostics.
    LogBuffer.install();
    LogBuffer.instance.attachFile();

    // Dart-side crashes left no trace at all. The Kotlin uncaught handler only
    // sees Java throws, so a Dart exception that took the app down produced an
    // empty log and a silent relaunch — indistinguishable from the low-memory
    // killer, which is exactly the distinction we need.
    FlutterError.onError = (details) {
      debugPrint('[CRASH] flutter: ${details.exceptionAsString()}');
      debugPrint('[CRASH] ${details.stack}');
      FlutterError.presentError(details);
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      debugPrint('[CRASH] platform: $error');
      debugPrint('[CRASH] $stack');
      return true;
    };

    globalContainer = ProviderContainer();
    runApp(
      UncontrolledProviderScope(
        container: globalContainer,
        child: const Fox1App(),
      ),
    );
  }, (error, stack) {
    debugPrint('[CRASH] zone: $error');
    debugPrint('[CRASH] $stack');
  });
}

class Fox1App extends ConsumerStatefulWidget {
  const Fox1App({super.key});

  @override
  ConsumerState<Fox1App> createState() => _Fox1AppState();
}

class _Fox1AppState extends ConsumerState<Fox1App> {
  /// Recovery navigates from here, and `this` sits ABOVE the MaterialApp — so
  /// `Navigator.of(context)` finds nothing and throws. A key on the app's own
  /// navigator is the only handle that works from outside it.
  final _navigator = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    ref.read(settingsInitProvider);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _recoverInFlightCall();
      _goOnDutyIfAsked();
      _startRing();
    });
  }

  /// The smart ring stays connected all day once one is paired (Settings →
  /// Smart Ring → Use this ring). A no-op until then.
  Future<void> _startRing() async {
    try {
      await ref.read(ringServiceProvider).start();
      // Hold-to-talk works whether or not a ring is paired yet: the button
      // stream is the service's, and pairing later needs no restart.
      await ref.read(ringGesturesProvider).start();
      // Voice notes: recordings come off the ring and get transcribed on
      // their own. Also moves in any the Ring test screen pulled earlier.
      await ref.read(ringNotesProvider).start();
      // A hold with the screen off needs the network while the device idles.
      // Say which way it is, so every log answers it without asking.
      final bg = await SystemActionsService.backgroundAllowed();
      debugPrint('[RING] background access: ${bg ? 'allowed' : 'NOT allowed'
          ' — a hold with the screen off may find no network'
          ' (Settings → Smart Ring)'}');
    } catch (e) {
      debugPrint('[RING] could not start: $e');
    }
  }

  /// Bring the call agent up at boot if the wearer left it on duty.
  ///
  /// It has to be here rather than on any screen: the whole point is that the
  /// agent answers calls when nobody is looking at the device. Settings starts
  /// and stops it directly when the toggle is flipped; this covers a restart.
  Future<void> _goOnDutyIfAsked() async {
    // Settings are loaded asynchronously at startup, so wait for them rather
    // than reading a default and concluding the agent is off.
    await ref.read(settingsInitProvider.future);
    if (!ref.read(callAgentOnDutyProvider)) return;
    final address = ref.read(callAgentDeviceProvider);
    if (address.isEmpty) {
      debugPrint('[CALL-AGENT] on duty but no board chosen — staying off');
      return;
    }
    final err = await startCallAgent(address);
    if (err != null) debugPrint('[CALL-AGENT] could not go on duty: $err');
  }

  /// Step 7, and it has to live here rather than on the bridge screen.
  ///
  /// The recovery itself is in `BridgeTestScreen`, which is where the session
  /// is assembled — but after a crash the app relaunches to the watchface, and
  /// that screen is never built. Recovery would only have run if the wearer
  /// happened to open Settings → Call Bridge, which during a call they cannot
  /// do: the dialer owns the screen. So the *check* runs at startup, and when
  /// there is a live call to rejoin it opens the screen that can do it.
  ///
  /// The two cases that need no bridge — a finished call to file, a stale entry
  /// to discard — are handled here without disturbing anything on screen.
  Future<void> _recoverInFlightCall() async {
    final journal = ref.read(crashJournalProvider);
    final snap = await journal.findUnfinished();
    if (snap == null) return;

    final live = await journal.callStillLive();
    switch (CrashJournal.decide(snap, callLive: live)) {
      case Recovery.nothing:
        debugPrint('[RECOVER] stale in-flight call from ${snap.number} '
            '— discarding');
        await journal.callEnded();
        return;

      case Recovery.fileOnly:
        debugPrint('[RECOVER] the app died during a call with ${snap.number}'
            ' — it is over, filing it');
        final history = ref.read(callHistoryProvider);
        await history.load();
        await history.record(CallReport.unavailable(
          number: snap.number,
          startedAt: snap.startedAt,
          durationS: snap.durationS,
        ));
        await journal.callEnded();
        return;

      case Recovery.readopt:
        debugPrint('[RECOVER] the app died during a call with ${snap.number}'
            ' — it is STILL UP, rejoining');
        await ref.read(settingsInitProvider.future);

        // On duty: rejoin headlessly. Opening the bring-up harness in front of
        // a wearer who is mid-call would put a device picker and a log window
        // on screen — and worse, that screen takes the bridge for itself and
        // silently leaves the agent off duty afterwards.
        if (ref.read(callAgentOnDutyProvider) &&
            snap.deviceAddress.isNotEmpty) {
          final err = await readoptCall(snap.deviceAddress,
              number: snap.number, startedAt: snap.startedAt);
          if (err == null) return;
          debugPrint('[RECOVER] headless rejoin failed: $err');
        }

        // Off duty — this was the playground, so send it back there. The
        // navigator may not be attached the instant the first frame is drawn,
        // and there is a live caller waiting, so try for a moment.
        for (var i = 0; i < 20; i++) {
          if (!mounted) return;
          final nav = _navigator.currentState;
          if (nav != null) {
            nav.pushNamed('/bridge-test');
            return;
          }
          await Future.delayed(const Duration(milliseconds: 100));
        }
        debugPrint('[RECOVER] no navigator after 2s — cannot open the bridge');
        return;
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FOX-1',
      navigatorKey: _navigator,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0A0A0A),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF00E5CC),
          surface: Color(0xFF0A0A0A),
        ),
        useMaterial3: true,
      ),
      // Wraps everything: a caller waiting on a hand-over does not care which
      // screen is showing, and the prompt must outrank all of them.
      builder: (context, child) =>
          TransferPromptOverlay(child: child ?? const SizedBox.shrink()),
      home: const _Home(),
      routes: {
        '/settings': (_) => const SettingsScreen(),
        '/bridge-test': (_) => const BridgeTestScreen(),
        '/ring-test': (_) => const RingTestScreen(),
      },
    );
  }
}

/// The launcher once the device is set up; before that, only the FOX-1 Hub's
/// code (`OnboardingScreen`). Black while the settings load, so a set-up
/// device never flashes the setup screen.
class _Home extends ConsumerWidget {
  const _Home();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(settingsInitProvider).isLoading) {
      return const ColoredBox(color: Colors.black);
    }
    return ref.watch(setupDoneProvider) ? const LauncherShell() : const OnboardingScreen();
  }
}
