# Call agent ↔ main agent integration — implementation plan

Written 2026-08-27, after the night the bridge was proven end to end.
Read [CALL_AUDIO_FINDINGS.md](CALL_AUDIO_FINDINGS.md) first — it records the
hardware constraints this plan assumes.

## What is already proven

Do not re-litigate these; they are measured, not assumed.

- Bridged calls work: caller ↔ ESP32 (HFP/SCO) ↔ SPP ↔ app ↔ Gemini Live.
  61-minute call, `resync 0`, `drop 0`.
- One HFP slot on this device. `HfpRouter` moves it: board during a bridged
  call, earbud otherwise. ~850 ms each way.
- **Dropping the board mid-call hands the live call to the device.** The carrier
  call survives; telephony falls back to the device mic, and `HfpRouter` forces
  speakerphone so it lands somewhere audible. This is the whole mechanism behind
  `transfer_to_human` — it already works, it just has no UI and no policy.
- Re-plugging an earbud during a handed-over call re-routes correctly, repeatedly.
- The call agent's Gemini session is separate from `AISession`'s.

## Architecture

### Two sessions, never one

The call agent and the main agent keep separate Gemini Live sessions.

- **Audio topology.** One Live session has one input and one output stream. The
  caller (16 kHz over SPP) and the wearer (device mic) cannot share one without
  losing speaker attribution.
- **Lifetime.** A call is minutes; the main session is warm/cold across a day.
- **Trust.** The caller is an untrusted speaker with a direct line to a model
  that holds tools. A shared session shares the tool set and the context.

### New: `CallOrchestrator`

Today the call agent's lifecycle lives in `bridge_test_screen.dart`. It cannot
stay there — a call arrives whether or not anyone is looking at that screen.

```
CallOrchestrator                       (lib/services/call/call_orchestrator.dart)
 ├── owns CallBridgeService            SPP up whenever the board is reachable
 ├── answer policy                     decides on CALLER-ID, before pickup
 ├── spawns CallAgentSession per call  fresh Gemini session, fresh briefing
 ├── CallStateAuthority                one source of truth (see below)
 └── emits CallReport                  → AISession / store / call card UI
```

One `CallAgentSession` **per call**, never reused. That is also what finally
kills the context-bleed bug for good: resuming a handle across calls let one
caller receive the previous caller's answer 900 ms before their own call was
even answered.

## Call state authority — and what happens when things end badly

This is the part the naive design gets wrong.

**The board is our only source of call state while it holds HFP.** The moment we
disarm and drop the board's HFP — which is exactly what `transfer_to_human`
does — the board has no AG link and sends no more CIEV indicators. **We go blind
to call state at the very moment a human is on the line.**

So call state needs two sources and one authority:

| Phase | Authority | Fallback |
|---|---|---|
| Bridged (board armed, HFP up) | board `CALL-STATE` frames | `AudioManager.mode` |
| Handed over (board HFP down) | `Fox1InCallService` | `AudioManager.mode` polling |
| No bridge at all | `Fox1InCallService` | — |

`AudioManager.mode == MODE_IN_CALL` already works on this device —
`CallBridgeService.holdUntilCallEnds()` relies on it and it is self-clearing.
`Fox1InCallService` gives real state but needs default-dialer.

Feed both into one `CallSession` state machine. **Every transition must be
idempotent** — two sources will report the same hangup and both will arrive.

### Failure matrix

| Event | What happens | What must happen |
|---|---|---|
| **Caller hangs up mid-call** | Board sends `[0,0]`, already handled | Emit `CallReport` from what we have — the report must not depend on a graceful `end_call` |
| **Caller hangs up during handover** | Board is gone; no CIEV | InCallService / mode poll must catch it, dismiss the wearer prompt, stop the vibration |
| **Carrier drops the call (signal)** | Same as hangup, no goodbye | Same path; mark report `unresolved: true` |
| **Cellular data drops, call survives** | Gemini unreachable, agent goes silent, caller hears nothing | See below — this needs a real answer |
| **Board powers off mid-call** | Handover (proven tonight) | Alert the wearer; do not silently transfer |
| **Gemini session expires** | Handled — reconnect on resumption handle | Keep; it carried six reconnects in an hour |
| **App killed mid-call** | Foreground service now held via `holdForCall` | Verify; on restart, adopt the in-progress call rather than ignoring it |

