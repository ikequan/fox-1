# Phone Call Audio — Findings (VP39 Device)

**Goal:** the Gemini agent places and receives phone calls and holds a two-way
conversation — it must hear the caller *and* the caller must hear it. This is a
core product feature, not a nice-to-have.

**Status: SOLVED — and not by VoIP.** An ESP32 presenting itself to the device as
an HFP headset carries call audio off-device over SCO and back over SPP, so the
agent's voice enters the uplink past the API that blocks it. A two-way
conversation with a real caller works end to end.

Everything below about *on-device* injection remains correct and is why this
route exists. What is now wrong is the conclusion that VoIP was the only way
out — see [The bridge](#the-bridge-what-actually-worked). The VoIP sections are
kept because the open questions they raise (one public number, Ghana DID
paperwork, caller ID) are exactly what the bridge avoids.

Last updated: 2026-08-25.

## Device & constraints

| | |
|---|---|
| OS | **Android 8.1 — API 27** (confirmed on device 2026-08-25) |
| Root | No |
| ADB | **No access at all** |
| Install | Release APK served over LAN, downloaded via the device browser |
| Google Play | **Present** (so FCM push is available) |
| Region | Ghana |

Every conclusion below follows from "unprivileged sideloaded app on API 27".
Newer Android is a product target, so anything that works only because this
device is old — `WifiManager.setWifiEnabled`, for one — cannot be load-bearing. Any
proposal requiring `adb shell`, `pm grant`, root, or a system/priv-app install is
out of scope and should not be re-litigated.

## What works today

- `make_call` — dials via `ACTION_CALL` intent
- `end_call` — `TelephonyManager` reflection (API 26) or `Call.disconnect()`
- The agent **hears** the caller — caller's voice exits the device speaker and the
  device mic picks it up
- The agent **speaks** — VOICE_COMMUNICATION `AudioTrack` plays on the speaker

## What does not work, and why

**The caller cannot hear the agent.** The original diagnosis in this file blamed
acoustic echo cancellation stripping speaker audio from the uplink. That effect is
real but it is *downstream of the actual wall*:

> **There is no public Android API that writes PCM into the telephony uplink.**
> Even with the echo canceller disabled, there is nowhere to put the audio.

| Mechanism | Blocked by |
|---|---|
| Capture call audio (`VOICE_CALL` / `VOICE_UPLINK` / `VOICE_DOWNLINK`) | `CAPTURE_AUDIO_OUTPUT` — `signature\|privileged` |
| Inject to uplink via `AudioDeviceInfo.TYPE_TELEPHONY` | Audio policy honors it for privileged clients only; `setPreferredDevice()` silently ignored. Also API 28 — **does not exist on API 26** |
| `AudioManager.MODE_IN_CALL` | `MODIFY_PHONE_STATE` — `signature\|privileged`; Telecom owns the mode during a call anyway |
| Disable the modem-side echo canceller | No app-accessible switch. `AcousticEchoCanceler.setEnabled(false)` attaches to *your own* record session and cannot touch the codec/modem canceller, whose reference signal is the full device output mix |

`AudioRecord` failing to initialize for `VOICE_DOWNLINK` is the platform enforcing
`CAPTURE_AUDIO_OUTPUT` — not a VP39 quirk. **Correction:** the comment in
`lib/services/audio/call_audio_service.dart` claiming this "only works on Android 8,
blocked on 9+" is wrong. It required the privileged permission on 8 as well; some
OEM builds simply didn't enforce it. That path never existed for a sideloaded APK.

No commercial AI phone product injects into a carrier call — Bland, Vapi, Retell all
run VoIP. Google's Duplex and Call Screen get further only because they ship as
privileged system components.

### Ruled out by API 26 specifically

These were considered and are unavailable on this device — do not spend time on them:

- `AudioDeviceInfo.TYPE_TELEPHONY` — API 28
- `AudioManager.MODE_CALL_SCREENING` — API 30
- `setCommunicationDevice()` / `getAvailableCommunicationDevices()` — API 31

### Bluetooth SCO

SCO gives no injection point. It **relocates the whole call path**: downlink goes to
the BT device's speaker and the uplink is sourced from *the BT device's microphone*.
With ordinary earbuds you lose twice — the agent's voice plays into an earcup nobody
is wearing, and the device mic stops being the call mic so the agent also stops
hearing the caller.

The only way SCO reaches the uplink is if audio enters the BT device's mic input
electronically — see the HFP loopback idea under [Not taken](#not-taken).

## Approaches tried

| Approach | Result |
|---|---|
| VOICE_COMMUNICATION + speaker ON | User hears agent; AEC blocks caller from hearing |
| VOICE_COMMUNICATION + speaker OFF | Nobody hears it (device has no earpiece) |
| USAGE_MEDIA + speaker ON | Doesn't play during active calls |
| VOICE_DOWNLINK capture | `AudioRecord` fails to init — privileged permission |
| VOICE_CALL capture | Same |
| InCallService events | Binds; events unreliable on this device |
| Dual AudioTrack (MEDIA + VOICECOMM) | USAGE_MEDIA breaks the mic recorder |

**One untried long shot** (~15 min, expected to fail): during a call, set no audio
mode at all and play via the legacy `AudioTrack(AudioManager.STREAM_VOICE_CALL, …)`
constructor with speaker off. Some old MTK HALs had a proprietary in-call
music-to-uplink mix path. Worth doing once purely to write "closed" here instead of
"probably closed".

## Default dialer / InCallService

Becoming default dialer changes **call control**, not **audio access**. You get
`Call` objects, `setAudioRoute()`, `CallAudioState`, RTT — but no API hands over call
PCM in either direction. Keep `Fox1InCallService` for state events and clean
`endCall`; it cannot and will not expose call audio.

⚠️ **Do not "modernize" `InCallChannel.requestDefaultDialer`.** It uses
`TelecomManager.ACTION_CHANGE_DEFAULT_DIALER`, which is deprecated on API 29+ in
favour of `RoleManager.createRequestRoleIntent(ROLE_DIALER)` — but `RoleManager` does
not exist on API 26. **The current code is correct for this device.**

## The VoIP direction

With VoIP the app owns both audio streams: Gemini → uplink is a digital write, and
downlink → Gemini is a digital read. No speaker, no mic, no echo canceller anywhere
in the loop. The whole class of problem above disappears rather than being worked
around. The device already needs data for Gemini Live, so it adds no new connectivity
requirement.

Bonus: the `_aiSpeaking` echo gating in `audio_manager.dart` becomes unnecessary
during VoIP calls, which means **the caller can interrupt mid-sentence and the agent
will hear it**. The current acoustic setup structurally cannot do barge-in.

### The hard requirement this creates

Whatever carries the call **must accept application-supplied PCM**. If the SDK owns
the mic and speaker, its own AEC recreates the exact failure documented above — a
different transport with an identical dead end.

Mobile WebRTC generally does **not** expose custom audio tracks. Injecting PCM
requires supplying your own `AudioDeviceModule` at `PeerConnectionFactory`
construction, and SDKs wrapping WebRTC rarely surface that hook.

### Provider tension (unresolved)

| Provider | Custom audio injection | Ghana numbers |
|---|---|---|
| **Twilio** Voice Android SDK | ✅ `AudioDevice` API (5.2+, current in 6.9.0, official `exampleCustomAudioDevice`). Supports API 25+, so Android 8 is fine. Device must be set when no call is in progress | ❌ None |
| **Telnyx** WebRTC Android SDK | ❌ No custom `AudioDeviceModule`, no PCM injection, no app-supplied `PeerConnectionFactory`. Only ringtone/ringback config — UI sounds, not stream control | ✅ Available, from ~$1 |

**Ghana DID paperwork (Telnyx):** mobile numbers need name, contact phone,
passport/ID and address. National numbers additionally need a Letter of Intent
(template supplied by Telnyx) and proof of address dated within 3 months.

### Two routes that remain

- **A — PJSIP on the device.** Buy the number as a plain SIP trunk and skip the
  vendor SDK. `pjsua2` exposes custom audio media ports, so Gemini's PCM feeds
  straight into the call. Keeps one Gemini session on-device. Cost: PJSIP
  integration (prebuilt AAR or NDK build) plus a foreground service to hold the SIP
  registration alive under Android 8's background execution limits.
- **B — Server-side media bridge.** Provider call-control API with bidirectional
  media streaming forks call audio to a WebSocket on a host, which bridges to Gemini
  Live. The device never touches call audio — it requests calls and can gate
  answering with a heartbeat so the agent is offline when the device is off. Less
  device work, provider-agnostic. Cost: a host to run, and the call's Gemini session
  is separate from the device's.

Current lean: **B** — fully digital audio path, no NDK integration, and no lock-in to
one vendor's SDK, which is the trap that cost us the Twilio plan.

## The bridge — what actually worked

[fox-1-call-bridge](https://github.com/ikequan/fox-1-call-bridge) + `CallBridgeChannel.kt`. Android will route a
call to a Bluetooth headset, so the board pretends to be one: call audio leaves
over SCO, returns to this app over SPP as IMA-ADPCM, and the agent's reply goes
back the same way. The device's own mic and speaker leave the call path entirely
once SCO is up, so there is no acoustic coupling and no AEC anywhere — the whole
class of problem above disappears rather than being worked around.

Proven on this hardware: mSBC/16 kHz wideband, ~8 kB/s each way, caller ID and
ring delivered before answer, and the caller hearing Gemini clearly.

It also dissolves [Open question 1](#open-questions): the carrier call *is* the
call, so there is one public number, no DID paperwork and no caller-ID
verification.

### Two constraints found the hard way

**Wi-Fi must be off during an agent call.** With Wi-Fi associated the caller
hears the agent chopped up; with Wi-Fi off and Gemini on LTE the same call is
clean. 2.4 GHz Wi-Fi and Bluetooth share the band and the antenna, and this link
already carries live SCO plus 16 kB/s of RFCOMM. The bridge now disables Wi-Fi
for the duration of a call and restores it after. This is a product rule — the
agent needs data and the bridge simultaneously, always.

This took a long time to see because a second bug masked it: the outbound PCM
buffer was capped at 400 ms, and Gemini delivers a four-second reply in about
one second, so most of every reply was discarded regardless of which radio was
in use. Wi-Fi was tested, looked innocent, and was wrongly ruled out. Two faults
masking each other is worth remembering when a variable "tests clean".

**Gemini is a burst source, not a real-time one.** Any buffer between it and the
call must hold a whole utterance and be drained by the call's own clock. Sizing
it for latency discards speech.

## Open questions

1. **Can the SIM number be presented as outbound caller ID?** The goal is one public
   number: inbound via carrier forwarding SIM → VoIP number, outbound via caller-ID
   verification. Providers generally require ownership or verification, and Ghana NCA
   rules plus local carrier CLI handling may block foreign-originated caller ID. If
   the answer is no, outbound shows the VoIP number while inbound arrives on the SIM
   — two publicly visible numbers, which breaks the requirement. **Confirm with the
   provider before ordering a number.**
2. **Ghana-local providers** — Hubtel (Ghanaian) and Africa's Talking (regional) may
   have cleaner local CLI standing and cheaper domestic rates. Unverified whether
   either supports real-time bidirectional media streaming.
3. **Route A or B**, and whether hosting is available.

## The single HFP slot — how audio gets steered (2026-08-26)

Measured on the device, not inferred. It resolves the routing conflict between the
bridge board and the user's earbud.

**This device connects exactly one HFP device at a time.** With the ESP32 and a
TECNO True 1 Air both showing "Connected" in Bluetooth settings,
`BluetoothHeadset.getConnectedDevices()` returned only the board, and the earbud's
own row read "Connected (no phone)" — A2DP, no headset profile. The settings screen
lists every Bluetooth connection; only the HFP profile list is authoritative here.

That one slot is also what steers SCO. `startBluetoothSco()` carries no device
argument on API 27; native `btif_hf.cc` routes to `btif_hf_latest_connected_idx()`,
the most recently SLC-connected headset. With a single slot the two questions
collapse: **whoever holds HFP gets the call audio.**

This is why the earlier symptoms looked random and were not. The agent's voice was
never competing for the earbud's SCO — the earbud had no SLC and was never
eligible. Disconnecting it changed nothing because it had nothing to lose.

### The lever, and that it works here

`BluetoothHeadset.connect(device)` / `disconnect(device)` are `@hide`, but on API 27
they are gated only by `BLUETOOTH_ADMIN` (a normal permission) and non-SDK-interface
enforcement did not exist until API 28. `HfpProbeChannel` confirmed on this build:
both methods present, `disconnect` moved the state 2 → 0, `connect` moved it back.

**SPP is unaffected by HFP going down.** Cycled four times with gaps up to 35 s
while the bridge ran: `resync 0`, `drop 0`, stats unbroken. Different RFCOMM channel
on the same ACL link. The board also did not auto-reconnect during those gaps, so
`setPriority` is not needed — and is deliberately avoided, since a crash mid-call
would leave the user's earbud pinned priority-off and silently unable to take calls.

### Property names

`bt.max.hf.connections` is the AG-side knob and the one that governs — the device is
the audio gateway. `bt.max.hfpclient.connections` is the HF role (a device acting
*as* a headset) and does not apply. Both read unset on this build; neither is
authoritative on a patched one. The connected-devices list is.

### Implementation

`services/HfpRouter.kt` moves the slot: `acquireForBridge()` frees it from whoever
holds it and gives it to the board, `releaseToUser()` gives it back to the earbud
(preferring whoever was displaced, then whatever is A2DP-connected). Both run on one
serial executor and poll `getConnectionState` until the change lands, because the
reflective call returns "request accepted", not "done".

Wired to arm/disarm in `CallBridgeChannel`, and exposed as → bridge / → earbud
buttons on `BridgeTestScreen`.

**Side benefit:** during a bridged call the earbud has no SLC, so it never receives
`RING` and cannot send `ATA` to steal SCO mid-call. The constraint that looked like
the problem turns out to be the enforcement mechanism.

### Confirmed end to end (2026-08-26, 15:36–15:41)

The earbud was **crowded out, not disabled** — it takes the slot readily once the
board releases it, and the settings row changes from "Connected (no phone)" to
"Connected, battery 90%" (the HFP battery indicator) as visible confirmation.

Swap timings, both directions under a second:

| | |
|---|---|
| release → earbud (idle) | 590 ms |
| acquire → bridge | 850 ms (55 ms to free, 795 ms to connect) |
| release after a live call | 950 ms |

A real carrier call ran through the bridge with the slot held by the board
(`board already holds the slot` — the acquire is idempotent, no churn on a
session that is already routed): `resync 0`, `drop 0`, `skip 0`, `starve 1`,
`q` 1–5, `w 10/10ms`. On stop the slot went back to the earbud, and the main AI
session that followed **played to the earbud and took a barge-in on it**
(`interrupted by user`, 350 audio chunks / 4.1 MB delivered). Verified usable at
~20 m from the device, which is the smart-ring use case this was blocking.

## Infrastructure built (reusable)

- `Fox1InCallService.kt` — InCallService with `Call.Callback`, call state tracking
- `InCallChannel.kt` — platform channel bridge for InCallService
- `CallAudioChannel.kt` — VOICE_DOWNLINK capture. Dead on any unrooted device; kept
  only as a probe for hardware with a non-conformant HAL
- `PhoneChannel.kt` — contacts, call history, make/end call. **Keep the carrier
  `ACTION_CALL` path** for user-initiated and emergency calls regardless of which
  VoIP route is chosen
- `in_call_service.dart`, `call_audio_service.dart` — Dart wrappers
- Call state polling with auto-recovery in `AISession`
