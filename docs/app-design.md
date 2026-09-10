# Design — the settings app

Why micpeg grows a GUI, and what that must not disturb.

[`design.md`](design.md) covers the daemon: the CoreAudio traps, the judgement logic, and the
reasons the agent is shaped the way it is. **Read it first.** Nothing in this document
overrides it. This document covers only the second face of the program — the app a person
opens to choose a microphone and to confirm the thing is working.

---

## Why a GUI at all

The daemon is finished. The CLI is not the obstacle to other people using it — the obstacle is
that the person whose AirPods hijack their microphone is not necessarily someone who will
`git clone` anything.

Three routes bring someone to this tool:

| Trigger | How they find out |
|---|---|
| Told in a meeting that they sound bad | **After the fact.** Something already went wrong |
| Music degrades whenever AirPods connect | Experienced without knowing the cause |
| A recorder or voice-input tool grabs the wrong mic | Immediately |

The second is larger than it looks. When macOS moves the default input to AirPods, the
Bluetooth link drops from A2DP to HFP and **the audio they hear degrades too**. Pinning input
to a wired microphone prevents the whole transition. Most people never learn the causal chain.

*(This last claim is a README-facing assertion and is on the verification checklist below. Do
not publish it until it has been observed on real hardware.)*

All three want the same thing: *one microphone, decided once, never thought about again.*

## The property that drives every decision

**This app succeeds by not being opened.** Expected lifetime launches: two or three — at
install, when the microphone is replaced, and when the user wonders whether it is still
working.

Three consequences:

1. Onboarding must complete **in one sitting, on one screen**. A multi-page wizard is dead
   code the moment setup finishes.
2. There is **no everyday flow**. If a normal week requires opening the app, the design failed.
3. The only recurring reason to open it is doubt, so **the answer must be visible on open** —
   not one click away.

Consequence 1 means onboarding is not a separate screen: it is the main window's
*unconfigured* state. One window, several states.

## What does not change

The daemon binary is untouched. `evaluate()`, the three listeners, the state machine, the
1,228-line `main.swift` — none of it is refactored to accommodate the app. The daemon keeps
its own deployment target, its own dependencies, and its own guarantees.

Three of the daemon's properties are load-bearing for the app's honesty, and each is now
enforced by a grep in CI rather than by discipline:

| Invariant | Check |
|---|---|
| The app never writes to CoreAudio | `AudioObjectSetPropertyData` absent from `Sources/MicpegApp`, `Sources/MicpegUI`, `Sources/MicpegAudio` |
| The daemon never touches the default output | `DefaultOutputDevice` absent from `Sources/micpeg`, `Sources/MicpegAudio` |
| The daemon cannot open an audio stream | `AVFoundation` absent from `Sources/micpeg`, `Sources/MicpegAudio` |

The first replaces the old proof. Before the app existed, `grep -c DefaultOutputDevice
Sources/micpeg/main.swift == 0` was the whole argument that micpeg does not meddle with audio
output. The app has to *read* the default output to show it, so that grep alone no longer
carries the claim. The replacement is stronger and covers more: **the app performs no CoreAudio
writes at all.** Every mutation goes through the `micpeg` CLI, which owns the single call to
`setDefaultInputDevice`.

The third makes the README's "never opens the microphone" claim survive the arrival of a level
meter. It is now a statement about the *agent*, and it stays literally true. The app opens the
microphone only while the user is running an input test, and asks for permission at that
moment — see [`app-ui.md`](app-ui.md).

## Process model

The important property is that it already exists: the daemon is a launchd agent in its own
process, and the GUI has no relationship to it beyond a config file and a state file.

```
launchd ──► micpeg daemon          (always; survives everything)
                 │
                 ├── writes ~/.config/micpeg/state.json
                 └── writes ~/Library/Logs/micpeg.log
                              ▲
                              │ reads
Dock / Spotlight ──► Micpeg  ─┘      (opened ~3 times, disposable)
                        │
                        └── spawns Contents/MacOS/micpeg for every write
```

So "quitting the app leaves the background agent running" needs no work: no `LSUIElement`, no
hidden window, no intercepted termination. Closing the window ends the GUI process; launchd
holds the daemon.

This is also why the app is **not** a menu bar item. A menu bar app is a second resident
process — 40–70 MB against a daemon that was tuned to 0 idle wakeups and ~4 MB — and its icon
promises "quitting me stops the feature", which here would be false. The two affordances a menu
bar would have provided are replaced:

| Menu bar gave | Replacement |
|---|---|
| "Is it running?" at a glance | The window itself, answering on open |
| An off switch | **System Settings → General → Login Items & Extensions**, which `SMAppService` populates for free |

Using the OS's own off switch matters more than it sounds. A background process the user cannot
find and cannot stop is the thing people are right to distrust.

`applicationShouldTerminateAfterLastWindowClosed` is `true`. The GUI has no reason to linger.

## Source layout

```
Sources/MicpegAudio/   # read-only CoreAudio helpers. No writes. Shared.
Sources/micpeg/        # daemon + CLI. Owns the only setDefaultInputDevice call.
Sources/MicpegUI/      # SwiftUI views. Library target so Xcode previews work.
Sources/MicpegApp/     # executable: @main, wiring, migration. Thin.
```

`MicpegAudio` is an extraction of the existing helper block in `main.swift` (`addr`, `fourCC`,
`osStatusText`, `defaultInputDevice`, `deviceID(forUID:)`, `deviceString`, `deviceUID`,
`deviceName`, `transportType`, `hasInput`, `allDevices`, `transportCode`) — **minus
`setDefaultInputDevice`, which stays in the daemon target.**

This is not the `main.swift` split that `CLAUDE.md` defers. That deferred task is about the
judgement path. This is about a hundred lines of pure functions, and it is done for a specific
reason: those helpers are where the subtle CoreAudio mistakes live — `takeRetainedValue` on
every CFString getter, `kAudioObjectPropertyElementMain` rather than `Master`, input-scope
`kAudioDevicePropertyStreams` with `dataSize > 0`. Duplicating them into the app would create a
second place to get them wrong. `evaluate()` and everything around it do not move.

The `MicpegUI` / `MicpegApp` split exists so SwiftUI previews have a library target to attach
to — see [`app-ui.md`](app-ui.md). It produces one executable either way.

### Deployment target: macOS 14

SwiftPM's `platforms:` is package-wide, so the whole package moves to the app's minimum
version — the daemon cannot keep its own. Since the single distributed artifact is the app
bundle and the CLI now ships inside it, that costs nothing at distribution time.

macOS 14 rather than 13, which `SMAppService` alone would have allowed, because `@Observable`
is 14-only. Without it the state model needs `ObservableObject` and per-property `@Published`
throughout — more boilerplate in exactly the code that bridges CoreAudio callbacks, the file
watcher and the log parser into the view, which is the part most likely to be got wrong.
macOS 14 shipped in September 2023.

**This makes `README.md`'s "macOS 12 (Monterey) or later" false** from the moment the package
moves, including for the source-build path in `scripts/install.sh`. Fix it in stage 5.

## Bundle layout

```
Micpeg.app/Contents/
  Info.plist
  MacOS/Micpeg                                 # SwiftUI app, universal
  MacOS/micpeg                                 # daemon + CLI, universal
  Library/LaunchAgents/com.micpeg.agent.plist  # where SMAppService looks
  Resources/AppIcon.icns
```

**This layout does not survive a case-insensitive filesystem, which is the macOS default.**
`MacOS/Micpeg` and `MacOS/micpeg` resolve to a single file on APFS as shipped — measured, see
[`verification.md`](verification.md) — so the second copy silently overwrites the first. The
names have to change before stage 2 assembles anything.

`Info.plist` keys that matter:

| Key | Value | Why |
|---|---|---|
| `CFBundleIdentifier` | `com.micpeg.app` | |
| `LSMinimumSystemVersion` | `14.0` | See *Deployment target* above |
| `NSMicrophoneUsageDescription` | one sentence naming the input test | Shown in the TCC prompt. Absent ⇒ the app is killed on first capture |
| `LSUIElement` | **absent** | A Dock icon is wanted |

The agent plist uses `BundleProgram` — a bundle-relative path — not an absolute `Program`. An
absolute path breaks when the app is moved or replaced by an update, which is exactly the
failure the old hand-written plist in `~/Library/LaunchAgents` had. Everything else carries
over unchanged from `cmdInstall()`: `RunAtLoad`, `KeepAlive`, `ThrottleInterval 60`,
`ProcessType Background`, `StandardErrorPath` pointing at `~/Library/Logs/micpeg.log`.

### The label stays `com.micpeg.agent`