### The data-drop case needs pre-recorded audio

Voice and data are separate. The carrier call survives a data outage; Gemini
does not. The 20-second stall watchdog reconnects, but if data is genuinely gone
the reconnect fails repeatedly and **the caller sits in silence**.

We cannot synthesise a reply without the network. So ship a small set of
pre-recorded 16 kHz mono WAVs in assets and play them over SPP:

- `holding.wav` — "One moment, I'm having trouble with my connection."
- `apology_end.wav` — "I'm sorry, I can't hear you properly. He'll call you back."

Escalation: 20 s no agent → `holding.wav`; 45 s → `apology_end.wav` then
`end_call`. Do not attempt `transfer_to_human` here unless the wearer prompt can
actually be shown — a silent transfer is worse than a clean apology.

## Tools

### Trust boundary

`NativeToolsBridge` is the wrong bridge for the call agent. Build a sibling with
its own **allowlist** — not the main bridge plus a filter. Allowlists in one
place do not drift; filters do.

```
CallToolsBridge implements AgentBridge   (lib/services/agent/call_tools_bridge.dart)
```

**Call agent may have:**

| Tool | Notes |
|---|---|
| `end_call` | Always finish the current turn before hanging up |
| `transfer_to_human` | See sequence below |
| `take_message` | Writes to quarantine, not to memory |
| `schedule_callback` | Proposes; the wearer confirms |
| `check_availability` | Read-only calendar |
| `recall` | Scoped to this contact only |

**Call agent must NOT have:** `launch_app`, the screen-automation set
(`get_screen`/`tap`/`swipe`/`type_text`/`press_back`/`press_home`/`scroll`),
`make_call`, `send_message`, `set_alarm`, `set_volume`, `set_brightness`, or the
generic `execute` relay.

Every one of those is something a caller can talk it into. On 2026-08-27 the
*main* agent mis-heard noise as Hindi and launched YouTube unprompted — that is
the same failure mode with a friendly input.

### `transfer_to_human` sequence

1. Agent says it is transferring (finish the turn — do not cut it)
2. `sendArm(false)` — board stops taking call audio
3. `HfpRouter.releaseToUser()` — board HFP down, earbud or speaker up
4. **Keep SPP open** — so the human can hand it back
5. Stop the `CallAgentSession` (privacy: it must not sit listening to a human
   conversation)
6. **Alert the wearer** — vibrate, wake screen, full-screen prompt:
   `"Amina is on the line"  [Take call]  [Back to agent]`
7. Switch call state authority to on-device telephony

**Timeout is mandatory.** No response in ~15 s → re-arm, agent resumes and
covers: *"Sorry, I can't reach him right now — can I take a message?"* Without
this the caller sits in silence, which is the worst outcome this product has.

## Data contracts

### Briefing (trusted, main → call)

Built fresh per call, into the call agent's system prompt: caller number,
matched contact name, wearer profile, standing instruction for that contact,
short recent-context digest.

### CallReport (quarantined, call → main)

A **forced tool call**, not free text, so it parses:

```json
{ "caller": "0200000001", "contact": "Amina", "duration_s": 184,
  "summary": "...", "commitments_made": [], "action_items": [],
  "callback_requested": true, "unresolved": false,
  "caller_asserted": ["says he already paid the deposit"] }
```

`caller_asserted` is the important field. Anything a caller merely *said* is
recorded as a claim, never as fact. "Remember that Alex agreed to pay me €500"
is a sentence a caller can simply say out loud.

### Shared store

Both agents get `recall(query)`. Only the main agent gets unrestricted
`remember(...)`. Call-agent writes land in quarantine for the wearer or the main
agent to promote or discard.

Retrofitting a trust boundary into a memory store is miserable. Build it in now.

## Call history — the thing that makes it one assistant

Without this the agent meets every caller as a stranger, and the product is a
voicemail robot. With it, this works:

