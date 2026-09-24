import 'dart:async';

import 'package:flutter/foundation.dart';

import '../platform/system_actions_service.dart';
import '../session/ai_session.dart';
import 'call_orchestrator.dart';
import 'call_report.dart';
import 'pending_reports.dart';

/// Gets a finished call's message to the wearer.
///
/// A call ends and somebody is owed the news. The device cannot know whether the
/// wearer is looking at it, so it tries and then waits:
///
///  1. queue the message, so it cannot be lost by trying at a bad moment
///  2. buzz once and wake the screen — "look at your wrist", not an alarm
///  3. wake the main agent if it is asleep, and hand it the message to pass on
///  4. if nobody says anything back, stand down and leave it queued
///
/// Step 4 is the one that matters. The failure this avoids is an assistant that
/// announces something to an empty room and considers it delivered.
class WearerBriefer implements PendingSink {
  WearerBriefer({
    required this.pending,
    required this.wakeAgent,
    required this.wearerName,
    required this.isAgentAwake,
  });

  final PendingReports pending;

  /// Brings the main agent up and returns it. Null if it cannot start — no
  /// API key, no network — in which case the message stays queued.
  final Future<AISession?> Function() wakeAgent;

  final String Function() wearerName;
  final bool Function() isAgentAwake;

  /// How long to give the wearer to answer before deciding they are not there.
  ///
  /// Long enough to get a wrist up and say something; short enough that a device
  /// left on a desk is not sitting there listening.
  static const _waitForWearer = Duration(seconds: 25);

  Timer? _giveUp;
  bool _delivering = false;

  @override
  Future<void> onReport(CallReport r) async {
    await pending.load();
    await pending.add(r);
    await deliver(reason: 'a call just ended');
  }

  /// Try to pass on whatever is queued.
  ///
  /// Safe to call whenever the wearer might be there — after a call, and when
  /// they start talking to the agent themselves.
  Future<void> deliver({required String reason}) async {
    await pending.load();
    if (pending.isEmpty || _delivering) return;
    _delivering = true;
    try {
      if (!isAgentAwake()) {
        // Nudge first: waking the agent takes a moment, and a buzz that
        // arrives after it has already started speaking is just confusing.
        await SystemActionsService.nudge();
      }

      // wakeAgent opens a WebSocket, and that can fail — a dead network, a
      // Gemini setup timeout. It used to throw straight past this method and
      // out into the zone as a bare "TimeoutException: Future not completed",
      // which read like a crash and said nothing about the message it lost.
      // The message survives either way; what was missing was saying so.
      AISession? session;
      try {
        session = await wakeAgent();
      } catch (e) {
        debugPrint('[BRIEF] could not wake the agent ($e) — message stays '
            'queued for next time');
        return;
      }
      if (session == null) {
        debugPrint('[BRIEF] could not wake the agent — message stays queued');
        return;
      }

      session.tell(pending.briefing(wearer: wearerName()));
      debugPrint('[BRIEF] handed ${pending.length} message(s) to the agent'
          ' ($reason)');

      // The agent has been told. Whether the *wearer* heard it is a different
      // question, and the only honest answer is whether they said anything.
      //
      // An earlier version cleared the queue immediately when the agent was
      // already awake, on the theory that the message went into a live
      // conversation. It does not follow — the agent being warm is not the
      // wearer being present, and on the first real test that shortcut marked
      // two messages delivered that nobody ever heard.
      _giveUp?.cancel();
      _giveUp = Timer(_waitForWearer, () async {
        _giveUp = null;
        if (isAgentAwake() && _heardFromWearer) {
          await pending.clear();
          return;
        }
        debugPrint('[BRIEF] no answer — the message waits for next time');
        // Deliberately not cleared. It goes out on the next conversation.
      });
    } finally {
      _delivering = false;
    }
  }

  bool _heardFromWearer = false;

  /// Call when the wearer says something. Confirms the message landed on ears
  /// rather than on an empty room.
  Future<void> noteWearerSpoke() async {
    _heardFromWearer = true;
    if (_giveUp != null) {
      _giveUp!.cancel();
      _giveUp = null;
      await pending.clear();
    }
  }

  void reset() {
    _heardFromWearer = false;
  }

  void dispose() {
    _giveUp?.cancel();
    _giveUp = null;
  }
}
