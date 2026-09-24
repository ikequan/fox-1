# JY Smart Ring — BLE Protocol & Integration Guide

An independent description of the JY smart ring's BLE protocol, written for
interoperability with the FOX-1 launcher. It was worked out by observing how
the ring and its companion app, **LoraFit**, behave, and by testing on hardware.
Command and field names are descriptive labels used in this document and in FOX-1's
code.

## Confidence levels

| Marker | Meaning |
|---|---|
| ✅ | Confirmed: matches the vendor app's behaviour and/or verified on hardware |
| ⚠️ | Inferred from observed behaviour — verify on device |
| ❓ | Unknown — needs a sniffing session |

Nothing here has been tested against real hardware yet. Verify with `nRF Connect`
or a logging build before depending on any of it.

> **Revised 2026-09-10.** A second pass worked out every command and reply layout
> directly rather than inferring from field names. It **corrected the button mapping (§5)**, fixed the heartbeat interval and
> `setTime` payload, and recovered every payload layout (§4a). The Settings →
> Smart Ring screen implements all of it; `lib/services/ring/ring_protocol.dart`
> is the reference and is unit-tested.

---

## 1. Connection & GATT layout ✅

The app discovers services and matches UUIDs by **case-insensitive substring**, not
by full equality. Do the same — the app only relies on these fragments, so only
they are certain.

| Purpose | Service (contains) | Characteristic (contains) | Properties |
|---|---|---|---|
| Command (host → ring) | `56FF` | `33F3` | Write |
| Notify (ring → host) | `56FF` | `33F4` | Notify |
| Battery level | `180F` | `2A19` | Read + Notify |

`180F`/`2A19` are the standard Bluetooth SIG Battery Service, so those are almost
certainly `0000180F-0000-1000-8000-00805F9B34FB` etc. The `56FF`/`33F3`/`33F4`
fragments are ⚠️ — most likely `0000XXXX-0000-1000-8000-00805F9B34FB`, but confirm
the base with a scanner rather than assuming.

Connection sequence as the app performs it:

1. Connect GATT, discover services
2. Locate the three characteristics above; **abort if any is missing**
3. Read battery (`2A19`), then enable its notification
4. Enable notification on `33F4` (write CCCD `2902` = `0x01 0x00`)
5. Negotiate MTU — the app requests it via command `0x03` (see below)
6. Send `setTime` (`0x01`) and `setUserInfo` (`0x02`)
7. On the `queryDeviceFeature` (`0x37`) reply, start `sendAppHeartbeat` (`0x3E`, no
   payload) every **2000 ms** ✅ — as the vendor app does it

The ring **also enumerates as an Android HID input device** — see §7.

---

## 2. Packet framing ✅

All packets, both directions, share a 10-byte header. **Little-endian. No checksum.**

```
offset  size  field
0       2     magic = 0xFCFE   (on the wire: FE FC)
2       2     opcode
4       2     totalPackets     (1 when not fragmented)
6       2     currentPacket    (1-based; 1 when not fragmented)
8       2     payloadLength
10      N     payload
```

Receiver validation, mirroring the app: drop if length < 10, drop if magic ≠ `0xFCFE`,
drop if `buffer.length != payloadLength + 10`.

Opcodes are **shared between request and response** — sending opcode `0x2F`
(queryAudioState) produces a notification also tagged `0x2F`. Treat the opcode as a
topic, not a direction.

---

## 3. Commands — host → ring ✅

All sent to characteristic `33F3` as a single packet (`totalPackets = 1`,
`currentPacket = 1`).