```
wearer  → main agent: "call the mechanic for an update"
main    → call agent: outbound, briefed with the task
mechanic: "still waiting on the part, I'll ring you back"
call    → main agent: CallReport { callback_requested: true }
   … later …
mechanic rings in
call agent picks up ALREADY KNOWING about the part and the promised callback
mechanic: "got that part in"    ← agent understands "that part"
call    → main agent: CallReport { action_items: ["collect Thursday"] }
```

The whole loop turns on the agent having the previous call in hand *before* it
speaks.

### Storage

SQLite (`sqflite`) rather than JSON files — the access pattern is "rows for this
number, newest first", which is a query, not a file read.

```
calls(
  id, thread_id, caller_raw, caller_e164, contact_name,
  direction, started_at, duration_s,
  summary, commitments_json, action_items_json,
  caller_asserted_json, callback_requested, unresolved
)
```

### Four things that decide whether this works

**Normalize the number, key on the normalized form.** `0200000001`,
`+233200000001` and a contacts match are the same human. Key on E.164, keep the
raw string alongside for display. Get this wrong and one person accumulates
three unrelated histories, and the agent still meets them as a stranger.

**Threads, not just caller history.** The mechanic example is a *thread* — "the
brake job" — that happens to run over one number, but might not. The garage
could call from a different line; the same mechanic might have two jobs running.
Main agent opens a `thread_id` when it dispatches a task; the call agent
attaches inbound calls to an open thread when the caller matches. Caller history
answers "who is this"; the thread answers "what are we in the middle of".

**Budget the briefing.** Do not paste forty summaries into the system prompt.

- last 3 summaries verbatim
- a rolling digest of everything older (regenerate it when it grows past ~10)
- **all** open commitments and action items, regardless of age

This matters for latency, not just tokens: on auto-answer you are composing the
briefing inside the two rings before pickup.

**`caller_asserted` stays marked forever.** When a summary is digested into the
rolling digest, claims must stay tagged as claims. Otherwise "he says he already
paid the deposit" quietly becomes "he paid the deposit" after two rounds of
summarisation, and the caller has written to the wearer's memory just by
repeating themselves.

Unknown numbers get history too — repeat-caller detection is most of what makes
screening useful.

### Tools this adds

| Tool | Who | Notes |
|---|---|---|
| `recall_calls(contact)` | both | Read-only. Call agent scoped to the current caller only |
| `open_thread(purpose, contact)` | main only | Dispatching a task |
| `close_thread(id, outcome)` | main only | |

The call agent never opens or closes threads — it attaches to them. Otherwise a
caller can talk it into opening work items.

## Auto-answer

**Policy** — keyed off the caller ID the board sends *before* pickup:

- known contact + allowed → auto-answer after ~2 rings
- unknown → ring through, or answer with a screening persona
- blocked → do not touch

Always ring for a beat first. Instant pickup denies the wearer their own call
and will feel like the device stealing their phone.

**Mechanism** — open question. `TelecomManager.acceptRingingCall()` is
system-only. Preferred path is `Fox1InCallService` + `Call.answer()`, which
needs default-dialer (already a known requirement). Fallback: reflect
`BluetoothHeadset.acceptCall`, the same pattern that worked for the HFP slot.

**Disclosure:** many jurisdictions require telling a caller they are speaking to
an AI. Cheap in the greeting, expensive to retrofit.

## Build order

Auto-answer last, because it is the one that fails in front of a real caller.

**Steps 1-3 are done and verified on hardware (2026-08-27).** The call-state
authority survives a hand-over; the allowlist, `end_call` and `CallReport` work
including on abrupt hangups; `transfer_to_human` completes on all three paths
(timeout, take, send-back) with re-arm afterwards.

Two things that testing taught, worth keeping:

- **The wearer prompt has to be a `SYSTEM_ALERT_WINDOW`.** During a call the
  vendor's in-call UI owns the screen. An in-app Flutter overlay is drawn where
  nobody can see it; a full-screen-intent notification only launches an activity
  when the screen is off or locked; and this device will not open the shade over
  the dialer. See `ui/TransferOverlay.kt`.
- **The agent invents facts to fill gaps in its briefing.** With no owner name
  in the prompt it told a caller the owner was "Todd", twice, unprompted. This
  is the concrete argument for step 5 — the briefing is not a nicety.

