# Design

Why micpeg is built the way it is, and the three CoreAudio traps that shaped it.

The Korean development log with the full blow-by-blow — including the tests that failed and
what each failure changed — is at [`ko/engineering-log.md`](ko/engineering-log.md).

---

## Constraints

In priority order, as stated by the person who needed this:

1. **Input only.** Never read or write the default output. Do not even offer an
   output-pinning option.
2. **Optimization above features.** No meaningful memory, CPU, or power cost; no interference
   with other OS behaviour.
3. **Respect manual selection.** If the user deliberately picks another microphone, leave it.

Constraint 1 is enforced structurally rather than by discipline: output keys are absent from
the config schema, so there is nothing to switch on. `grep -c DefaultOutputDevice
Sources/micpeg/main.swift` returns 0.

---

## Three traps

These cost the most to find, and they are the part worth reading if you are writing your own
CoreAudio agent.

### 1. `dispatchMain()` silently kills every listener

The obvious choice for a daemon with no UI is `dispatchMain()` — it looks lighter than
`CFRunLoopRun()`. It is a trap.

`AudioHardwareDeprecated.h:193-197` states that the HAL attaches its notification handlers to
`CFRunLoopGetMain()`. `dispatchMain()` does not park the main thread; it calls `pthread_exit()`
on it ([Quinn, Apple DevForums 794775](https://developer.apple.com/forums/thread/794775)). The
run loop object survives, but nothing services it.

Handing your own dispatch queue to `AudioObjectAddPropertyListenerBlock` does not save you —
the HAL still has to receive the mach notification on *its* run loop before it can redispatch
to your queue.

The failure is invisible: the process registers cleanly, logs "listening", uses no CPU, and
enforces nothing. An idle daemon with dead listeners is indistinguishable from an idle daemon
with live ones, which is exactly why this nearly shipped.

**Use `CFRunLoopRun()`, and do not touch `kAudioHardwarePropertyRunLoop`.** Writing NULL to
that property is a second trap layered on the first: the constant lives in the deprecated
header (`:218`) but carries no `API_DEPRECATED` annotation — its neighbour
`kAudioHardwarePropertyProcessIsMaster` does — so you get no compiler warning at all, and the
"reverts to pre-10.6 behaviour" note is a 16-year-old sentence of unverified current relevance.

A `CFRunLoop` with no timers and no scheduled sources blocks in `mach_msg` on its port set with
no timeout. That is where the 0-idle-wakeups number comes from; it is a property of the design,
not a tuning result.

### 2. `coreaudiod` restarts during ordinary use, and takes your listeners with it

The initial design assumed there was no callback for listener death. There is:
`kAudioHardwarePropertyServiceRestarted` (`'srst'`, `AudioHardware.h:573-577, 631`), documented
as *"any state the client has, such as cached data or **added listeners**, must be re-established
by the client."*

This is not a rare event. On the development machine, uptime was 16 days while `coreaudiod` had
restarted 2 hours 13 minutes earlier, with no reboot — cross-checked against the mtime of
`/Library/Preferences/Audio/com.apple.audio.DeviceSettings.plist`.

Miss it and you get [BackgroundMusic #126](https://github.com/kyleneideck/BackgroundMusic/issues/126):
`kAudioHardwareBadObjectError` (560947818) and an agent that is permanently deaf.

One `'srst'` listener covers both HAL restarts and wake-from-sleep breakage. An
`NSWorkspace.didWakeNotification` hook — the intuitive answer — would not have caught that
16-day-uptime restart at all, and it drags in AppKit.

**Recovery must be narrow.** The first implementation read "re-establish cached state" broadly
and cleared the arrival timestamps too. Because dispatch ordering guaranteed `'dev#'` ran first,
recovery deterministically destroyed evidence that had been recorded milliseconds earlier, and
the agent yielded to the headset every time. The only cache worth discarding is the
`AudioDeviceID` cache — and micpeg does not keep one, because `'uidd'` resolution is cheap
enough that caching IDs only buys you an ID-reuse race.

Recovery now does exactly three things: re-register listeners, invalidate the pending
self-write tag, and re-apply the pin.

### 3. Timing cannot tell an automatic switch from a deliberate one

The intuitive heuristic — "if the device just appeared, the switch was automatic" — fails
specifically on AirPods, which is the case that matters.

AirPods complete A2DP (output) first and HFP (input) seconds later. Measured on real hardware,
the input and output objects are published as **separate events ~16 ms apart**, and which of
them appears "new" differs between connections. Worse: macOS has been observed setting the
default input to the headset **before its input object exists at all**.

So a 5-second grace window expires mid-negotiation and the agent classifies an automatic
switch as a user decision — failing at precisely the moment it exists to act.

**Primary classification is transport type, not timing.** Bluetooth is the only route by which
macOS takes the default input on its own. Everything else — USB, Virtual, Unknown, BuiltIn —
is treated as a deliberate choice and yields immediately.

There is no signal that identifies the initiator of a change. This was checked, not assumed:
`log stream --predicate 'subsystem == "com.apple.coreaudio"'` produces zero lines across these
transitions, `log show --last 30m` likewise, and the callback signature carries no initiator
field. A heuristic is unavoidable; the question is only which signal to build it on.

---

## Architecture

A single Swift binary that is both the launchd agent and the CLI. Links CoreAudio and
Foundation only — no AppKit, no dependencies.

```
main thread ── CFRunLoopRun() ──► blocks in mach_msg, no timers, no polling
                     │
        HAL delivers notifications
                     ▼
              hal queue (serial)  ──► hops to work queue
                                          │
                                    work queue (serial)
                                          │
                              ┌───────────┼───────────┐
                            dev#         dIn         srst
                        record arrivals  evaluate()  re-register
                        re-apply pin     revert/yield re-apply pin
```

Two queues, not one. Listener teardown runs on `work` while the HAL delivers on `hal`, so
`AudioObjectRemovePropertyListenerBlock` never waits on the queue that is delivering to it.

### Three listeners on `kAudioObjectSystemObject`

| Selector | Purpose |
|---|---|
| `kAudioHardwarePropertyDevices` (`'dev#'`) | Record device arrivals/departures, re-apply the pin |
| `kAudioHardwarePropertyDefaultInputDevice` (`'dIn '`) | Judge and revert |
| `kAudioHardwarePropertyServiceRestarted` (`'srst'`) | Re-register everything |

All 29 AudioSystemObject selectors in the macOS 26 SDK (`AudioHardware.h:606-637`) were
reviewed; nothing narrower exists. `'livn'` is per-device and reports dying hardware;
`kAudioObjectPropertyOwnedObjects` is strictly noisier than `'dev#'`.

### Relevance filter

`'dev#'` fires for output-only devices too. On the development machine an external display
re-registered its audio endpoint every 11.3 seconds for 8 hours straight — 3,243 events, 94% of
the log, 32.6 s of CPU and 3.6 MB of heap growth, all of it doing nothing, because an
output-only device cannot affect which *input* is default.

A device-list change is now processed only if an arriving device has an input scope, is a pin
target, or is on a blocked transport — or if a departing device was input-capable or a target.
`inputCapableUIDs` is tracked because a device that has already left cannot be queried.

The blocked-transport clause is load-bearing: AirPods publish their output object ~16 ms
*before* their input object, and in real logs **that output-object event is what triggered the
revert**, because macOS had already moved the default input.

Measured effect: **10.1 ms → 0.070 ms per filtered event, a 145× reduction.**

### State machine

| State | Condition | Behaviour |
|---|---|---|
| `ABSENT` | No configured target present | Completely inert |
| `PINNED` | Target present, watching | Reverses blocked-transport transitions only |
| `YIELDED` | User chose something else | Inert until the target reconnects, `micpeg on`, or the yielded-to device disappears |
| `PAUSED` | `micpeg off` | Inert |
| `BACKOFF` | 3 reverts within 5 s | 60 s inert + a loud warning |

`BACKOFF` must log loudly. Per [FB15113809](https://developer.apple.com/forums/thread/763583), a
Continuity-poisoned HAL returns `noErr` while reverting forever, which would burn through the
guard in silence.

### Deciding whether to revert

Three independent pieces of evidence, checked in order of strength:

1. **Post-write grace** — the default moved within `postWriteGraceSeconds` of micpeg's own
   write. Structurally a flip-back; nobody re-picks a device in 400 ms. This depends on nothing
   but micpeg's own clock, which makes it immune to the entire class of failures that broke the
   arrival-window approach three times.
2. **System churn window** — armed for 15 s at startup and after a HAL reset, when macOS is
   re-deciding every default from scratch.
3. **Arrival window** — the device itself, or any blocked-transport device, appeared within
   `arrivalWindowSeconds`.

All three are needed. In one HAL-restart test, micpeg had not written anything (the default was
already correct), so there was no write clock — the first hijack 4.3 s later could only be
caught by the arrival window. The re-hijack 436 ms after that revert could only be caught by
post-write grace. Either mechanism alone fails.

Observed flip-back intervals across three runs: 406 ms, 436 ms, 463 ms. Consistent.

### Two rules learned from a prior art bug

Derived from real defects in `cli-fix-my-mic`:

1. **Only `'dIn '` may produce a yield verdict.** `'dev#'` records arrivals and re-applies the
   pin; it never decides that the user made a choice. (That tool called its stabilize routine
   from both listeners, so any device-list change within 10 s of a correction was misread as a
   manual re-switch and disabled protection for an hour.)
2. **Tag self-writes explicitly.** Record the expected device ID immediately before writing and
   swallow exactly that one callback — never a boolean "settling" window, which also swallows
   genuine user changes. The tag carries a timestamp and expires, so a stale expectation cannot
   eat a real event later.

### API details that matter

- `kAudioObjectPropertyElementMain`, not `Master` (`AudioHardwareBase.h:208`)
- Resolve UID → ID with `kAudioHardwarePropertyTranslateUIDToDevice` (`'uidd'`,
  `AudioHardware.h:483-489`); do not enumerate
- **Never cache `AudioDeviceID`.** IDs are reused across reconnects; `'uidd'` is cheap
- `takeRetainedValue()` on every CFString getter — the caller owns the reference
  (`AudioHardwareBase.h:650`)
- Treat every set as asynchronous
- Calling set from a listener callback is not a deadlock (`AudioHardware.h:382-389`: only the IO
  context properties `kAudioDevicePropertyDeviceIsRunning` and
  `kAudioDeviceProcessorOverload` dispatch synchronously) — but you still need the queue hop,
  because your set re-fires `'dIn '`
- Check input capability via `AudioObjectGetPropertyDataSize` on `kAudioDevicePropertyStreams`
  in the **input scope** with `dataSize > 0`; no allocation. Scope matters — a Wave:1 is
  1-channel in and 2-channel out

---

## Approaches rejected

| Alternative | Why not |
|---|---|
| **Event-triggered agent** (`com.apple.iokit.matching` on USB attach) | IOKit matching fires on service publication, not on "the default input changed", and there is no `notify(3)` name for audio device changes (verified against `strings /usr/sbin/coreaudiod`). Process launch takes tens of ms, so it corrects after the fact anyway — and if it is not running when the HAL resets, nobody consumes `'srst'`. |
| **Polling** (`StartInterval 5`) | 17,280 process spawns per day to replace a listener that costs 0 idle wakeups. |
| **HAL plugin** | Publishes virtual devices; has no say over the system default. Requires admin install. No benefit. |
| **Aggregate device** | Changes the microphone's identity in every app's picker and in `cpal`'s enumeration. Actively harmful. |
| **Hammerspoon** | 15–25 MB baseline with [multi-GB growth reports](https://github.com/Hammerspoon/hammerspoon/issues/3614). Conflicts with constraint 2. |
| **Bluetooth XPC stream** (`com.apple.bluetooth.connections`) | `xpc_events(3)` is undocumented and every consumer is an Apple daemon; an unprivileged agent that subscribes is likely to receive nothing, without an error. |

Existing tools were evaluated and did not fit: `cli-fix-my-mic` hardcodes the built-in
microphone as the restore target (the exact opposite of the requirement) and its
`shouldBlockAsInput()` has no `Virtual` case, so `default: true` blocks Wave Link's virtual
devices and Continuity iPhone Mic. SoundSource 6 costs $49 and installs a HAL driver.
SoundAnchor is closed-source with an unreachable site, so "does clearing the output list really
mean it never touches output?" cannot be established — and there is no way to confirm it handles
`coreaudiod` restarts, which every reference implementation reviewed had missed.

---

## Why pinning the OS default is sufficient

Verified rather than assumed. Claude Code's voice capture is Rust `cpal` + `coreaudio-rs`
calling CoreAudio AUHAL directly — no browser or Electron layer, so there is no `getUserMedia`
seam to intervene at. `cpal`'s `default_input_device()` reads
`kAudioHardwarePropertyDefaultInputDevice` directly, and there is no device picker. The
[official docs](https://code.claude.com/docs/en/voice-dictation) say only "check your default
input in System Settings".

Because `cpal` resolves the device when push-to-talk is pressed rather than at startup, a late
revert is still a correct revert. There is no latency pressure on the correction path — which
is why micpeg uses a 300 ms debounce and a single 1 s re-verify instead of a polling ladder.
