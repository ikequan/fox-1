import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/call/call_transfer.dart';

/// The current hand-over, if any. Written by whoever owns the
/// [CallTransferController]; read by the overlay below.
final transferStateProvider = StateProvider<TransferState>(
  (ref) => const TransferState(phase: TransferPhase.none),
);

/// What the wearer does about it. Set by the overlay, acted on by the owner.
final transferActionProvider = StateProvider<TransferAction?>((ref) => null);

enum TransferAction { take, sendBack }

/// Full-screen prompt: a real person is on the line, right now.
///
/// Deliberately app-wide rather than a route, because a call does not care
/// which screen the wearer is looking at, and it must not be dismissable by a
/// stray swipe — the only ways out are the two buttons or the timeout.
class TransferPromptOverlay extends ConsumerWidget {
  const TransferPromptOverlay({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(transferStateProvider);
    return Stack(
      children: [
        child,
        if (t.isWaiting)
          Positioned.fill(
            child: _Prompt(state: t, ref: ref),
          ),
      ],
    );
  }
}

class _Prompt extends StatelessWidget {
  const _Prompt({required this.state, required this.ref});

  final TransferState state;
  final WidgetRef ref;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF0A0A0F),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text('ON THE LINE',
                  style: TextStyle(
                      color: Color(0xFF00E5CC),
                      fontSize: 11,
                      letterSpacing: 2)),
              const SizedBox(height: 8),
              Text(
                state.who,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              // The countdown is the honest part: it tells the wearer the
              // caller is not waiting indefinitely.
              Text('back to the agent in ${state.secondsLeft}s',
                  style: const TextStyle(color: Colors.white38, fontSize: 11)),
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF00C853),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  onPressed: () => ref
                      .read(transferActionProvider.notifier)
                      .state = TransferAction.take,
                  child: const Text('Take call',
                      style: TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w600)),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  onPressed: () => ref
                      .read(transferActionProvider.notifier)
                      .state = TransferAction.sendBack,
                  child: const Text('Back to agent',
                      style: TextStyle(fontSize: 13, color: Colors.white70)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
