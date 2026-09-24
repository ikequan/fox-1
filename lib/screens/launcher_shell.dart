import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/providers.dart';
import '../services/session/ai_session_manager.dart';
import '../widgets/swipe_navigator.dart';
import 'watchface_screen.dart';
import 'ai_agent_screen.dart';
import 'apps_screen.dart';
import 'notifications_screen.dart';
import 'controls_screen.dart';

/// Root launcher shell — hosts the SwipeNavigator with all 5 screens.
class LauncherShell extends ConsumerStatefulWidget {
  const LauncherShell({super.key});

  @override
  ConsumerState<LauncherShell> createState() => _LauncherShellState();
}

class _LauncherShellState extends ConsumerState<LauncherShell>
    with WidgetsBindingObserver {
  SwipeScreen _currentScreen = SwipeScreen.home;
  final GlobalKey<SwipeNavigatorState> _navigatorKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _enforceImmersive();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _enforceImmersive();
      // Coming back from another app: Android may have dropped the
      // swallow-external-touches flag with the old input listener, and a GATT
      // link can come back one-way — connected, but nothing arriving. Assert
      // both rather than trust them.
      unawaited(ref.read(ringGesturesProvider).resume());
      unawaited(ref.read(ringServiceProvider).probeNow());
      return;
    }
    // Backgrounding is NOT a reason to end a conversation. The display times
    // out while the wearer is still talking, and the agent backgrounds FOX-1
    // whenever it opens another app to work in — tearing down here would break
    // both. The session decides for itself, and only drops when genuinely idle.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      ref.read(aiSessionManagerProvider).onBackgrounded();
    }
  }

  void _enforceImmersive() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersive);
  }

  void _onScreenChanged(SwipeScreen screen) {
    setState(() => _currentScreen = screen);
    // Update Riverpod provider so AI screen can react reliably
    final active = switch (screen) {
      SwipeScreen.home => ActiveScreen.home,
      SwipeScreen.aiAgent => ActiveScreen.aiAgent,
      SwipeScreen.apps => ActiveScreen.apps,
      SwipeScreen.notifications => ActiveScreen.notifications,
      SwipeScreen.controls => ActiveScreen.controls,
    };
    ref.read(activeScreenProvider.notifier).state = active;
  }

  @override
  Widget build(BuildContext context) {
    // The agent standing down, or pressing home, hands the screen back to the
    // watch face — otherwise the launcher resurfaces on whatever page it was
    // left on, usually the agent screen it just dismissed itself from.
    ref.listen<int>(goHomeSignalProvider, (previous, next) {
      _navigatorKey.currentState?.goHome();
    });

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (_currentScreen != SwipeScreen.home) {
          _navigatorKey.currentState?.goHome();
        }
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0A0A0F),
        body: SwipeNavigator(
          key: _navigatorKey,
          onScreenChanged: _onScreenChanged,
          home: const WatchfaceScreen(),
          aiAgent: const AIAgentScreen(),
          apps: const AppsScreen(),
          notifications: const NotificationsScreen(),
          controls: const ControlsScreen(),
        ),
      ),
    );
  }
}