Reusing the legacy label looks like it invites a collision with installations that still have
`~/Library/LaunchAgents/com.micpeg.agent.plist`. It does, and that is the point.

A *new* label would let the legacy agent and the bundled agent run **at the same time**. Two
daemons enforcing the same pin would each see the other's write as a change to judge, and three
reverts inside five seconds is precisely the `BACKOFF` trigger. With one shared label, launchd
refuses the second bootstrap and the conflict is loud instead of silent.

## Registration

`SMAppService.agent(plistName:)` replaces the hand-written plist and `launchctl bootstrap`. It
requires a valid code signature, which the project has, and in exchange it handles the parts
the manual path got wrong: the registration follows the bundle when it moves, and it is torn
down when the app is deleted rather than leaving an orphaned agent behind.

Two states need real handling, not just a success path:

- **`.requiresApproval`** — the user disabled the item in Login Items. `register()` can return
  without an error while the agent does not run. The app must detect this and deep-link to
  System Settings rather than claiming success.
- **`.notRegistered` after a successful install** — treat as a failure to surface, not to retry
  silently.

### Migration, on first launch of the app

```
legacy ~/Library/LaunchAgents/com.micpeg.agent.plist present?
  yes → launchctl bootout gui/$UID/com.micpeg.agent
        remove the plist
        if ~/.local/bin/micpeg is a regular file → replace with a symlink into the
          bundle, after asking
  no  → continue
SMAppService.agent(plistName:).register()
```

`~/.config/micpeg/config.json` is **not touched**. An existing user keeps their pinned target
across the upgrade, which is the entire point of leaving the config where the daemon already
looks for it. Moving it to `~/Library/Application Support` would buy nothing and cost a
migration.

## The GUI ↔ CLI contract

Reads and writes take different routes, and the asymmetry is deliberate.

| | Route |
|---|---|
| Device list, current input, current output | The app reads CoreAudio directly, via `MicpegAudio` |
| Live changes | The app registers its own listeners while the window is visible |
| Daemon state | `~/.config/micpeg/state.json`, watched |
| Recent activity | `~/Library/Logs/micpeg.log`, tail-parsed |
| **Every mutation** | `Process` → `Contents/MacOS/micpeg` |

The app cannot write to CoreAudio because the invariant forbids it and CI enforces it. That
constraint is what makes the routing table above a structural fact rather than a convention.

Three CLI changes are needed, and no more:

1. **`micpeg pick <uid>`** — pin a named device. The existing no-argument form (pin whatever is
   currently default) stays.
2. **Bundle guard in `cmdInstall()` and `cmdUninstall()`** — if the running executable is
   inside a `.app`, refuse and point at the app. Without this, a user with the CLI symlink on
   their PATH can run `micpeg install`, which writes the legacy plist and resurrects the
   conflict that migration just removed. The guard is what keeps "one registration path" true.
3. **A way to install the CLI symlink** — invoked by the app, optional for the user.

No JSON protocol is needed. An earlier draft of this design had one; reading CoreAudio directly
made it redundant and removed a serialization layer that would have had to stay in sync.

## Build and signing

`swift build -c release --arch arm64 --arch x86_64` produces both executables. A script
assembles the bundle tree, copies `Info.plist` and the agent plist, and signs.

**Sign inside-out. Do not use `--deep`** — it is deprecated and mis-signs nested code.

```
codesign  Contents/MacOS/micpeg      --options runtime --timestamp
codesign  Micpeg.app                 --options runtime --timestamp --entitlements …
```

The hardened runtime requires an explicit entitlement for microphone access even outside the
sandbox: **`com.apple.security.device.audio-input`**. Without it the TCC prompt never appears
and capture silently yields nothing — the same shape of failure as a dead HAL listener, and
worth an automated check (`codesign -d --entitlements -`) for the same reason.

The app is not sandboxable: it writes outside its container and spawns a helper. Developer ID
distribution only; the Mac App Store was never an option.

Distribution is one artifact: a notarized, stapled DMG on GitHub Releases, with a Homebrew Cask
pointing at it. `scripts/install.sh` remains the source-build path for developers.

## Traps to expect

These are predictions, not measurements. They are recorded here because each one produces a
*silent* failure, which is the category this project has already been burned by.