| Op (dec) | Op (hex) | Name | Payload |
|---|---|---|---|
| 1 | 0x01 | `setTime` | 6-byte LE **local wall-clock** seconds, then `00` ✅ (see §4a) |
| 2 | 0x02 | `setUserInfo` | height, weight, age, sex, …, timestamp |
| 3 | 0x03 | `getMTU` | `00 00` |
| 4 | 0x04 | `vibrateLED` | `[mode]` — **haptic feedback** |
| 6 | 0x06 | `getBattery` | `00 00` |
| 7 | 0x07 | `openHeartRate` | — |
| 8 | 0x08 | `closeHeartRate` | — |
| 9 | 0x09 | `getSportStatus` | `00 00` |
| 10 | 0x0A | `pauseOrResumeSport` | `[state] 00` |
| 12 | 0x0C | `setSportTarget` | target |
| 13 | 0x0D | `setAuxFunction` | 11 ints |
| 14 | 0x0E | `setTimeFormat` | `[0=24h, 1=12h]` |
| 15 | 0x0F | `openCloseBpBsHrv` | `[a] [b]` |
| 19 | 0x13 | `setBpCalibration` | systolic, diastolic |
| 20 | 0x14 | `openCloseTemperature` | `[0/1]` |
| 23 | 0x17 | `openCloseSpo2` | `[0/1]` ✅ — missing from the first pass |
| 26 | 0x1A | `setAppInfo` | app info struct |
| 28 | 0x1C | `setAppRunningInfo` | state |
| 29 | 0x1D | `getStepInfo` | — |
| 30 | 0x1E | `setAutoHeartRateSetting` | interval, window, enable… |
| 33 | 0x21 | `getStepCountInfo` | `[day]` |
| 34 | 0x22 | `getSleepData` | `[day]` |
| 36 | 0x24 | `getHealthRecord` | `[day]` |
| 37 | 0x25 | `getDeviceInfo` | — |
| 38 | 0x26 | `controlMultiSport` | `[mode]` |
| 39 | 0x27 | `deviceOperation` | `[op]` |
| 41 | 0x29 | `sendPaste` | `01` |
| **47** | **0x2F** | `queryAudioState` | `00 00` |
| **48** | **0x30** | `controlAudioMode` | `[mode] 00` — **0=stop, 1=live+save, 2=live only** ✅ |
| **49** | **0x31** | `pauseOrResumeAudio` | `[state] 00` |
| 52 | 0x34 | `getOfflineAudioData` | — |
| 54 | 0x36 | `clearOfflineAudioData` | index |
| 55 | 0x37 | `queryDeviceFeature` | `00 00` |
| 61 | 0x3D | `queryOfflineAudioFileCount` | — |
| 62 | 0x3E | `sendAppHeartbeat` | — |
| 63 | 0x3F | `stopOfflineRecord` | — |
| 64 | 0x40 | `stopOfflineRecordTransfer` | — |

❓ The argument enums (`controlAudioMode` mode values, `deviceOperation` ops,
`vibrateLED` patterns) are plain integers with no known meanings.
Determine by experiment — `vibrateLED` is the safest to probe first.

---

## 4. Notifications — ring → host ✅

Received on `33F4`. The field names below are descriptive labels for the values
each reply carries. Opcodes the vendor app handles: 23, 24, 25, 36, 37, 38, 40, 47,
48, 49, 50, 51, 52, 53, 54, 55.

Known payload keys:

| Domain | Keys |
|---|---|
| Health | `heart_rate`, `spo2`, `steps`, `distance`, `calories`, `temperature_celsius`, `temperature_tenths`, `sleepQuality`, `moveIntensity`, `duration` |
| Sport | `sport_type`, `current_sport_id`, `pause_status`, `final_state`, `start_timestamp` |
| Audio | `audio_state`, `opus_frames`, `frame_count`, `streaming`, `recording_storage_enabled`, `remote_recording_enabled`, `offline_file_count`, `remaining_file_count` |
| Input | **`button_event`** |
| Framing | `totalPackets`, `currentPacket`, `raw_payload`, `timestamp`, `current_timestamp`, `result`, `action`, `ext_value` |

Multi-packet responses (sleep, health history, offline audio) use `totalPackets` /
`currentPacket` in the header; reassemble before parsing.

Empty-result sentinels ✅: opcode **43** = sleep query returned no data, opcode **45**
= health record returned no data. Both (and 42) carry a 6-byte timestamp.

### 4a. Payload layouts ✅

All little-endian. `ts` is 6 bytes of **local wall-clock seconds** — the ring stores
`(utcMillis + zoneOffset) / 1000`, not UTC.
In history replies, a record that is all `0xFF` is an empty slot and is skipped.

