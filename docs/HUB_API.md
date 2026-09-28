# FOX-1 Hub API

The device serves FOX-1 Hub — a mobile-first web app for setup and the wearer's notes,
health, conversations, memory and settings — at `http://<device-ip>:8080`
while it is on. The frontend is static files in `assets/portal/`; everything
below is JSON served by `SettingsServer` + `PortalApi` on the device.

## Access

- **Off by default — except during first-time setup**, when it is on and
  held on until setup is done (see *Setup*). Otherwise on from Controls → Hub,
  Settings → FOX-1 Hub, or by asking the assistant ("open the Hub"). It turns itself off after
  **30 minutes without a signed-in request**, and every session ends with it.
  Background refreshes send `X-Portal-Poll: 1` and do not count — a tab left
  open must not keep the Hub on for ever. (The header keeps its old name.)
- A **6-digit PIN**, new each time the Hub is turned on, shown on the
  device. The QR code on the device carries it as `#pin=123456` — a URL
  fragment never reaches the server, so it is never logged.
- `POST /api/auth` `{"pin":"123456"}` →
  - `200 {"ok":true}` and cookie `cp_session` (HttpOnly, SameSite=Strict).
  - `401 {"ok":false,"error":"Wrong PIN","retryIn":0}`.
  - After 5 wrong in a row: `429 {"ok":false,"error":"Too many tries","retryIn":60}`
    (seconds; doubles on each further lockout).
- `GET /api/session` → `200 {"ok":true}` when signed in, else 401.
- `POST /api/logout` → `{"ok":true}`; the cookie stops working.
- Public without a session: `/`, `/portal.css`, `/portal.js`, `/icon.svg`,
  `/api/auth`, `/api/session`. Every other `/api/*` answers
  `401 {"ok":false,"error":"sign in"}`; the older HTML pages (`/logs`,
  `/ring`, …) redirect to `/#/login`.

## Conventions

- Times are local ISO-8601 without a zone: `"2026-09-13T20:08:16.000"`.
  Days are `"YYYY-MM-DD"`. Durations are whole seconds.
- Errors: `{"ok":false,"error":"…"}` with a 4xx/5xx status.
- Optional fields may be absent or `null`; clients treat both alike.

## Overview

`GET /api/overview`

```json
{
  "watch": {"battery": 78, "charging": false, "now": "2026-09-13T20:12:32.000"},
  "ring": {
    "paired": true, "name": "SR116-0767",
    "link": "ready",            // ready | connecting | idle | unpaired
    "battery": 42,              // null until read
    "lastSync": "2026-09-13T19:59:38.000",
    "lastSyncSummary": "359 heart · 116 step · 372 sleep records over 2 day(s)",
    "liveSteps": 3911
  },
  "today": DaySummary | null,
  "notes": {"count": 6, "waiting": 0, "failed": 0, "silent": 8, "recent": [NoteBrief, NoteBrief, NoteBrief]},
  "memory": {"facts": 45, "claims": 2},
  "conversations": {"today": 3, "last": "2026-09-13T20:12:27.000"},
  "callAgent": {"onDuty": false},
  "assistant": {"name": "FOX-1", "model": "models/gemini-3.8-live", "voice": "Kore"},   // name: Settings → Name
  "portal": {"address": "http://192.168.1.23:8080", "closesAt": "2026-09-13T20:45:00.000"}
}
```

## Voice notes

```
NoteBrief = {
  "id": "ring_20260913_200816",
  "recordedAt": "2026-09-13T20:08:16.000",
  "duration": 21,
  "status": "done",               // pending | done | failed
  "silent": false,                // transcribed, and nothing was said
  "title": "Ring Recording Test and HR Follow-Up",   // null until transcribed
  "summary": "…", "language": "English",
  "actionItems": ["Call HR to finalize the recruitment process"],
  "people": [], "dates": ["tomorrow"],
  "error": null                    // why the last try failed, if it did
}
Note = NoteBrief + {"transcript": "…"}
```