1. ✅ **`CallOrchestrator` + `CallStateAuthority`** — lift lifecycle out of
   `bridge_test_screen.dart`; two state sources, one idempotent machine.
   *Test: caller hangs up during a handover and we notice.*
2. ✅ **`CallToolsBridge` + `end_call` + `CallReport`** — the allowlist and the
   handoff contract. The report is what makes it feel like one assistant.
   *Test: abrupt hangup still produces a report.*
3. ✅ **`transfer_to_human` + wearer prompt + timeout** — the sequence above.
   *Test: transfer, ignore it, confirm the agent takes the call back.*
4. ✅ **Offline fallback audio** — generated speech clips + hold loop, escalation
   timers, hold music during transfer.
   *Test: flight-mode the data mid-call; caller should hear the apology, not silence.*
   Flight mode turned out to be untestable — the dialer owns the screen and the
   shade will not open over it, the same wall the transfer prompt hit. The
   bridge screen's **drop link** button arms a simulated outage that fires ten
   seconds into the next call instead. Verified 2026-08-27: holding line at
   +22 s, apology at +46 s, `end_call` at +51 s after the clip finished, with
   `resync 0 drop 0` across 1029 frames.

   Building this surfaced a defect that would have made the whole step inert:
   the two fallback plays sat below `_reconnecting` and `isConnected` in
   `_checkAlive`, so they could only fire while the socket was up but quiet —
   never during an actual outage. Escalation now sits above those guards; only
   the reconnect attempt is gated by them.
5. ✅ **Call history + threads** — normalized keys, budgeted briefing.
   *Test: the mechanic loop above, end to end, across two calls.*
   **Deviation: one JSON file, not SQLite.** SQLite means a native plugin on an
   AOSP build that has surprised us before, to hold a few hundred rows only ever
   read one caller at a time. `call_history.json` in the external files dir,
   rewritten per call, capped at 300 callers x 12 calls, degrading to in-memory
   if the directory is unreachable. Revisit if the briefing ever needs querying
   across callers rather than looking one up.

   **Matching is on the last nine digits**, not E.164. The board's caller ID
   gives `0200000001` and contacts gives `+233200000001`; keying on the raw
   string makes those two strangers, and hard-coding a dialling prefix is wrong
   the first time the wearer travels. Nine digits can collide across countries —
   on a personal device that is a rarer, smaller failure than never recognising a
   repeat caller.

   Also fixed here, same root cause as the "Todd" hallucination: the call prompt
   was a hard-coded string with no identity in it. It is now composed from the
   wearer's own Settings — the opening paragraph of their system prompt (where
   the assistant's name lives) plus the user profile — so the agent introduces
   itself by name and knows who it answers for. See `call_briefing.dart`.
   16 unit tests in `test/call_history_test.dart` cover the pure logic.
   **Letting her finish.** `end_call` and `transfer_to_human` used to take
   effect the instant the tool call arrived. The model emits the tool call
   *before* it finishes emitting audio, so the caller heard "Have a good d—";
   on a transfer they never heard "please hold" at all, because the audio gate
   shut 130 ms before she said it. `GeminiCallAgent.letHerFinish()` now gates
   both, and it waits on three things, in this order:

   1. **Generation stops** — 600 ms with no new chunk. Not `turnComplete`: a
      turn ending in a tool call is usually closed by an `interrupted` instead,
      so a wait on turnComplete alone hit its cap every time.
   2. **Playout completes** — the one that actually mattered. Gemini generates
      far faster than real time (four seconds of speech in one and a half), so
      "generation stopped" is not "the caller has heard it". Every chunk adds
      `bytes / 32000` seconds to a running `_speechEndsAt`; the wait runs until
      that passes. The clock is reset on `interrupted`, `beginTransfer` and
      call end, because each discards the queue.
   3. **Queue drain + a 700 ms tail** — the board keeps its own buffer (it logs
      `pacing primed with 4 frames (240 ms)`) and SCO adds more. Note the drain
      requires the queue to read empty three times 40 ms apart: the pacing
      thread feeds silence continuously, so a single empty reading is jitter,
      not silence, and `q 0` appears mid-call routinely.

   **Outgoing calls carry a number too.** The board reports an outbound call
   as `[0,2] dialling` and never sends a caller ID for one, so an outbound call
   had no key: one ran 195 s and produced a commitment, an action item and a
   claim, none of which could be filed. `DialedNumbers` supplies it from two
   sources at two different moments — `make_call` records what we dialled
   (exact, available at call start, so the agent can be briefed before it
   speaks), and the call log covers a number the wearer dialled by hand
   (Android only writes the entry when the call *ends*, so it cannot brief that
   call — it files it, and the next one is briefed). Both are time-bounded:
   filing a conversation under the wrong person is worse than filing it under
   nobody, and far harder to notice.

