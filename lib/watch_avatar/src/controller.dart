import 'package:flutter/foundation.dart';

import 'params.dart';
import 'state.dart';

/// What your app talks to. Set [state] from battery, voice and inactivity
/// events, and [params] from the settings pages; the avatar picks both up on
/// the next frame and blends into a new state rather than jumping.
class AvatarController extends ChangeNotifier {
  AvatarController({
    AvatarState state = AvatarState.idle,
    AvatarParams params = const AvatarParams(),
    bool lite = false,
    bool cap30 = true,
    bool paused = false,
    this.transition = const Duration(milliseconds: 450),
  })  : _state = state,
        _params = params,
        _lite = lite,
        _cap30 = cap30,
        _paused = paused;

  AvatarState _state;
  AvatarParams _params;
  bool _lite, _cap30, _paused;

  /// How long a change of state takes to blend in.
  Duration transition;

  AvatarState get state => _state;
  set state(AvatarState value) {
    if (value == _state) return;
    _state = value;
    notifyListeners();
  }

  /// Every design setting: colours, character, shape, motion, clock.
  AvatarParams get params => _params;
  set params(AvatarParams value) {
    if (value == _params) return;
    _params = value;
    notifyListeners();
  }

  /// Flat colours instead of the fox's shading: a fallback for slow devices.
  /// (Bloub is flat already.)
  bool get lite => _lite;
  set lite(bool value) {
    if (value == _lite) return;
    _lite = value;
    notifyListeners();
  }

  /// Draw at most 30 frames a second (default). Halves GPU work and battery
  /// use; this motion looks the same at 30 as at 60.
  bool get cap30 => _cap30;
  set cap30(bool value) {
    if (value == _cap30) return;
    _cap30 = value;
    notifyListeners();
  }

  /// Stop drawing, e.g. while another screen covers the avatar. The widget
  /// also pauses itself when the app goes to the background.
  bool get paused => _paused;
  set paused(bool value) {
    if (value == _paused) return;
    _paused = value;
    notifyListeners();
  }
}