| Op | Hex | Reply | Layout |
|---|---|---|---|
| 1 | 0x01 | ring clock | `year u16, month, day, hour, minute, second` |
| 6 | 0x06 | battery | `percent u8, charging u8` |
| 10 | 0x0A | sport pause | `sportId u8, paused u8` |
| 11 | 0x0B | **live heart rate** (after `0x07`) | `ts, bpm u8` |
| 21 | 0x15 | **live temperature** (after `0x14 [1]`) | `ts, raw i16` → `raw / 100` °C |
| 24 | 0x18 | **live SpO₂** (after `0x17 [1]`) | `ts, percent u8` |
| 27 | 0x1B | live sport | `ts, type u8, ts, duration u16, steps u32, cal u16, dist u16, hr u8, temp i16/10, spo2 u8` |
| 29 | 0x1D | step info (today) | `ts, steps u32, calories u16, distance u16` |
| 33 | 0x21 | step history | 16-byte records: `ts, duration u16, steps u32, calories u16, distance u16` |
| 34 | 0x22 | sleep | 8-byte records: `ts, sleepQuality u8, moveIntensity u8` |
| 36 | 0x24 | health history | 14-byte records: `ts, hr u8, spo2 u8, temp_tenths i16, 4 unused` |
| 37 | 0x25 | device info | `firmware u16, mac[6], manufacturer u16, model u16` |
| 40 | 0x28 | **button** | `raw u8` — see §5 |
| 47 | 0x2F | audio state | `state u8` (bitmask, §9), `ext u8` |
| 55 | 0x37 | features | `remoteRecording u8, recordingStorage u8` |
| 61 | 0x3D | offline files | `count u16` |

❓ Still open at this stage: units for calories and distance, and what the
`sleepQuality` values mean (both since answered on hardware, §11).

---

## 5. Button / touch events — the important one ✅

**Opcode 40 (0x28)**, payload key `button_event` (integer) — a button event the
device reports to the phone.

### Recovered values ✅ — corrected

The first pass mistook the vendor app's *remapped* `button_event` numbers for wire
values. What matters is byte 0 of the payload: `1` is a press, `2` is a release, and
the vendor app discards every other value (it remaps them to 1, 0 and −1):

| On the wire (byte 0) | `button_event` | Meaning |
|---|---|---|
| **1** | 1 | Button **pressed** |
| **2** | 0 | Button **released** |
| anything else | −1 | **Discarded** by LoraFit |

**There is no double-click value on this wire.** The earlier table's "2 = double-click"
was wrong: 2 is a release. Double-click, if the app has it, is derived from press/release
timing. The ring test screen flags a press within 450 ms of a release so double-tap can be
evaluated as a second gesture.

### The ring's button is hold-to-talk ✅

This is the key finding. In LoraFit, press/release drives **push-to-talk**, not
discrete taps:

- `button_event == 1` → begin capturing voice
- `button_event == 0` → send/stop the capture

⚠️ Double-click is **not** an opcode-40 value (see the corrected table above) — any
double-tap binding has to come from timing two press/release pairs.

**That maps onto FOX-1 almost exactly.** Hold the ring to talk to the agent,
release to send — a far better interaction than swiping to a screen, and it gives
natural turn boundaries instead of relying on silence detection. Double-click is free
for a second binding (start/stop a persistent session, interrupt the agent, etc.).

⚠️ **Caveat on gesture codes above 2.** LoraFit only ever consumes −1, 0, 1 and 2;
any other integer is routed to a handler that ignores it. If your ring's firmware
emits codes for long-press, swipe, or triple-tap, this app would silently drop them —
so the absence of higher codes here is **not** evidence the hardware can't send them.
Worth logging every value during calibration.

### Do not conflate the two button paths ✅

The vendor app also reads **byte 3** of a raw notification as a press state and
normalizes `2 → 0`. The opcode-40 path does the same normalisation on byte 0 — the
first pass read these as different meanings; they are the same convention.

---

## 6. Audio capture ✅

**The ring streams microphone audio live, in real time.** It is not
record-then-transfer only — live streaming and offline sync are separate,
coexisting mechanisms.

### Audio format ✅

| Parameter | Value |
|---|---|
| Codec | Opus |
| Sample rate | **16000 Hz** |
| Channels | **1 (mono)** |
| Decoded PCM | **16-bit signed, little-endian** |
| Opus packet size | **fixed 40 bytes** per frame |