6. ✅ **Shared store with quarantine** — `recall` for both, `remember` for one.
   `MemoryStore` (`lib/services/memory/memory_store.dart`), one JSON file
   beside the call history. A `Fact` carries `trust` (known | claimed),
   `subject` (normalised number, or empty for general notes) and `source`.

   **Two rules, and the second is the load-bearing one.** Only the main agent
   can write a fact — the call agent has no `remember` at all. And the call
   agent's `recall` passes `onlySubject: true`, hard-scoped to whoever is on
   the line. Without that second rule the first is decorative: *reading* is the
   leak, writing is only the corruption. "What did Alex say about the
   deposit?" is a sentence anyone can say out loud, and a helpful assistant
   would answer it.

   | | main agent | call agent |
   |---|---|---|
   | `remember` | yes | **no such tool** |
   | `recall` | everything | this caller only |
   | `review_claims` / `resolve_claim` | yes | no |

   Claims enter by exactly two routes, both marked and attributed:
   `take_message`, and every `caller_asserted` entry on a `CallReport`. They
   render as `UNVERIFIED CLAIM by <source>, not a fact` **per line** — not once
   as a heading, because a model summarising a mixed list drops the heading and
   keeps the sentences. Promotion via `resolve_claim` keeps the original
   provenance in the record rather than erasing it.

   Unreadable `trust` values fail closed to `claimed`. 16 tests in
   `test/memory_store_test.dart` cover the boundary itself.

   **Both stores are Riverpod singletons — `memoryStoreProvider` and
   `callHistoryProvider` — and must stay that way.** The first build made one
   per session, which looked harmless and was not: the main agent's copy was
   loaded at session start, so `review_claims` reported "nothing waiting" while
   three claims sat in the file, and whichever instance saved last overwrote
   the other's writes.

   **A fact about a person needs that person's number.** The call agent's
   `recall` is keyed on the caller, so `remember("my brother is Emmanuel")`
   filed with no `about_number` is invisible when Emmanuel telephones. The tool
   description now says so and points at `get_contacts`; this is the seam where
   the scoping rule costs something, and it is the right price.