- `GET /api/notes?q=grant&all=1` → `{"notes":[NoteBrief…], "silent": 8}`,
  newest first. Without `all=1`, silent recordings are left out. `silent` is
  always the total number of silent recordings, whether listed or not. `q` needs every word (title, summary,
  transcript, people, action items).
- `GET /api/notes/<id>` → `Note`.
- `GET /api/notes/<id>/audio` → `audio/wav`, rebuilt from the ring's packets
  on each request (about a second for a minute of audio).
- `POST /api/notes/<id>/retry` → `{"ok":true}` — a failed note goes back in
  the queue.
- `DELETE /api/notes/<id>` → `{"ok":true}` — the recording and its note.
- `POST /api/notes/delete-silent` → `{"ok":true,"deleted":8}`.

## Health

```
DaySummary = {
  "day": "2026-09-13",
  "steps": 3911, "calories": 106, "distance": 3031,      // metres
  "hr":   {"avg": 72, "min": 53, "max": 119, "n": 157},
  "spo2": {"avg": 97, "min": 94, "max": 99, "n": 40},
  "night": {                                              // ended that morning
    "fellAsleep": "2026-09-13T00:19:00.000", "woke": "2026-09-13T07:29:00.000",
    "asleep": 430, "deep": 175, "light": 185, "rem": 70, "awake": 0,   // minutes
    "score": 96, "label": "perfect", "bouts": 0
  },
  "stress": 31,                    // 0–100 estimate from heart rate, never a diagnosis
  "stressProvisional": false       // true until five earlier days exist
}
Aggregate = {
  "label": "2026-09-08", "from": "2026-09-08", "to": "2026-09-14",
  "days": 6,                                   // days with any data
  "steps": 24310, "stepsPerDay": 4052,
  "hr":    {"avg": 71, "min": 51, "max": 131},
  "spo2":  {"avg": 97, "min": 92, "max": 99},
  "sleep": {"nights": 5, "minutes": 402, "score": 88},   // averages over nights with sleep
  "stress": 34
}
```

- `GET /api/health/report?period=week&anchor=2026-09-13` →
  `{"period":"week","total":Aggregate,"buckets":[Aggregate…],"days":[DaySummary…]}`.
  - `period`: `day | week | month | year`. `anchor` is any day inside the
    span (default today). Weeks run Monday–Sunday.
  - `buckets`: one per day for a week or month, one per month for a year,
    none for a day. `days`: the day summaries in the span (not for `year`),
    for charts that need more than the aggregate — sleep stages, say.
- `GET /api/ring/health` — the older all-in-one view (today, week, month,
  year), kept for scripts.

## Conversations

What was said with the assistant, kept on the device as it happens.

```
Entry = {"t": "2026-09-13T20:10:51.529", "role": "user", "text": "…"}   // user | assistant | tool
Conversation = {"id": "2026-09-13T20:10:31.366", "start": "…", "end": "…",
                "turns": 12, "preview": "first thing the wearer said", "entries": [Entry…]}
```

- `GET /api/conversations/days?limit=30` →
  `{"days":[{"day":"2026-09-13","conversations":3,"turns":24}]}`, newest first.
- `GET /api/conversations?day=2026-09-13` →
  `{"day":"2026-09-13","conversations":[Conversation…]}`, oldest first.
  Entries more than 10 minutes apart start a new conversation.
- `GET /api/conversations/search?q=grant` →
  `{"results":[{"day","conversationId","t","role","text"}]}`, newest
  first, at most 50, over the last 90 days.

## Calls

- `GET /api/calls` →
  `{"callers":[{"key":"200000001","display":"0200000001","contactName":"Kofi"|null,"calls":[Call…]}]}`,
  most recent caller first; each caller's calls newest first.
- `Call = {"at","seconds","summary","commitments":[],"actionItems":[],"callerAsserted":[],"unresolved":false,"abrupt":false,"callbackRequested":false}`.
  `callerAsserted` are the caller's own unverified claims — show them as such.

## Memory

