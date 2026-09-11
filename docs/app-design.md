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
bundle/                # Info.plist, the agent plist, the entitlements and ko.lproj, for bundle.sh
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
  MacOS/MicpegApp                              # SwiftUI app, universal
  MacOS/micpeg                                 # daemon + CLI, universal
  Library/LaunchAgents/com.micpeg.agent.plist  # where SMAppService looks
  Resources/AppIcon.icns
  Resources/LICENSE                            # shown in Settings; MIT asks for it in every copy
  Resources/ko.lproj/Localizable.strings       # the Korean; the English is its keys
  Resources/ko.lproj/InfoPlist.strings         # the microphone prompt, in Korean
```

The resources are found through `Bundle.main`, not SwiftPM's `Bundle.module`, whose generated
accessor looks for its bundle at the root of the `.app` — beside `Contents/`, where codesign
refuses it with "unsealed contents present in the bundle root" — and otherwise calls
`fatalError`.

The app executable is `MicpegApp`, not `Micpeg`, because `MacOS/Micpeg` and `MacOS/micpeg`
are a single file on a case-insensitive filesystem — the macOS default — and the second copy
silently replaces the first (measured, see [`verification.md`](verification.md)). Every
shipping app that carries a CLI beside its GUI solves this the same way, by giving the two
files names that differ by more than case: IINA ships `IINA` and `iina-cli`, Spotify ships
`Spotify` and `spotify_cli`.

Which of the two gets renamed is not arbitrary. The daemon is a background process, so its
executable name is what `ps`, Activity Monitor and `launchctl print` show a person who is
trying to work out what is running; the app is a GUI process, whose displayed name comes from
`CFBundleName`. Renaming the app side costs a string nobody sees. It also happens to match
what SwiftPM already builds, so `scripts/bundle.sh` copies both files under the names it was
given and has no rename step that could collide. The script asserts afterwards that
`Contents/MacOS` holds two distinct files.

`Info.plist` keys that matter:

| Key | Value | Why |
|---|---|---|
| `CFBundleIdentifier` | `com.micpeg.app` | |
| `LSMinimumSystemVersion` | `14.0` | See *Deployment target* above |
| `NSMicrophoneUsageDescription` | one sentence naming the input test | Shown in the TCC prompt. Absent ⇒ the app is killed on first capture |
| `LSUIElement` | **absent** | A Dock icon is wanted |
| `CFBundleDevelopmentRegion` | `en` | The language `Strings.swift` is written in |
| `CFBundleLocalizations` | `en`, `ko` | Declares English, which has no `.lproj`, and Korean — which is what lets AppKit's own menus follow the app into Korean. `bundle.sh` checks it against the `.lproj` directories |

The agent plist uses `BundleProgram` — a bundle-relative path — not an absolute `Program`. An
absolute path breaks when the app is moved or replaced by an update, which is exactly the
failure the old hand-written plist in `~/Library/LaunchAgents` had. Everything else carries
over unchanged from `cmdInstall()`: `RunAtLoad`, `KeepAlive`, `ThrottleInterval 60`,
`ProcessType Background`.

**`StandardErrorPath` cannot come with it.** launchd does not expand `~`, and a plist built
before the user exists cannot contain an absolute home path; a tilde there does not degrade to
"no redirect", it refuses the job outright with `EX_CONFIG`. With the key omitted the daemon
runs and writes its entire log to `/dev/null` — measured, see [`verification.md`](verification.md).

The daemon therefore opens the log itself. `redirectStderrToLogIfDiscarded()` points fd 2 at
`~/Library/Logs/micpeg.log` when, and only when, fd 2 is `/dev/null` — which is exactly what
launchd hands a job with no redirect, and is not what a shell, a pipe or a user's own
`2>somewhere` looks like. It is the only change stage 2 made to the daemon, and it is the
reason `tail -f ~/Library/Logs/micpeg.log` still works and the Activity window has something to
read.

### The label stays `com.micpeg.agent`

Reusing the legacy label looks like it invites a collision with installations that still have
`~/Library/LaunchAgents/com.micpeg.agent.plist`. It does, and that is the point.

A *new* label would let the legacy agent and the bundled agent run **at the same time**. Two
daemons enforcing the same pin would each see the other's write as a change to judge, and three
reverts inside five seconds is precisely the `BACKOFF` trigger. One shared label prevents that,
and that reason stands — stage 3 tried to reach the two-daemon state from both directions on a
real machine and could not. Whichever way round the legacy plist and the registration were
created, exactly one daemon ran. What varied was *which* one, and whether anything said so.

**The rest of the original argument does not.** It claimed launchd would refuse the second
registration and make the conflict loud. Measured, it does the opposite: with the legacy agent
running, `register()` returns without throwing, changes nothing, and `status` reports `.enabled`
— about the legacy agent, because Background Task Management keys its record on the label and
not on the bundle. See [`verification.md`](verification.md). Two consequences:

- **Migration is mandatory, not a nicety.** The app must find the legacy plist on disk and tear
  it down *before* registering — **from the file, not from an API**. `statusForLegacyPlist(at:)`
  looked like the tool for this and is not: `SMAppService.h` says it is for apps "unable to
  adopt the new daemon and agent packaging guidelines" that still want to notice a user
  disabling their legacy helpers, and measured, it is keyed on the label like `status` is. It
  reported `enabled` for a plist launchd was ignoring completely. Stage 3 calls it and records
  the answer as evidence; nothing depends on it.
- **A legacy plist arriving on disk can switch a registration back on by itself.** Measured:
  after `unregister()`, writing the plist with no `launchctl bootstrap` produced a running
  daemon within a second — the bundle's daemon, under the original `BTM uuid`, ignoring the
  plist's own `ProgramArguments`. The Background Task Management record survives `unregister()`
  and the label is enough to revive it. See [`verification.md`](verification.md).
- **`SMAppService.status` is not a liveness check.** The only honest confirmation that the
  agent registered here is running is `state.json` — the timestamp has to move. That is a check
  the app needs anyway.

## Registration

`SMAppService.agent(plistName:)` replaces the hand-written plist and `launchctl bootstrap`. It
requires a valid code signature, which the project has. `BundleProgram` resolves as documented
and the agent runs from inside the bundle — that much is confirmed on hardware.

The two things it was adopted *for* are not confirmed, and one of them is contradicted:

| Claimed | Measured |
|---|---|
| The registration follows the bundle when it moves | It does not. A shell `mv` leaves the registration pinned to the old path (`EX_CONFIG`, `spawn failed`); a **Finder** move deletes both Background Task Management records outright, and moving the bundle back restores nothing |
| Deleting the app tears the agent down | Partly. The records do go, but the running daemon keeps going on its inode and the launchd job is left behind unspawnable |

Neither changes the decision — the manual path was worse on both counts, and nothing here is a
reason to go back to writing a plist into `~/Library/LaunchAgents`. But it changes what the app
must do:

- **The app has to re-register itself when it notices it has moved** — and stage 3 measured
  that "what the registration resolves to" is not a question the system will answer.
  `launchctl print` gives a bundle-*relative* `program identifier`; `SMAppService` exposes no
  path; the only source that holds the absolute URL is `sfltool dumpbtm`, which demands an
  administrator password and is therefore out of the question for a shipping app.
  `proc_pidpath()` on the running daemon is close and still wrong: a shell `mv` carries the
  inode, so the process reports the *new* path while the registration is broken, and the check
  reads healthy. **So the app records its own bundle path when it registers** and compares
  against that. One-way evidence: no record proves nothing, so it can only withdraw a healthy
  verdict, never grant one.
- **Repair means `unregister()` then `register()`, verified through `launchctl`.** A bare
  `register()` over a purged record creates a new BTM entry while leaving the old launchd job
  in place, and the next spawn fails with `EX_CONFIG` — measured. `unregister()` also does
  nothing at all when `status` is `.notFound`, so its return value proves nothing either.
- Stage 5's uninstall instructions cannot be "drag it to the Trash" alone.

Two states need real handling, not just a success path:

- **`.requiresApproval`** — the user disabled the item in Login Items. Measured: the launchd job
  is removed entirely, the daemon stops, and **code cannot undo it**. `register()` throws
  `SMAppServiceErrorDomain` code 1, "Operation not permitted", and an `unregister()` first does
  not help — the status snaps straight back. The app's only correct response is to say what
  happened and offer `SMAppService.openSystemSettingsLoginItems()`. Neither the domain nor the
  code belongs on screen; code 1 is not even in `SMErrors.h`.
- **`.notRegistered` after a successful install** — treat as a failure to surface, not to retry
  silently.

### Migration, on first launch of the app

```
legacy ~/Library/LaunchAgents/com.micpeg.agent.plist present?
  yes → launchctl bootout gui/$UID/com.micpeg.agent
        remove the plist
        if ~/.local/bin/micpeg is a regular file → offer to replace it with a symlink
          into the bundle. Offer only; it is the user's file
  no  → continue