7. ✅ **Crash re-adoption** — persist call context, re-adopt and re-arm on
   restart. `crash_journal.dart`. FOX-1 is the HOME launcher, so a kill is
   followed by a relaunch within seconds — while the call carries on regardless,
   with the caller now talking to an unarmed board and a dead session.

   `in_flight_call.json` holds the caller, the start time, the Gemini
   resumption handle and which board/stage to come back to. Written when a call
   becomes real (not when it ends — the point is to survive not reaching the
   end), deleted on a clean end. Finding it on startup means the last run did
   not get to delete it.

   `CrashJournal.decide` is pure and covers the three cases: **readopt** (a call
   is still up), **fileOnly** (it ended while we were dead — too late to rejoin,
   but the conversation is still filed rather than lost), and **nothing** for a
   snapshot older than three minutes. That staleness bound matters: without it a
   journal entry nobody cleared would have the device seize an unrelated call the
   wearer is having right now.

   "Is a call still up" is answered by **telephony** (`AudioManager.mode`), not
   the board — the board is precisely what was lost, so asking it is circular.

   **The check runs at app startup, not on the bridge screen.** The recovery
   itself lives in `BridgeTestScreen` because that is where the session is
   assembled — but after a crash the app relaunches to the *watchface*, and that
   screen is never built. Recovery would have fired only if the wearer opened
   Settings → Call Bridge, which during a call they cannot: the dialer owns the
   screen. So `main.dart` checks the journal after the first frame, handles the
   two cases that need no bridge (file it, discard it) in place, and opens the
   bridge screen only for a live call to rejoin.

   **HOME is not restarted promptly, and that nearly sank this.** The design
   assumed FOX-1 coming back "within seconds" because it is the launcher.
   Android restarts HOME when HOME is *needed* — and during a call the dialer is
   foreground, so nothing needs it. Measured: **99 seconds**, by which time the
   caller had gone and the correct decision was `fileOnly`. The prompt path is
   `CallBridgeService`, which is `START_STICKY`: on a restart with a null intent
   it checks `AudioManager.mode` and, only if a call is genuinely up, relaunches
   the activity. Starting an activity from a service is unrestricted on API 27;
   on Android 10+ the `SYSTEM_ALERT_WINDOW` the hand-over overlay already needs
   is the exemption.

   Recovery navigates via a `navigatorKey`, not `Navigator.of(context)`: the
   app state sits *above* its own `MaterialApp`, so `Navigator.of` finds nothing
   and throws — silently swallowing the re-adoption. It retries for two seconds
   because the navigator is not guaranteed attached the instant the first frame
   is drawn, and there is a live caller waiting.

   **Testing it needed a lever.** Force-stopping from Android Settings is
   unreachable mid-call for the same reason. The bridge screen has a **crash
   app** button that arms a real `Process.killProcess` twelve seconds into the
   next call — the same armed-beforehand pattern as step 4's *drop link*.

   **The stats backstop had to be taught about adopted calls.**
   `_reconcileCallState` reads the board's tracked indicators as a safety net.
   A re-adopted call is one the board never announced — we restarted into the
   middle of it — so those indicators are still zero, and three seconds after
   every adoption the backstop "corrected" `_callActive` to false. That flag
   gates the agent's audio: she carried on talking and the caller heard nothing,
   twice, before the log line `call state corrected from stats — idle` gave it
   away. While `_adoptedWithoutBoard` is set the board cannot end the call;
   telephony is polled instead, and the first real board transition clears the
   override.

   Re-adoption goes through the ordinary `_start()` path, then calls
   `GeminiCallAgent.adoptCall()`. That method exists because nothing else would
   fire: the board mentions an in-progress call only in its post-arm `initial`
   dump, which is deliberately ignored, so the agent would otherwise come up
   with no caller number, no briefing, no recall scope and `_callActive` false —
   gating its own audio off. The injected context tells the model it was cut off
   and to apologise in one sentence before carrying on.
8. ✅ **Auto-answer** — policy behind a setting, mechanism degrading.
   `auto_answer.dart`: `AutoAnswerPolicy` is pure (no channels, no timers, no
   lookups) because a wrong answer here means the device took a call it had no
   business taking. Modes off / known / everyone, **off by default** — the
   device answering the wearer's phone is opted into, never discovered.

   Rules, in order: **blocked wins over everything**, including `always` and
   `everyone` — a block list whose entries another setting can override is not
   a block list. A withheld number always rings through, even under `everyone`:
   there is nothing to file the conversation against, and they chose not to say
   who they are. `ringFirst` is never zero; instant pickup denies the wearer
   their own call.

   **Mechanism — this section's original claim was wrong.** It recorded
   `TelecomManager.acceptRingingCall()` as system-only. That stopped being true
   at **API 26**, when `ANSWER_PHONE_CALLS` became a normal runtime permission.
   So the supported path was available the whole time and the default-dialer
   decision never gated auto-answer at all.

   `answerCall` tries `Fox1InCallService.answerRinging()` (dialer, best) then
   `acceptRingingCall()` (`telecom`), and returns which it used. The first build
   reflected `BluetoothHeadset.acceptCall` as a fallback and it could never have
   worked: `acceptCall` is on `BluetoothHeadsetClient`, the **headset** role.
   The device is the phone. That path is deleted.

   Failure *reasons* are returned to Dart rather than logged natively — an
   `android.util.Log` line on a device with no ADB is a line nobody can read, and
   it cost a test round to learn that. Settings carries a **Grant answer
   permission** button for the same reason.

   Only `CallPhase.ringing` triggers it — never `dialing`, which is our own
   outbound call. A pending pickup is cancelled when the wearer answers first
   or the caller rings off.

   **Disclosure** is carried by the greeting: she introduces herself as an AI
   assistant on the first line, which matters more on an auto-answered call
   than a wearer-answered one because the caller did not choose to reach a
   machine.