The vendor app decodes and plays the ring's audio at 16 kHz mono 16-bit throughout,
and FOX-1's own decoding on hardware agrees (§11).

**16 kHz mono 16-bit is exactly what Gemini Live accepts** — decode and forward, no
resampling.

❓ Frame duration (samples per packet) was unknown at first. It doesn't
block anything: `opus_decode` returns the sample count. 40 bytes at 16 kHz suggests
~20 ms / 16 kbps CBR, unverified.

### Payload layout ✅

Within one reassembled audio command payload:

```
[0:6]   timestamp (6 bytes, little-endian, seconds-scale)
[6:]    back-to-back 40-byte Opus packets — no length prefix, no delimiter
        frame_count = (payloadLength - 6) / 40
```

Any trailing `(len - 6) % 40` bytes are discarded (the app logs a misalignment
warning). There is no per-frame sequence number inside the payload — ordering comes
from the transport header's `currentPacket` / `totalPackets`.

### The three audio modes ✅

| Opcode | Hex | Mode | Behaviour |
|---|---|---|---|
| 50 | 0x32 | `ONLINE_RECORDING` | live stream **and** saved to ring |
| 51 | 0x33 | `AI_DIALOG` | live stream only, nothing stored |
| 52 | 0x34 | `OFFLINE_SYNC` | stored-file transfer |

Started via **`controlAudioMode` (0x30)** ✅:

| Value | Effect |
|---|---|
| **0** | stop |
| **1** | online recording — live + save |
| **2** | AI dialog — live only |

**Use mode 2 for FOX-1.** It is purpose-built for exactly this: continuous live
mic audio with no storage side-effects.

The `streaming` flag is derived as `totalPackets == 0` — live modes send an unbounded
stream with `totalPackets = 0`; offline transfers send a finite count.

### Offline recordings (separate mechanism)

Quadruple tap on the ring starts and stops a recording kept on the ring itself.
Getting one off it, as the vendor app does it:

```
→ 0x3D  (empty)             how many files?
← 0x3D  u16 count
→ 0x34  (empty)             send the next file
← 0x34  × N                 packets 1..N (totalPackets = N): 6-byte time + 40-byte Opus frames
← 0x35                      instead of the above when there is nothing to send
← 0x36  u16 remaining       that file is complete
→ 0x36  u16 remaining       acknowledge — the ring DELETES the file
                            then 0x34 again while remaining − 1 > 0
```

`stopOfflineRecordTransfer` (0x40, empty) abandons a transfer. LoraFit ignores a
0x36 unless it asked with 0x34 and every packet of the file arrived, and only
then acks — **the ack is the delete, so send it only after the copy is safe.** It
must also come *straight after* the file: on hardware an ack sent minutes later,
after other commands, was silently ignored and the next `0x34` returned the same
file. Files come **oldest first**, so a new recording is only reachable once the
older ones have been moved.
Audio-state bits (0x2F reply): `0x10`/`0x30`
recording in progress, `0x40` finished, `0x50` both. LoraFit decodes each frame
with an Opus decoder, converts to MP3, stores it in its "EverNote" notes DB and
sends it to a vendor cloud for transcription. FOX-1 decodes with Android's own
`MediaCodec` Opus decoder instead (`RingBleChannel.decodeOpus`).

### Audio conditioning ✅

Live frames are **raw Opus** — the vendor app applies no noise suppression to live
audio. Its noise suppression is phone-side and runs only when converting offline
files to MP3. Whether the ring's firmware conditions the mic signal before encoding
is unknown.

**For FOX-1:** ring Opus → decode → `GeminiLiveClient.sendAudio()` directly. Dart
has no bundled Opus decoder, so this needs an FFI package or a small platform shim
(a decoder created for a rate and channel count, and a decode call from bytes to
16-bit samples).

---

## 7. Second path: the ring is also an HID device ✅

The vendor app watches Android's input devices and matches the ring's Bluetooth
name against the input device's name — it uses HID device removal to detect ring
disconnection.

