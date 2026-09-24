import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart';

import '../providers/providers.dart';
import '../services/notes/note_store.dart';
import '../services/notes/ring_notes.dart';
import '../services/platform/system_actions_service.dart';
import '../services/ring/ring_service.dart';

/// The wearer's view of the smart ring, in Settings. Plain words only — no
/// addresses, opcodes or logs; those live in Developer → Ring test.
///
/// Usually there is nothing to do here: a ring Android already knows is
/// paired automatically at boot. "Pair ring" covers the rest.
class RingSettingsCard extends ConsumerStatefulWidget {
  const RingSettingsCard({super.key});

  @override
  ConsumerState<RingSettingsCard> createState() => _RingSettingsCardState();
}

class _RingSettingsCardState extends ConsumerState<RingSettingsCard>
    with WidgetsBindingObserver {
  static const _accent = Color(0xFF00E5CC);
  static const _amber = Color(0xFFFFB74D);

  late RingService _ring;
  StreamSubscription<void>? _sub;
  String? _message;

  /// Whether Android lets the device keep its network while idle. Null until
  /// asked; re-asked whenever the app comes back from Android's prompt.
  bool? _background;

  late RingNotes _notes;
  final _noteSubs = <StreamSubscription<void>>[];
  int _noteCount = 0, _noteWaiting = 0;

  @override
  void initState() {
    super.initState();
    _ring = ref.read(ringServiceProvider);
    _sub = _ring.changes.listen((_) {
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.addObserver(this);
    _checkBackground();
    _notes = ref.read(ringNotesProvider);
    _noteSubs
      ..add(_notes.store.changes.listen((_) => _countNotes()))
      ..add(_notes.puller.changes.listen((_) {
        if (mounted) setState(() {});
      }));
    _countNotes();
  }

  Future<void> _countNotes() async {
    final all = await _notes.store.all();
    if (!mounted) return;
    setState(() {
      _noteCount = all.length;
      _noteWaiting = all.where((n) => n.status == NoteStatus.pending).length;
    });
  }

  String _notesLine() {
    final moving = _notes.puller.status != null;
    if (_noteCount == 0 && !moving) {
      return 'Quadruple-tap the ring to record a voice note, and again to stop.';
    }
    return [
      'Voice notes: $_noteCount',
      if (_noteWaiting > 0) '$_noteWaiting transcribing',
      if (moving) 'moving from the ring',
    ].join(' · ');
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sub?.cancel();
    for (final s in _noteSubs) {
      s.cancel();
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _checkBackground();
  }

  Future<void> _checkBackground() async {
    final ok = await SystemActionsService.backgroundAllowed();
    if (mounted && ok != _background) setState(() => _background = ok);
  }

  Future<void> _pair() async {
    setState(() => _message = null);
    // Scanning needs location on Android 8–11 and the Bluetooth permissions
    // from 12; ask here, where the wearer can see why.
    await [
      Permission.location,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
    ].request();
    final m = await _ring.findAndPair();
    if (mounted) setState(() => _message = m);
  }

  Future<void> _forget() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text('Forget this ring?',
            style: TextStyle(color: Colors.white, fontSize: 15)),
        content: const Text(
            'The device stops connecting to it. Health history already on the '
            'device stays.',
            style: TextStyle(color: Colors.white70, fontSize: 13)),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(c).pop(false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.of(c).pop(true),
              child: const Text('Forget', style: TextStyle(color: Colors.redAccent))),
        ],
      ),
    );
    if (yes != true) return;
    await _ring.forget();
    if (mounted) setState(() => _message = 'Ring forgotten.');
  }

  String _when(DateTime t) {
    final now = DateTime.now();
    final sameDay = t.year == now.year && t.month == now.month && t.day == now.day;
    return sameDay ? 'at ${DateFormat('HH:mm').format(t)}' : DateFormat('d MMM HH:mm').format(t);
  }

  @override
  Widget build(BuildContext context) {
    final r = _ring;
    final paired = r.paired;
    final (status, color) = !paired
        ? (r.searching ? 'Searching…' : 'Not paired', Colors.white38)
        : switch (r.link) {
            RingLink.ready => ('Connected', _accent),
            RingLink.connecting => ('Connecting…', _amber),
            RingLink.idle => ('Reconnecting…', _amber),
            RingLink.unpaired => ('Not paired', Colors.white38),
          };

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.trip_origin, color: color, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  paired && r.name.isNotEmpty ? r.name : 'Smart ring',
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(status, style: TextStyle(color: color, fontSize: 12)),
            ],
          ),
          const SizedBox(height: 6),
          if (paired)
            Text(
              [
                if (r.battery != null)
                  'Battery ${r.battery}%${r.charging ? ', charging' : ''}',
                r.syncing
                    ? 'Syncing…'
                    : r.lastSync == null
                        ? 'Not synced yet'
                        : 'Synced ${_when(r.lastSync!)}',
              ].join(' · '),
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            )
          else
            Text(
              r.setupStatus ??
                  'Pair your ring for hold-to-talk and health tracking.',
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
          if (paired || _noteCount > 0) ...[
            const SizedBox(height: 4),
            Text(_notesLine(),
                style: const TextStyle(color: Colors.white54, fontSize: 12)),
          ],
          // Without the exemption, a hold with the screen off can find no
          // network: Android cuts it while the device idles.
          if (paired && _background == false) ...[
            const SizedBox(height: 8),
            const Text(
              'Hold-to-talk with the screen off needs background access.',
              style: TextStyle(color: _amber, fontSize: 12),
            ),
            const SizedBox(height: 4),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  foregroundColor: _amber,
                  side: const BorderSide(color: Colors.white24),
                  minimumSize: const Size(0, 36),
                ),
                onPressed: SystemActionsService.allowBackground,
                child: const Text('Allow background access',
                    style: TextStyle(fontSize: 13)),
              ),
            ),
          ],
          if (_message != null) ...[
            const SizedBox(height: 6),
            Text(_message!, style: const TextStyle(color: Colors.white70, fontSize: 12)),
          ],
          const SizedBox(height: 10),
          if (!paired)
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: _accent,
                foregroundColor: const Color(0xFF0A0A0A),
                minimumSize: const Size(double.infinity, 40),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: r.searching ? null : _pair,
              child: Text(r.searching ? 'Searching…' : 'Pair ring',
                  style: const TextStyle(fontSize: 13)),
            )
          else
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _accent,
                      side: const BorderSide(color: Colors.white24),
                      minimumSize: const Size(0, 38),
                    ),
                    onPressed: r.ready && !r.syncing ? () => r.sync() : null,
                    child: const Text('Sync now', style: TextStyle(fontSize: 13)),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextButton(
                    onPressed: _forget,
                    child: const Text('Forget',
                        style: TextStyle(color: Colors.redAccent, fontSize: 13)),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
