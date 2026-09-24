import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../providers/providers.dart';
import '../watch_avatar/watch_avatar.dart';
import '../widgets/mascot.dart';

/// Every design setting of the live mascot — colours, shape, eyes, motion,
/// clock — with a live preview on top. The list itself is `watch_avatar`'s
/// own [AvatarSettingsList], built from the web tool's settings, so nothing
/// here has to be kept in step with it.
///
/// Changes are saved as they are made (a moment after the last one), as the
/// web tool's own JSON under `avatar_params`. Switching character here
/// switches the mascot too: they are the same choice.
class AvatarDesignScreen extends ConsumerStatefulWidget {
  const AvatarDesignScreen({super.key});

  @override
  ConsumerState<AvatarDesignScreen> createState() => _AvatarDesignScreenState();
}

class _AvatarDesignScreenState extends ConsumerState<AvatarDesignScreen> {
  late final AvatarController _avatar;

  // Captured here, never read through `ref` in dispose.
  late final StateController<AvatarParams> _design;
  late final StateController<Mascot> _mascot;
  Timer? _saveSoon;
  AvatarParams? _unsaved;

  @override
  void initState() {
    super.initState();
    _design = ref.read(avatarParamsProvider.notifier);
    _mascot = ref.read(mascotProvider.notifier);
    _avatar = AvatarController(params: ref.read(liveAvatarParamsProvider));
    _avatar.addListener(_changed);
  }

  void _changed() {
    final p = _avatar.params;
    _design.state = p;
    final want = p.character == Character.fox ? Mascot.fox : Mascot.bloub;
    if (_mascot.state != want) _mascot.state = want;
    _unsaved = p;
    // Sliders change many times a second; save once they settle.
    _saveSoon?.cancel();
    _saveSoon = Timer(const Duration(milliseconds: 400), _save);
  }

  Future<void> _save() async {
    final p = _unsaved;
    if (p == null) return;
    _unsaved = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('avatar_params', jsonEncode(p.toJson()));
    await prefs.setString('mascot', _mascot.state.name);
  }

  Future<void> _reset() async {
    final fox = _avatar.params.character == Character.fox;
    _avatar.params = fox ? AvatarParams.fox : const AvatarParams();
  }

  @override
  void dispose() {
    _saveSoon?.cancel();
    unawaited(_save());
    _avatar.removeListener(_changed);
    _avatar.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0A0A),
        title: const Text('Mascot design', style: TextStyle(fontSize: 16)),
        actions: [
          TextButton(
            onPressed: _reset,
            child: const Text('Reset',
                style: TextStyle(color: Color(0xFF00E5CC), fontSize: 13)),
          ),
        ],
      ),
      body: Column(
        children: [
          SizedBox(height: 140, child: WatchAvatar(controller: _avatar)),
          Expanded(
            child: Theme(
              data: ThemeData.dark(useMaterial3: true),
              child: AvatarSettingsList(controller: _avatar),
            ),
          ),
        ],
      ),
    );
  }
}