⚠️ **Worth testing before building any of the above.** If the ring emits standard HID
key events for its touch gestures, Android delivers them to the foreground activity
as `KeyEvent`s, and the launcher can catch them in `dispatchKeyEvent` with **zero BLE
code**. That would make "summon the agent by tapping the ring" a few lines instead of
a protocol implementation.

Test: pair the ring, override `dispatchKeyEvent` in `MainActivity`, log every
keycode, then tap/double-tap/long-press. Costs 15 minutes and could save days.

---

## 8. Integration plan for FOX-1

**Step 0 — the session bug, independent of the ring.** `AIAgentScreen` starts and
stops the session off `activeScreenProvider`, so every visit builds a new
`AISession`, reconnects the WebSocket, and loses all conversation history. Summoning
by ring will feel exactly as slow as swiping unless this is fixed first. Move the
session to a long-lived provider that survives screen changes, and have the screen
observe it rather than own it.

**Step 1 — gesture input, as hold-to-talk.** Bind `button_event` 1/0 (press/release)
to "start listening / end turn", and 2 (double-click) to a session toggle. Test the
HID path first (§7) — if gestures arrive as key events, this needs no BLE client at
all. Otherwise it comes over opcode 40 via step 2.

**Step 2 — BLE client.** Done with Android's own GATT API in
`RingBleChannel.kt` (bytes only, operations serialised), wrapped by
`lib/services/ring/ring_ble.dart` — no BLE plugin. The protocol layer
(`ring_protocol.dart`) is pure Dart and unit-tested.

**Step 3 — health data.** Feed `heart_rate`, `spo2`, `steps`, `temperature_celsius`
into the watchface and Controls screen. These are also worth exposing to Gemini as
tools (`get_heart_rate`, `get_sleep_data`) so the agent can answer questions about
the wearer — a natural fit for `NativeToolsBridge`.

**Step 4 — ring mic. Unblocked.** Send `controlAudioMode(2)` (AI_DIALOG), parse
`[6-byte timestamp][40-byte Opus frames]` off opcode 0x33, decode with libopus at
16 kHz mono, and hand the PCM straight to `GeminiLiveClient.sendAudio()` — the rate
already matches, so no resampling. The only new dependency is an Opus decoder binding.

The payoff is real: a ring mic near the mouth beats the device's own mic, and it
lets the agent listen without the device being raised. Note this also makes the ring a
better echo situation than the device — worth revisiting `AudioManager`'s `_aiSpeaking`
gating once ring audio is the input source.

---

## 9. Open questions

1. Whether the ring emits `button_event` codes **above 2** (long-press, swipe) that
   LoraFit ignores ⚠️ — log everything during calibration
2. Does the ring emit HID keycodes? ⚠️ (could bypass the BLE client for gestures)
3. ~~Full 128-bit UUIDs~~ SIG base: `000056ff-0000-1000-8000-00805f9b34fb` etc. ✅ (§11)
4. ~~Heartbeat interval~~ **2000 ms**, started on the `0x37` reply ✅
5. Opus frame duration ❓ — cosmetic; `opus_decode` reports the sample count
6. `vibrateLED` (0x04) and `deviceOperation` (0x27) argument values ❓ — **LoraFit
   never calls either one**, so watching the app cannot reveal them. Probe values 0–3
   on hardware.

**Resolved:** `button_event` values, `controlAudioMode` values, Opus parameters,
payload layout, and the live-vs-offline question — see §5 and §6.

### Audio state bitmask ✅

For parsing `audio_state` from `queryAudioState` (0x2F):

| Bits | Meaning |
|---|---|
| `1\|2` | online recording active |
| `4\|8` | AI dialog active |
| `16` | offline recording in progress |
| `64` | offline recording completed |

## 10. Checking this description

Everything here can be checked with a BLE scanner such as `nRF Connect`, or with the
FOX-1 ring console (`http://<device-ip>:8080/ring`), which sends any command and logs
every reply. `lib/services/ring/ring_protocol.dart` is the reference implementation
and is unit-tested.

## 11. Verified on hardware ✅ (2026-09-10, ring `SR116-0767`)

Tested from Settings → Smart Ring on the T4G device (log
`session-2026-09-10T12-25-51`). Everything below was observed on hardware, not
inferred.

