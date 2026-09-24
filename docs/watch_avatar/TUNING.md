# Tuning reference

Every setting the avatar has. Generated from `src/param_specs.dart`, so it always matches the code.

A settings page reads a value with `controller.params.valueOf(key)` and writes one with
`controller.params = controller.params.withValue(key, value)`. Changes show on the next frame.
The one exception is **character**: change it with `params.switchCharacter(...)`, which also swaps to that character's colours unless the user has picked their own.

Values use the same types everywhere: colours are `Color`, choices are the enum values listed, numbers are `double`, toggles are `bool`. In JSON (`toJson` / `fromJson`, and the web tool's export) colours are `"#rrggbb"` strings and choices are their names.

"Both" means the setting affects bloub and the fox.

## Character

| Key | Label | Values | Default | Applies to | What it does |
|---|---|---|---|---|---|
| `character` | Character | bloub (Bloub), fox (Fox) | bloub | Both | Which character is on the device. Use AvatarParams.switchCharacter() to change it: it also swaps to the character's own colours, unless the user has picked colours of their own. |
| `layout` | Layout | screen (Screen is the face), figure (Face on a background) | screen | Both | Bloub: the whole screen is its face, or its face sits on the background colour. Fox: "screen" frames it more tightly. |

## Colour

| Key | Label | Values | Default | Applies to | What it does |
|---|---|---|---|---|---|
| `body` | Face | colour | #f2f2ec | Both | Bloub's face; the fox's fur. |
| `eye` | Eyes | colour | #0a0a0c | Both | Eyes, mouth, nose, tear and the time. |
| `bg` | Background | colour | #0a0a0c | Both | Behind the character. Bloub shows it only in the "Face on a background" layout; the fox always does. |
| `muzzle` | Cheeks and belly | colour | #ffffff | Fox | The fox's cream cheeks, belly and inner ears. |
| `boltLow` | Charging bolt | colour | #ff453a | Both | The bolt in the battery-cell eyes while charging or low. |
| `boltFull` | Full bolt | colour | #32d74b | Both | The bolt in the battery-cell eyes when fully charged. |

Defaults above are bloub's. The fox's own palette (`AvatarParams.fox`): fur `#e8823c`, eyes `#141010`, background `#0b0b0c`, cheeks and belly `#fbe7d2`.

**Palettes.** `kPalettes` holds the web tool's six colour schemes (Paper on ink, Ink on paper, Fox, Amber, Signal, Ash). `palette.applyTo(params)` sets all four main colours at once: the quickest way to offer colour on a small screen. For single colours, `kSwatches` is a short list that works well as tappable circles.

## Shape

| Key | Label | Values | Default | Applies to | What it does |
|---|---|---|---|---|---|
| `faceShape` | Face shape | circle (Circle), squircle (Rounded square) | circle | Bloub | Bloub's outline, seen in the "Face on a background" layout. |
| `radius` | Face size | 50 to 118, step 1 | 100 | Both | The character's size in design units. The picture is always scaled to fit the screen, so this mostly changes how much room the padding and the eyes take relative to the face. |
| `pad` | Padding | 0 to 60 px, step 1 | 12 | Both | Space around the character. Lower = bigger on screen. |
| `corner` | Corner sharpness | 2.2 to 9, step 0.1 | 4 | Bloub | For the rounded-square face: higher = squarer corners. |
| `wobble` | Edge wobble | 0 to 6, step 0.1 | 0.6 | Bloub | A hand-drawn wobble in bloub's outline. 0 = perfectly smooth. |

## Eyes

| Key | Label | Values | Default | Applies to | What it does |
|---|---|---|---|---|---|
| `eyeShape` | Eye shape | pill (Pill), round (Round), square (Rounded square) | pill | Both | The resting eye shape. Round and rounded square use the average of width and height, so they come out even. |
| `eyeW` | Eye width | 8 to 46, step 1 | 21 | Both | Eye width. The fox draws its eyes at 62% of this. |
| `eyeH` | Eye height | 8 to 64, step 1 | 44 | Both | Eye height. The fox draws its eyes at 62% of this. |
| `eyeAz` | Eye spread | 8 to 42 °, step 1 | 21 | Both | How far apart the eyes sit, as an angle around the head. |
| `eyeEl` | Eye height on face | -20 to 32 °, step 1 | 9 | Both | Where the eyes rest vertically. With "Eye height jump" on, they roam around this point. |

## Motion

| Key | Label | Values | Default | Applies to | What it does |
|---|---|---|---|---|---|
| `speed` | Speed | 0.2 to 3 ×, step 0.05 | 1 | Both | Speed of all motion. 1 = as designed. |
| `yaw` | Turn | 0 to 55 °, step 1 | 17 | Both | How far the head turns left and right. |
| `pitch` | Nod | 0 to 45 °, step 1 | 11 | Both | How far the head tips up and down. |
| `roll` | Tilt | 0 to 30 °, step 1 | 6 | Both | How far the head tilts sideways. |
| `drift` | Drift | 0 to 26 px, step 1 | 5 | Both | How much the whole character floats and bobs. |
| `blink` | Blink depth | 0 to 1, step 0.05 | 1 | Both | 0 = never blinks, 1 = full blinks. |
| `wander` | Wander | 0 to 1, step 0.05 | 0.6 | Both | Random glances around, on top of each state's own motion. 0 = none. They never repeat. |
| `glance` | Glance every | 0.5 to 4 s, step 0.1 | 1.5 | Both | Seconds between random glances. |
| `eyeJump` | Eye height jump | 0 to 100 %, step 5 | 100 | Both | How far the eyes jump up and down with each glance, as a share of their full range. 0 = eyes stay at their resting height. |
| `glanceStyle` | Glance style | smooth (Smooth), sharp (Sharp) | smooth | Both | Smooth: eased glances. Sharp: the head holds, then snaps to the next look, like a small robot. |

## Clock

| Key | Label | Values | Default | Applies to | What it does |
|---|---|---|---|---|---|
| `clock` | Show the time | on / off | on | Both | The time on the character: under bloub's eyes, on the fox's belly. |
| `clock24` | 24-hour time | on / off | on | Both | Off: 12-hour time with AM/PM. |

## Behaviour that isn't a setting

- **States** blend into each other over `controller.transition` (default 450 ms). When the eye changes shape (for example to hearts, or to battery cells) it happens during a blink, so the swap is never seen.
- **Each state starts from its own beginning** when entered: listening turns toward the voice, happy starts its hop.
- **Random glances** run on real time and never repeat. The tool's export length does not apply to the app.
- **The fox** draws its eyes at 62% of the eye size settings (1.2 times larger in battery states, so the bolt reads), and the time sits on its belly. **Bloub** shows the time under its eyes.
- **GIF settings** from the web tool (frame rate, size, length) are ignored by the app.