```
Fact = {"id":"f12","text":"…","subject":"200000001"|"","subjectLabel":"Kofi"|"",
        "trust":"known","source":"the wearer","at":"…"}    // trust: known | claimed
```

- `GET /api/memory` → `{"facts":[Fact…]}`, newest first. `subject` empty =
  the wearer's general memory; otherwise it is about that caller.
- `POST /api/memory` `{"text":"…","about":""}` → `{"ok":true,"fact":Fact}` —
  written as the wearer's own (trusted).
- `POST /api/memory/<id>/confirm` → `{"ok":true}` — a claim becomes a fact,
  recorded as confirmed by the wearer.
- `DELETE /api/memory/<id>` → `{"ok":true}` — forget a fact or discard a claim.

## Settings

- `GET /api/settings` → every setting (keys as in `settings_server.dart`).
- `POST /api/settings` → **partial**: only keys present change.
- `stand_down_after`: minutes of quiet before a conversation ends, one of
  1, 2, 5, 10 (default 2).
- `system_prompt`: the device assistant's instructions. Sent and accepted
  **only in developer mode**; otherwise the built-in prompt is used and the
  key is left out.
- `GET /api/settings/options` →
  `{"models":[{"value","label"}],"voices":[{"name","style"}]}`.
- `POST /api/camera` (partial, applied live) and `GET /api/camera/stream`
  (MJPEG, for an `<img>`).
- `POST /api/watchface` (partial, applied live): the font, weight and size,
  and `watch_time_x` / `watch_time_y` — where the time is centred on a live
  mascot's face, 0–1 of the screen.

## Mascot design

The mascots (Bloub, the fox) take their whole design — colours, shape,
eyes, motion, clock — from the avatar web tool's own JSON. Which mascot is
shown is the ordinary `mascot` setting (`bloub | fox`).

- `GET /api/avatar` → `{"mascot":"bloub","params":{…},"groups":[…],"specs":[…],"palettes":[…]}`
  — the design as drawn, in the web tool's format, plus how to build a
  control for every setting (from `watch_avatar`'s `kParamSpecs`; the
  character is left out, being the `mascot` setting):
  `{"key","label","group","kind":"color|choice|number|toggle","help","min","max","step","unit","choices":[{"value","label"}],"bloub":true,"fox":true}`.
  Palettes are `{"name","bg","body","eye","muzzle"}`, colours `"#rrggbb"`.
- `POST /api/avatar` `{"changes":{"eyeShape":"round","speed":1.5}}` — one or
  a few settings in the tool's JSON form, applied at once: the device changes
  while the wearer drags. Unknown keys are skipped.
- `POST /api/avatar` `{"palette":2}` — one of the palettes.
- `POST /api/avatar` `{"params":{…}}` — the tool's "Settings for the app"
  export. A design names its own character, and the mascot switches to it.
  A body with none of the tool's keys is refused (400).
- `POST /api/avatar` `{"reset":true}` — the character's default design.
- Every POST answers `{"ok":true,"mascot":"…","params":{…}}`.

## Backup & restore

One zip: `manifest.json` (format `fox1-backup`, version, `app`, `createdAt`,
`includesKeys`, `counts`, and the settings with their types), then
`internal/health|notes|conversations/…` and `external/memory.json`,
`call_history.json`, `pending_reports.json`. ClawPin (the app FOX-1 was
before) writes the same format with `"app": "clawpin"`.

- `GET /api/backup` → the zip as a download
  (`Content-Disposition: attachment; filename="fox1-backup-YYYY-MM-DD.zip"`).
  `?keys=1` includes `gemini_api_key`, `openclaw_token` and `agent_relay_token`;
  otherwise they are left out. `setup_done` and `developer_mode` never are.
- `POST /api/restore` — the body is the zip (`Content-Type: application/zip`,
  up to 512 MB) → `{"ok":true,"restored":{"from":"clawpin","createdAt":"…","files":12,"settings":20,"includesKeys":true,"skipped":0}}`,
  then the app restarts about a second later. Notes, health days and chats
  are added (same names replaced); memory, call history and settings are
  replaced. Setup counts as done again only if a key came across. Entries
  outside the listed folders and files (or with `..`) are skipped, not
  written. `400` with a plain message for a file that is not a backup or is
  from a newer FOX-1.