**GATT.** The fragments sit on the standard SIG base — `000056ff-…`, `000033f3-…`
(write, writeNoResp), `000033f4-…` (notify), `0000180f`/`00002a19` (read, notify). MTU
512. The ring also exposes services LoraFit never touches:

| Service | What it is |
|---|---|
| `1812` | **HID over GATT** — five `2A4D` report characteristics plus `2A4A/4B/4C/4E` |
| `FEF5` | Vendor service, nine characteristics — likely firmware update |
| `FF12` | `FF15` write / `FF14` notify — purpose unknown |
| `180A` | Device information (`2A50` PnP ID) |

**Gestures take three different paths.** Gesture meanings are from the ring's owner
(the product page only says *"tap control to start/stop audio recording"* and *"support
short video gesture"*); what arrives on each path is from the logs.

| Gesture on the ring | What arrives | Path |
|---|---|---|
| **Tap-and-hold** | opcode 40: `01` on press, `02` on release — holds of 0.1–11.4 s, accurate timing | **BLE** — hold-to-talk. In LoraFit this is what starts the live audio stream to the host. |
| **Tap** or **swipe** | canned screen swipe **up**: (160,238)→(160,46), 105–180 ms | **HID touchscreen** — `SR116-0767`, vendor `0x05AC`, product `0x0220` |
| **Double-tap** | canned screen swipe **down**: (160,135)→(160,354), 120–210 ms | HID touchscreen, same device |
| **Quadruple tap** | starts/stops a recording stored **on the ring**: `audio_state` `0b10000` → `0b1000000`; the `0x3D` file count read 2 afterwards | ring-side only |

What follows from that:
- **Hold-to-talk over BLE works** and is the only gesture that reaches the app with
  press/release timing.
- The HID path offers **two distinguishable events**: tap and swipe both give *up*,
  double-tap gives *down*. With hold on BLE, the ring has **three usable inputs** —
  hold (with press/release timing), up, down.
- HID swipes move **whatever app is in front**. FOX-1 can swallow them while it is in
  front (`dispatchTouchEvent`, external devices only — the test screen's *Block ring
  touches*), and nowhere else. **Confirmed:** with blocking on, 60+ ring swipes in a row
  all arrived and were consumed.
- The ring's `vendor 0x05AC` is Apple's USB vendor ID, borrowed — common for cheap HID
  rings, so phones treat them as a known accessory.

**Decoded and plausible:** battery 84%; device info (firmware 136, maker `A5DA`, model
`A001`); today's steps; step history; sleep (138 samples); health history (98 records, HR
55–119, SpO₂ 97–99 %, 31.0 °C); live heart rate; `setTime` (the ring read its clock back
correctly).

**Learned from the data:**
- **Step history records are running totals** for the day, not per-slot counts — the
  last record equals today's total. The first decoder summed them and reported 9,676
  steps for a 1,069-step day.
- **Distance is metres, calories are kcal** (1,069 steps → 828 m and 28 kcal).
- **Samples are every 5 minutes.** Sleep quality is **4 deep, 3 light, 2 REM, 1 awake,
  0 not sleeping** — only 2–4 count as sleep. Confirmed to the minute against a LoraFit
  screenshot (6h20 = 22 deep + 41 light + 13 REM samples) and LoraFit's own rules (§12).
- New opcodes: **`0x11`** (empty) = heart-rate measurement finished; **`0x19`** (empty) =
  SpO₂ finished; **`0x44`** = device name, length-prefixed ASCII (`0a` + `SR116-0767`),
  sent unprompted after connect.
- After every device-info reply the ring also sends 13 bytes with **no `FE FC` header**
  (`0c 88 00` + MAC + `3a 00 48 00`) — the firmware version and MAC again, framing
  unknown. Safe to ignore.
- `vibrateLED` acknowledges modes 0–3 by echoing the byte, but **nothing is felt** —
  the SR116 appears to have no vibration motor. Haptic confirmation will have to come
  from the device.
