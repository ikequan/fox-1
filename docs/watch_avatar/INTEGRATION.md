# Device avatar 1.0 — integration guide

Both characters (bloub and the fox), all 12 states, every design setting from
the web tool, smooth blending between states, and everything a settings page
needs. Drawn live on a Canvas: sharp at native resolution, no image assets, no
packages.

**How this build was checked.** The motion code was converted back to
JavaScript and compared against the web design tool's own output: 199,404
values across both characters, all 12 states and 7 combinations of settings,
with no mismatches. The settings list, ranges and defaults were checked against
the tool too. It has **not** been compiled by its author (no Dart toolchain was
available), so step 2 below catches anything left. The drawing code follows the
patterns of the fox build (0.2.0) that already compiled and passed on the device.

## 1. Replace the old module

1. Delete `lib/fox_avatar/`.
2. Copy this folder in as `lib/watch_avatar/`.
3. Change the import:

   ```dart
   import 'watch_avatar/watch_avatar.dart';
   ```

The old names still work (`FoxAvatar`, `FoxAvatarController`,
`FoxPerfOverlay`), so existing code compiles unchanged. New code should use
`WatchAvatar`, `AvatarController` and `AvatarPerfOverlay`.

## 2. Check it compiles

```sh
flutter analyze lib/watch_avatar
```

Fix only genuine compile errors, and report what you changed. Do not change the
motion maths in `src/rig.dart` or the shapes and colours in the painters: they
are verified against the design tool. `rig.dart` is also written in a plain
style so it can be re-checked against the tool automatically; keep that style.

## 3. Show it

```dart
final avatar = AvatarController();                // create once, keep it

WatchAvatar(controller: avatar)                    // fills its box
```

The widget paints its own background, so it can fill the screen directly.
Give it a **bounded size** (full screen, or a `SizedBox`). It uses
`SizedBox.expand`, so it can't sit directly inside a `Column` or a scroll view.

## 4. Drive the states

```dart
avatar.state = AvatarState.charging;
```

Changes blend over `avatar.transition` (default 450 ms). Each state starts from
its own beginning when entered. Suggested wiring:

| Event                                   | State                          |
|-----------------------------------------|--------------------------------|
| plugged in, below 100%                  | `charging`                     |
| plugged in, at 100%                     | `fullBattery`                  |
| unplugged, at or below your low mark    | `lowBattery` (e.g. 15%)        |
| voice input open                        | `listening`                    |
| assistant replying                      | `speaking`                     |
| waiting on a result                     | `thinking`                     |
| no interaction for a while              | `sleeping` (e.g. 2 minutes)    |
| error, failed action                    | `sad` (for a few seconds)      |
| success, goal reached                   | `happy` (for a few seconds)    |
| a message from a favourite contact      | `love` (for a few seconds)     |
| input not understood                    | `confused` (for a few seconds) |
| otherwise                               | `idle`                         |

When two apply, pick in a fixed priority order, for example: listening /
speaking / thinking, then the brief reactions, then battery, then sleeping,
then idle. `AvatarState.values` lists them all, and each has `.label` for
debug menus.

## 5. Settings pages

All design settings live in `avatar.params`, an immutable `AvatarParams`.
Read and write any one by its key:

```dart
final size = avatar.params.valueOf('radius') as double;
avatar.params = avatar.params.withValue('radius', 90.0);
avatar.params = avatar.params.withValue('eyeShape', EyeShape.round);
avatar.params = avatar.params.withValue('body', const Color(0xFFFFB457));
avatar.params = avatar.params.switchCharacter(Character.fox);  // character: use this
avatar.params = kPalettes[3].applyTo(avatar.params);            // a whole palette
```

**What there is to tune** is in `TUNING.md`: every setting with its key,
range, default, which character it affects, and what it does.

**To build pages from data**, use `kParamSpecs`. Each `ParamSpec` has the key,
label, group, kind (colour / choice / number / toggle), slider range, step and
unit, the choices for a picker, whether it applies to bloub or the fox, and a
help sentence. `kParamGroups` gives the groups in order; hide specs where
`!spec.appliesTo(avatar.params.character)`.