SMAppService.agent(plistName:).register()
record this bundle's path as the registration's origin
wait for proof: a pid, that pid's executable inside this bundle, and a state.json
  written since register() was called
```

None of those three is optional. `register()` returning proves nothing, `status` answers for
whichever agent holds the label, and a pid alone survives a move that has already broken the
registration.

`~/.config/micpeg/config.json` is **not touched**. An existing user keeps their pinned target
across the upgrade, which is the entire point of leaving the config where the daemon already
looks for it. Moving it to `~/Library/Application Support` would buy nothing and cost a
migration.

## The GUI ↔ CLI contract

Reads and writes take different routes, and the asymmetry is deliberate.

| | Route |
|---|---|
| Device list, current input, current output | The app reads CoreAudio directly, via `MicpegAudio` |
| Is anything configured at all | `~/.config/micpeg/config.json`, **read only** |
| Live changes | The app registers its own listeners while the window is visible |
| Daemon state | `~/.config/micpeg/state.json`, watched |
| Activity | `~/Library/Logs/micpeg.log`, parsed whole (the daemon truncates it past 256 KB) and watched by its own descriptor — it is appended in place, where `state.json` is replaced |
| **Every mutation** | `Process` → `Contents/MacOS/micpeg` |

The app cannot write to CoreAudio because the invariant forbids it and CI enforces it. That
constraint is what makes the routing table above a structural fact rather than a convention.

`config.json` is read because nothing else answers "has this person chosen a microphone yet".
`state.json` reports `(absent)` both for a target that was never set and for one that is merely
unplugged, and app-ui.md's unconfigured state is the first of those. Reading it is safe;
writing it is what would lose someone's pinned device during an upgrade, so the CI check is a
ban on the app writing **any** file rather than a ban on naming that one — it has nothing to
write, because every mutation goes through the CLI.

The app's own defaults domain, `com.micpeg.app`, holds the only values it stores, two of them,
each owned by one file: where it registered from (`RegistrationRecord.swift`, stage 3) and its
display language (`AppLanguage.swift`, as `AppleLanguages` — the key System Settings writes for a
per-app language, so the two cannot disagree). Neither is the daemon's business, and neither is a
file the app writes itself. `scripts/invariants.sh` fails if a third file names `UserDefaults`.

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

| Assumption | How to check | Status |
|---|---|---|
| `BundleProgram` resolves correctly for an `SMAppService`-registered agent | `launchctl print gui/$UID/com.micpeg.agent` and read the resolved program path | **confirmed** (stage 2) |
| Replacing the app in place keeps the registration working | `ditto` a new build over it, restart the agent | **confirmed** (stage 2) |
| Registration survives moving the app | Move to a different directory, restart the agent | **not reliably** (stages 2, 3) — one direction survived, the other died with `EX_CONFIG`, and launchd never repairs it |
| The app can detect that it has moved | Move the bundle, run the survey from the new path | **only from its own record** (stage 3) — `proc_pidpath` reads healthy through a shell `mv` |
| `statusForLegacyPlist(at:)` answers about the legacy plist | Bootstrap it, then write one launchd ignores, and compare | **false** (stage 3) — it answers about the label, like `status` |
| A legacy plist on disk is inert until it is bootstrapped | Write it, bootstrap nothing, watch | **false** (stage 3) — it revives the SMAppService record within a second |
| Deleting the app tears the agent down | Trash the app, then `launchctl print` | **false** (stage 2). Whether emptying the Trash or a login clears it is open |
| A legacy agent under the same label makes the conflict loud | Bootstrap the old plist, then `register()` | **false** (stage 2) — it is silent, and `status` lies |
| `.requiresApproval` is reachable | Disable in Login Items, relaunch, observe the status the app reads | **confirmed** (stage 2) — and **not** recoverable in code |
| The bundled agent can keep a log | Read `fd 2` of the running daemon | **fixed** (stage 2) — the daemon opens the file itself |
| Anything micpeg ships needs an administrator password | Read every `authd` authorization in a session | **never** (stage 2) — agent registration is per-user |
| `com.apple.security.device.audio-input` is required under hardened runtime | Build a notarized copy without it and see whether the prompt appears | open — the entitlement is attached and verified, its *necessity* is not |
| `AVAudioEngine` recovers from a device change mid-test | Start a test, connect a headset, watch the meter | **confirmed** (stage 4) — the engine stops itself and the app restarts it |
| The microphone permission prompt appears when the test starts | Press Start Test on a machine that has never granted it | **confirmed** (stage 4) — TCC created the record on the first press |
| Pinning input keeps AirPods in A2DP (the README claim) | Play audio, connect, compare before/after | open |
| SwiftUI previews work against a SwiftPM library target in the current Xcode | Open `Package.swift`, add a preview, run it | **partly** (stage 4) — the macro produces the `PreviewRegistry` types Xcode discovers; the canvas cannot be driven from a shell |
| The app can tell a silent microphone from a quiet room | Measure RMS on both | **only with a measured threshold** (stage 4) — 0.01 called a working microphone silent |
| Every device with an input scope is a microphone | List devices while an input test is running | **false** (stage 4) — the HAL publishes a transient aggregate device |
| A `Window` main scene offers no New Window command | Read the menu bar through the accessibility API | **confirmed** (§24) — SwiftUI builds no File menu at all |
| Closing a `Window` main scene quits the app, as Apple's documentation says | Close the main window with Settings open | **open** — not exercised (§24) |
| AppKit's own menus follow the app's language | Choose 한국어, reopen, read the menu bar | **confirmed** (§24) |
| System Settings' per-app language writes the key the Settings window writes | Choose a language for Micpeg in System Settings, then `defaults read com.micpeg.app AppleLanguages` | **open** — the key written here works; what System Settings writes was not observed (§24) |

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