- Live temperature and live SpO₂ produced no reading in the ~30 s and ~5 s they were on.
- Turning the 2 s heartbeat off for 17 s did not drop the link; longer gaps are untested.
- Quadruple tap confirmed: the `0x3D` offline-recording count went 4 → 5 across one.
- **The 5-minute heart-rate history is noisy.** 75 bpm recurs all day and all night,
  deep sleep included — almost certainly the ring's "no reading" — and single
  103–119 bpm readings sit between neighbours in the 60s–70s. Averaged raw, sleeping
  HR came out at 86. `stress_estimator.cleanHeartRate` drops a dominant exact value
  and isolated spikes; never average this history raw.
- **Skin temperature is 31.0 °C in every record** (176 of 176) — not a real
  measurement. Live temperature (`0x14`) acks but never reported a value.
- **Recordings decode.** Frames are Opus **CELT wideband, 20 ms** (TOC config 23);
  `OMX.google.opus.decoder` handles them. A 35-packet, 8.4 s file moved in 2.1 s
  (~7.5 KB/s, ≈4× real time). The ring held 7 files — the oldest from 12:37.
- **Moving them all works** (21:43): seven files, 8–24 s each, oldest first, each
  acked the moment its raw copy was on disk; the count went 7 → 0 and every file
  was a different recording. Audio state reads **32** while the ring is sending
  (between each `0x34` and its first packet) — not named in LoraFit.
- **The ring starts its own MTU exchange at connect**, so Android reports
  `onMtuChanged` twice about 0.4 s apart. Running service discovery on each lost an
  in-flight read and wedged the GATT handle; discover once per connection.
- **Live heart rate is slow but plausible:** after `0x07`, one reading — 72 bpm —
  arrived 2 min 45 s later, then `0x11` (done). Unprompted `0x0B` readings also arrive
  about every 5 minutes (111, 75 — the same suspect values as the history), so an
  on-demand reading looks more trustworthy than the ring's scheduled ones.
- **`0x0F` echoes its two bytes** (`00 01` → `00 01`). No data reply seen yet.

## 12. How LoraFit turns the data into reports ✅

**The ring keeps about seven days.** LoraFit's background sync asks for day offsets
0–6; anything older is gone from the ring. Week, month and year reports therefore
need the host to keep its own history — LoraFit keeps a local database.

**Sleep** — implemented in
`lib/services/ring/sleep_analysis.dart`:

- *The night of day D* = samples from **18:00 on D−1 to 12:00 on D**, trimmed to the first and last
  sample of quality 2–4. "Fell asleep" is shown one sample (5 min) before the first,
  "woke" is the last. 12:00–15:00 is shown separately as a nap.
- **Score 0–100** = duration × 0.35 + deep % × 0.30 + light % × 0.20 + REM % × 0.15,
  percentages of everything inside the night, awake included:

  | Part | points |
  |---|---|
  | duration (h) | <4 → 0 · 4–5 → 60 · 5–6 → 80 · **6–9 → 100** · 9–10 → 80 · 10–11 → 70 · ≥11 → 80 (sic) |
  | deep % | <5 → 0 · 5–10 → 60 · 10–15 → 80 · **≥15 → 100** |
  | light % | <40 → 60 · 40–50 → 80 · **50–60 → 100** · 60–70 → 80 · 70–80 → 50 · ≥80 → 30 |
  | REM % | <5 → 0 · 5–10 → 60 · 10–15 → 80 · **15–25 → 100** · 25–30 → 80 · ≥30 → ? (the vendor's value is unknown; we use 60) |

  Labels: ≥90 perfect · ≥80 good · ≥60 average · ≥40 poor · else severe insomnia.
- **Week/month:** each night is filed under the day you woke (sample time + 12 h). The
  headline is the average sleep and average score over nights that have sleep — empty
  nights do not drag it down. There is no year view.

**Heart rate, SpO₂, steps** — average, minimum and maximum per metric per day.
Day view: raw 5-minute
points plus the day's average/min/max, "latest" = the newest record. Week/month: one
min–max bar with the average per day; the period headline is the mean of the daily
averages. Steps use each day's MAX (the records are running totals), and the day chart
is hour-by-hour differences. No year view for any metric.

**Stress, HRV, blood pressure: none.** `openCloseBpBsHrv` (0x0F, payload
`[type, on/off]`) exists but LoraFit reads no reply to it. FOX-1's stress
figure is its own estimate from heart rate, steps and sleep —
`lib/services/ring/stress_estimator.dart`, which documents its sources and limits.