## Setup

First launch: the device shows only the Hub's QR code and PIN
(`OnboardingScreen`), keeps the Hub on however long setup takes, and
switches to a mascot once a phone signs in. The frontend sends every
signed-in page to `#/setup` until `done` is true.

```
Permission = {"id": "microphone", "label": "Microphone", "why": "So FOX-1 can hear you.",
              "askedBy": "prompt",        // prompt: an Android pop-up · screen: a Settings screen
              "required": true, "granted": false}
```

- `GET /api/setup` →
  `{"done":false,"hasKey":true,"profile":"…","mascot":"fox","name":"FOX-1","ringPaired":false,"permissions":[Permission…],"keepsAccessibility":false,"canFinish":true}`.
  `keepsAccessibility`: FOX-1 holds WRITE_SECURE_SETTINGS and puts its accessibility
  service back when Android drops it. The Hub's Settings → Permissions card uses this same endpoint.
  Permissions in the order the Hub shows them: `microphone` (the only
  required one), `camera`, `phone`, `contacts`, `location`, `accessibility`,
  `notifications`, `dialer`, `systemSettings`, `battery`, `overlay`.
  `canFinish` = a Gemini key is saved and the microphone is granted.
  Answers happen on the device, so the Hub polls this (with `X-Portal-Poll`).
- `POST /api/setup/permission` `{"id":"camera"}` → `{"ok":true,"askedBy":"prompt"}` —
  puts Android's prompt or Settings screen on the device; it returns at once.
- `POST /api/setup/ring` → `{"ok":true,"paired":true,"result":"…"}` — finds and
  pairs the smart ring (up to ~30 s).
- `POST /api/setup/done` → `{"ok":true}` — the device leaves the QR code for
  its watch face. Settings → FOX-1 Hub → *Set up again* on the device clears it.
- The key, profile, name (`assistant_name`) and character are ordinary settings, saved with
  `POST /api/settings`.
- The setup page's first step also offers *Restore from a backup*.

## System

- `POST /api/portal/stop` → `{"ok":true}`, then the Hub closes.
- Older pages, signed in: `/logs` (live log), `/api/logs/files` (saved
  sessions), `/ring` (ring console), `/api/bridge/recordings` (call-bridge
  test recordings).

## Developer

Only while developer mode is on (tap the version in the device's Settings
seven times); otherwise each answers `403`.

- `GET /api/dev/screen` → the raw accessibility tree, and
  `?format=compact` → `{"compact":"…"}`, the screen as `get_screen` gives it
  to the model. Read on the device, no model call.
- `POST /api/dev/screen-tool` `{"name":"tap","args":{"node_id":3}}` → the
  tool's result. Runs one tool exactly as the model would: `get_screen`,
  `tap`, `scroll`, `type_text`, `press_back`, `press_enter`, `press_home`,
  `launch_app`, `app_shortcut`, `close_app`, `close_all_apps` — no model call.
  Also `send_sms`, which **sends a real text**, and `do_on_device`, which runs
  the screen helper and **is billed** (a Flash model, about a cent a task).
- `POST /api/dev/task` `{"text":"…"}` → `{"ok":true}` — sends a typed request
  to the assistant in a fresh conversation, mic off. **This calls the model and
  is billed.**
- `GET /api/dev/usage` →
  `{"turns":[{"at","prompt","toolUsePrompt","response","thoughts","usd"}…],"totalUsd":0.41,"screens":["…"]}`
  — the current conversation's cost per turn from the model's own token
  counts, and the screens read since the last `/api/dev/task`. `totalUsd`
  includes the helper and the key points written for the conversation.
- `GET /api/dev/screens` → every screen the model or helper read today:
  what it was given beside the raw tree; `/dev/screens` shows it as a page.