## Resolved questions

### Default dialer — defer it; it only gates auto-answer

"Default dialer" means FOX-1 becomes the phone app. Android binds its
`InCallService`, which then gets `Call.answer()`, `Call.disconnect()` and real
call state — but FOX-1 must also *show the in-call UI for every call*,
including ones the wearer dials. If that UI is broken, the device cannot make
calls.

The decision splits cleanly, so it does not need making yet:

- **Post-handover call state (steps 1–3):** `AudioManager.mode` polling is
  enough. All we need there is "is a call still up", to dismiss the wearer
  prompt and stop the vibration. Caller ID and ring state were already captured
  before the handover. `CallBridgeService.holdUntilCallEnds()` proves the mode
  check works on this device.
- **Auto-answer (step 6):** genuinely needs it. You cannot answer a call from
  mode polling.

So: build `CallStateSource` as an interface with a mode-polling implementation
now, and add an `InCallService` implementation when the dialer work happens.
Do not block step 1 on it.

When you do get to auto-answer, **take the dialer rather than reflecting**.
`BluetoothHeadset.acceptCall` would work on API 27 for the same reason the HFP
lever does — no non-SDK enforcement — but the product targets newer Android
where that gate closes. Same argument that made the HFP work app-side instead of
board-side. And FOX-1 is already the HOME launcher; taking the dialer is
consistent with what it already is, not a new category of risk.

### Board over SPP with HFP down — no, and it is worse than "no"

Answered from firmware, not guessed. In
the call bridge's `src/main.c`, `spp_send_call_state()` is called from
exactly two places — `ESP_HF_CLIENT_CIND_CALL_EVT` (line ~738) and
`ESP_HF_CLIENT_CIND_CALL_SETUP_EVT` (line ~748). Both are HFP indicator events.
**With no SLC the board receives no CIND events and therefore sends nothing.**

And the sharp edge: on `CONNECTION_STATE_DISCONNECTED` (line ~689) the board
sets `g_call_active = false; g_call_setup = 0` and does **not** send a frame.
So its internal state silently becomes "idle" while the call is in fact still
running on the device. Any later frame would be actively wrong.

Two consequences:

1. Post-handover state **must** come from on-device telephony. Not optional.
2. Worth a small firmware change: on SLC disconnect, send a distinct
   *state-unknown* marker rather than silently zeroing. The app knows when it
   dropped HFP itself, but not when the board goes out of range — and in that
   case a stale "idle" is a trap.

### Fallback audio — generate once, cache, plus hold music

Speech clips: generate at first run (or first successful connection) from
Gemini, cache as 16 kHz mono PCM in the app's files dir, regenerate only if the
voice setting changes. No licensing, matches the agent's own voice, and the
generation happens when the network is *good* rather than when it has failed.

**Hold music during `transfer_to_human`.** The 15-second wearer-alert window is
otherwise dead silence for the caller, which is exactly when a real person hangs
up. Play a loop the way a call centre does — it also signals "you are being
transferred, stay on the line" without words.

- Speech clips: Gemini-generated, cached.
- Hold loop: **bundled or synthesized**, not Gemini — it must exist before the
  first successful connection, and it needs to loop seamlessly. A short
  programmatically generated pad avoids licensing entirely.
- Both are just PCM into the same SPP path as Gemini audio; the ADPCM encoder
  does not care about the source, only that the stream stays continuous.

### App killed mid-call — re-adopt and re-arm

Requires persisting enough to resume, written **at call start and on each
report update**, not at teardown:

- caller number, contact match, call start time
- the briefing that was composed
- the Gemini resumption handle
- the partial report so far

On restart: reconnect SPP, **verify with the call state authority that a call is
actually still up**, and only then re-arm and resume the Gemini session on the
handle. Re-arming into a call that already ended would push agent audio at a
dead line. The `holdForCall` foreground service should make this rare, but
"rare" is not "never" on a 192 MB heap.
