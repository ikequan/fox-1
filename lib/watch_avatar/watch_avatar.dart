/// Watch avatar: bloub and the fox, every state, every design setting.
/// Import this one file:
///
///   import 'watch_avatar/watch_avatar.dart';
library;

import 'src/controller.dart';
import 'src/perf_overlay.dart';
import 'src/state.dart';
import 'src/watch_avatar_widget.dart';

export 'src/controller.dart' show AvatarController;
export 'src/param_specs.dart'
    show ParamSpec, ParamKind, ParamChoice, kParamSpecs, kParamGroups, paramSpec,
        AvatarPalette, kPalettes, kSwatches;
export 'src/params.dart'
    show AvatarParams, Character, Layout, FaceShape, EyeShape, GlanceStyle;
export 'src/perf_overlay.dart' show AvatarPerfOverlay, AvatarPerfSample;
export 'src/settings_list.dart' show AvatarSettingsList;
export 'src/state.dart' show AvatarState, AvatarStateInfo;
export 'src/watch_avatar_widget.dart' show WatchAvatar;

/// Build of this module; include it when reporting test results.
const String watchAvatarVersion = '1.0.0';

// ---- names from the fox-only builds (0.1 / 0.2), so existing code compiles
typedef FoxAvatar = WatchAvatar;
typedef FoxAvatarController = AvatarController;
typedef FoxPerfOverlay = AvatarPerfOverlay;

/// Every state is animated now.
final Set<AvatarState> animatedStates = AvatarState.values.toSet();
