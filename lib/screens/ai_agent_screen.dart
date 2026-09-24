import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../config/constants.dart';
import '../providers/providers.dart';
import '../services/platform/screen_automation_service.dart';
import '../services/session/ai_session.dart';
import '../services/session/ai_session_manager.dart';
import '../widgets/live_mascot.dart';
import '../widgets/mascot.dart';

/// Observes the shared [AISession] — it no longer creates or destroys it.
/// Entering the screen wakes the session (resuming the previous conversation);
/// leaving drops it to warm, and it goes cold on its own after a short idle.
class AIAgentScreen extends ConsumerStatefulWidget {
  const AIAgentScreen({super.key});

  @override
  ConsumerState<AIAgentScreen> createState() => _AIAgentScreenState();
}

class _AIAgentScreenState extends ConsumerState<AIAgentScreen> {
  String _statusText = '';
  String _lastTranscript = '';
  bool _visionActive = false;
  bool _accessibilityChecked = false;

  final List<StreamSubscription> _subs = [];
  AISession? _observed;

  @override
  void dispose() {
    _detach();
    super.dispose();
  }

  void _detach() {
    for (final sub in _subs) {
      sub.cancel();
    }
    _subs.clear();
    _observed = null;
  }

  Future<void> _enter() async {
    final manager = ref.read(aiSessionManagerProvider);

    if (ref.read(geminiApiKeyProvider).isEmpty) {
      setState(() => _statusText = 'Set API key in Settings');
      _mood(MascotMood.idle);
      return;
    }

    setState(() => _statusText = 'Connecting...');
    _mood(MascotMood.thinking);

    await _warnIfAccessibilityOff();

    try {
      // Subscribe BEFORE waking. sessionState is a broadcast stream with no
      // replay, so attaching afterwards misses the very events that clear
      // "Connecting..." — which left this screen stuck permanently.
      final session = await manager.ensureSession();
      if (session == null || !mounted) return;
      _attach(session);

      await manager.wake();
    } catch (e) {
      if (!mounted) return;
      setState(() => _statusText = 'Error: ${e.toString().split('\n').first}');
      _mood(MascotMood.confused);
    }
  }

  Future<void> _warnIfAccessibilityOff() async {
    if (_accessibilityChecked) return;
    _accessibilityChecked = true;
    final enabled = await ScreenAutomationService().isServiceEnabled();
    if (!enabled && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Accessibility service disabled — screen automation unavailable',
          ),
          duration: Duration(seconds: 3),
        ),
      );
    }
  }

  /// Subscribing is cheap and idempotent — the session outlives this widget, so
  /// we attach on entry and detach on exit without touching its lifecycle.
  void _attach(AISession session) {
    if (identical(_observed, session) && _subs.isNotEmpty) return;
    _detach();
    _observed = session;

    _subs.add(session.sessionState.listen(_applyState));

    _subs.add(
      session.visionState.listen((active) {
        if (!mounted) return;
        setState(() => _visionActive = active);
        ref.read(visionActiveProvider.notifier).state = active;
      }),
    );

    _subs.add(
      session.transcript.listen((entry) {
        if (!mounted) return;
        setState(() {
          _lastTranscript = entry.text;
          if (entry.role == TranscriptRole.assistant) _statusText = '';
        });
        Future.delayed(AppConstants.transcriptLinger, () {
          if (mounted && _lastTranscript == entry.text) {
            setState(() {
              _lastTranscript = '';
              if (session.isListening) _statusText = 'Listening...';
            });
          }
        });
      }),
    );

    // What the mascot does — speaking, thinking, listening — is
    // `AISessionManager`'s job now: the watch face shows it too, and this
    // screen is often not even built when a conversation starts.

    // Render whatever the session already is, so the UI never depends on having
    // caught a past event.
    _applyState(session.currentState);
    if (session.isVisionActive != _visionActive) {
      setState(() => _visionActive = session.isVisionActive);
    }
  }

  /// Only the words under the mascot: the mascot itself follows
  /// [mascotStateProvider], off the same session stream.
  void _applyState(AISessionState state) {
    if (!mounted) return;
    setState(
      () => _statusText = switch (state) {
        AISessionState.starting => 'Connecting...',
        AISessionState.active => 'Listening...',
        AISessionState.onCall => 'On a call',
        AISessionState.error => 'Error',
        AISessionState.warm || AISessionState.stopped => '',
      },
    );
  }

  void _mood(MascotMood state) =>
      ref.read(mascotStateProvider.notifier).state = state;

  Future<void> _leave() async {
    _detach();
    await ref.read(aiSessionManagerProvider).goWarm();
    if (!mounted) return;
    setState(() {
      _statusText = '';
      _lastTranscript = '';
    });
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final mood = ref.watch(mascotStateProvider);

    // PageView keeps off-screen children alive, so screen presence comes from
    // the provider rather than widget visibility.
    ref.listen<ActiveScreen>(activeScreenProvider, (prev, next) {
      if (next == ActiveScreen.aiAgent && prev != ActiveScreen.aiAgent) {
        _enter();
      } else if (next != ActiveScreen.aiAgent && prev == ActiveScreen.aiAgent) {
        _leave();
      }
    });

    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF0F0505), Color(0xFF0A0A0F)],
        ),
      ),
      child: Stack(
        children: [
          const Positioned.fill(
            child: LiveMascot(screen: ActiveScreen.aiAgent),
          ),

          // The agent can open the camera itself, so the wearer must be able to
          // see when it is watching.
          if (_visionActive)
            Positioned(
              top: size.height * 0.06,
              left: 0,
              right: 0,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(
                      color: Color(0xFFFF3B30),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  const Text(
                    'Camera on',
                    style: TextStyle(color: Color(0xFFFF3B30), fontSize: 11),
                  ),
                ],
              ),
            ),

          if (_statusText.isNotEmpty)
            Positioned(
              left: 16,
              right: 16,
              bottom: size.height * 0.1,
              child: Text(
                _statusText,
                style: TextStyle(
                  color: mood == MascotMood.idle
                      ? Colors.white30
                      : const Color(0xFF00E5CC),
                  fontSize: 12,
                ),
                textAlign: TextAlign.center,
              ),
            ),

          if (_lastTranscript.isNotEmpty)
            Positioned(
              left: 16,
              right: 16,
              bottom: size.height * 0.04,
              child: Text(
                _lastTranscript,
                style: const TextStyle(color: Colors.white60, fontSize: 11),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ),
    );
  }
}