**`state.json` is written atomically, so watching the file descriptor breaks after one write.**
`writeState()` uses `.atomic`, which replaces the inode. A `DispatchSource` attached to the old
file object stops firing and the UI freezes on stale data while looking healthy. Watch the
parent directory, or re-arm on `.delete`/`.rename`.

**`AVAudioEngine`'s input node binds to the device present when the engine starts.** If the
default input changes during a test, the meter goes quiet and the user concludes the microphone
is broken. Observe the configuration-change notification and restart.

**A revert moves the device twice, about 400 ms apart.** Measured flip-back intervals were 406,
436 and 463 ms (`design.md`). Restarting the engine on each transition makes the meter stutter.
Debounce more generously than the daemon's 300 ms.

**The engine must be stopped on every exit path** — test stopped, window closed, app
deactivated. An orange microphone indicator that stays lit destroys trust faster than any
missing feature.

**The daemon's log format becomes an implicit API** the moment the app parses it. Pin the
format of the lines that are parsed, and make parse failure produce an empty list rather than
an error state — a copy edit in a log message must never break the app.

**Listeners must be removed when the window goes away.** The daemon's `dispatchMain()` trap does
not apply to the app (AppKit runs the main run loop), but leaked listeners on a closed window
still cost.

## Alternatives rejected

| Alternative | Why not |
|---|---|
| **Menu bar app** | A second resident process against a daemon tuned to 0 idle wakeups, and its icon implies that quitting stops the feature. Settings are touched twice a year; that does not earn permanent menu bar space |
| **Ship the CLI separately too** (brew formula alongside the Cask) | Two registration paths for one label. Every combination needs mutual detection, and the support surface doubles for an audience that mostly wants an app |
| **A new launchd label for the bundled agent** | Lets both agents run at once and fight, landing in `BACKOFF`. See above |
| **Xcode project** | The repo has no `.xcodeproj` and does not need one for a single-window app. Xcode can open `Package.swift` directly when previews are wanted, so the tooling is available without the project file |
| **Electron / Tauri** | A 100 MB runtime on a program whose design constraint is "no meaningful memory, CPU, or power cost" |
| **Sharing a full core module between daemon and app** | Forces the deferred `main.swift` split as a prerequisite and couples the app to the judgement path. Only the read-only helpers move |
| **A JSON protocol over the CLI** | Redundant once the app reads CoreAudio directly; a serialization layer with nothing left to serialize |
| **Exposing the tuning values in the GUI** (`arrivalWindowSeconds`, `debounceMs`, `reverifyDelaySeconds`, `postWriteGraceSeconds`, `blockTransports`) | Every one was derived from hardware measurement. A settings panel advertises that they are safe to change. They stay in `config.json` for people who read `design.md` |

## Unverified assumptions

This project's rule is that documentation is not evidence. Everything below is drawn from
Apple's documentation or from reasoning, and **none of it has been observed on real hardware.**
Confirm each before building on it, and record results in [`verification.md`](verification.md).

| Assumption | How to check |
|---|---|
| `BundleProgram` resolves correctly for an `SMAppService`-registered agent | `launchctl print gui/$UID/com.micpeg.agent` and read the resolved program path |
| Registration survives moving the app and replacing it with an update | Move to a different directory, reboot, re-check |
| `.requiresApproval` is reachable and recoverable | Disable in Login Items, relaunch, observe the status the app reads |
| Deleting the app tears the agent down | Trash the app, then `launchctl print` |
| `com.apple.security.device.audio-input` is required under hardened runtime | Build a notarized copy without it and see whether the prompt appears |
| `AVAudioEngine` recovers from a device change mid-test | Start a test, connect a headset, watch the meter |
| Pinning input keeps AirPods in A2DP (the README claim) | Play audio, connect, compare before/after |
| SwiftUI previews work against a SwiftPM library target in the current Xcode | Open `Package.swift`, add a preview, run it |

## Build order

Stage 2 comes before any UI work on purpose. `SMAppService` plus `BundleProgram` is the part
that is documented but unobserved, and discovering it does not work after the interface is
finished would invert the whole schedule.

1. **`MicpegAudio` extraction + the three CLI changes.** No app yet. Verifiable on its own.
2. **Bundle assembly, signing, and a minimal app that only registers and unregisters the
   agent.** Confirm on real hardware before continuing.
3. **Migration from the legacy install.**
4. **The interface** — states, device sheet, level meter.
5. **Release pipeline** — notarized DMG, Homebrew Cask, README revision.
