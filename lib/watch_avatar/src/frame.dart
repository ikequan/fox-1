import 'package:flutter/foundation.dart';

import 'rig.dart';

/// The current pose and quality, published once per drawn frame.
class PoseFrame extends ChangeNotifier {
  PoseFrame(this._pose);
  AvatarPose _pose;
  bool _lite = false;

  AvatarPose get pose => _pose;
  bool get lite => _lite;

  void update(AvatarPose pose) {
    _pose = pose;
    notifyListeners();
  }

  set lite(bool value) {
    if (value == _lite) return;
    _lite = value;
    notifyListeners();
  }
}