**Or use the ready-made list**, `AvatarSettingsList(controller: avatar)`: every
setting with the right control, grouped, live. Pass `groups: ['Colour']` for a
single page. It uses Material widgets; restyle it or read it as a reference.
It lives in its own file (`src/settings_list.dart`), so if the app doesn't use
Material you can delete that file and its export line.

**Saving.** `avatar.params.toJson()` gives a small map; store it however the app
stores settings, and restore with `AvatarParams.fromJson(map)`. Unknown or
malformed values fall back to defaults, so old saves never break.

**Designs from the web tool.** The tool's **Settings for the app** button
downloads `avatar-settings.json` in exactly this format:
`AvatarParams.fromJson(jsonDecode(text))` loads it. **Load settings** in the
tool takes a file saved from the app, so a design can go either way.

## 6. Keep it fast

- Create `AvatarController` once. Setting `params` rebuilds the fox's cached
  layers, which is fine on a settings page but not every frame.
- Don't wrap the avatar in `Opacity`, `ShaderMask`, `BackdropFilter` or
  animated clips: each forces an extra offscreen pass every frame.
- It caps at 30 fps (`cap30`) and pauses itself when the app is backgrounded.
  Set `avatar.paused = true` while another screen covers it.
- `lite: true` draws the fox with flat colours. It isn't needed on this device
  (full passed), but it's there as a fallback.

## 7. Test

Wrap the avatar with the test overlay (remove it before shipping):

```dart
AvatarPerfOverlay(controller: avatar, child: WatchAvatar(controller: avatar))
```

**Looks.** Step through all 12 states for each character and compare with
`reference/fox-all-states.png` and `reference/bloub-all-states.png` (320 x 385,
the device's size). Positions will differ slightly, since everything is
moving; shapes, colours, framing and the time's position should match.

**Transitions.** Switch between states quickly. Nothing should jump. When the
eyes change shape (idle to happy, anything to love, into and out of the
battery states), the swap happens during a blink.

**Settings.** Change a few settings in each group and check the avatar follows
at once. Switch character both ways: default colours should swap, and
hand-picked colours should stay.

**Performance** (profile mode, full quality, 30 fps cap, nothing else animating,
60 s each), for:

| Character | State      | fps (lowest) | raster avg / worst | build avg / worst |
|-----------|------------|--------------|--------------------|-------------------|
| fox       | idle       |              |                    |                   |
| fox       | charging   |              |                    |                   |
| fox       | love       |              |                    |                   |
| bloub     | idle       |              |                    |                   |
| bloub     | charging   |              |                    |                   |
| bloub     | speaking   |              |                    |                   |

Pass: the same bar as before. Average fps at least 29 with no second below 27,
raster average at most 20 ms, worst at most 33 ms.

## 8. What to send back

The analyze result and any fixes, a screenshot of each state for each
character (`adb exec-out screencap -p > state.png`), the performance table,
the Flutter version and `watchAvatarVersion`.

## Files

| File                         | What it is                                               |
|------------------------------|----------------------------------------------------------|
| `watch_avatar.dart`          | the public API; import only this                          |
| `TUNING.md`                  | every setting, what it does, its range and default        |
| `reference/`                 | how every state should look, at 320 x 385                 |
| `src/state.dart`             | `AvatarState`, with the tool's names and labels           |
| `src/params.dart`            | `AvatarParams`: every setting, JSON in the tool's format  |
| `src/param_specs.dart`       | `kParamSpecs`, palettes and swatches, for settings pages  |
| `src/settings_list.dart`     | optional ready-made settings list (Material)              |
| `src/controller.dart`        | `AvatarController`: state, params, cap, pause, lite       |
| `src/watch_avatar_widget.dart` | the widget: clock, transitions, lifecycle               |
| `src/rig.dart`               | the motion maths, a verified port of the design tool      |
| `src/bloub_painter.dart`     | bloub, drawn flat each frame                              |
| `src/fox_painter.dart`       | the fox: shaded layers baked once, moved per frame        |
| `src/shapes.dart`            | eye shapes, bolt, bloub's outline, time format            |
| `src/frame.dart`             | the per-frame pose notifier                               |
| `src/perf_overlay.dart`      | testing aid only                                          |
