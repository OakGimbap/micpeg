# CLAUDE.md

## Project

`micpeg` — keeps a chosen microphone as the macOS default audio **input**, reverting the
automatic switch macOS performs when a Bluetooth headset connects.

Two faces, two processes:

- **`micpeg`** — a launchd agent (and the CLI). This is the program. It is finished.
- **`Micpeg.app`** — a SwiftUI settings app used to pick a microphone and confirm the agent is
  working. Opened perhaps three times in its life. Under construction.

Read [`docs/design.md`](docs/design.md) before changing anything in the judgement path. It
records three CoreAudio traps that each cost a full round of real-hardware testing to find.
Read [`docs/app-design.md`](docs/app-design.md) and [`docs/app-ui.md`](docs/app-ui.md) before
touching the app.

## Tech stack

- Swift, SwiftPM. **No Xcode project** — Xcode may open `Package.swift` when SwiftUI previews
  are wanted, but no `.xcodeproj` enters the repo.
- The daemon links CoreAudio + Foundation only. No third-party dependencies anywhere.
- Distribution is a single notarized `Micpeg.app` containing both executables.
- Minimum macOS 14, in effect since the app target landed. SwiftPM's `platforms:` is
  package-wide, so the daemon inherits it; `@Observable` is the reason it is 14 and not 13.
  `swift-tools-version` is 5.9 because `.macOS(.v14)` does not exist before it. **This makes
  README's "macOS 12 (Monterey) or later" false**, including for the source build in
  `scripts/install.sh` — the README fix is stage 5. See `docs/app-design.md`.
- Verified on real hardware only on macOS 26.

## Architecture principles

1. **Input only.** `kAudioHardwarePropertyDefaultInputDevice` is the sole write target in the
   whole project.
2. **Zero idle cost.** The daemon parks on `CFRunLoopRun()`. Never `dispatchMain()` (it
   `pthread_exit()`s the main thread and silently kills every HAL listener). No timers, no
   polling, no `StartInterval`. Any new timer must be one-shot and self-cancelling.
3. **Never cache `AudioDeviceID`.** Resolve UID → ID through `'uidd'` every time. IDs are
   reused across reconnects.
4. **Only `'dIn '` may decide the user made a choice.** `'dev#'` records arrivals and re-applies
   the pin; it never yields.
5. **Tag self-writes explicitly** with an expiring expectation, and swallow exactly one
   callback. Never a boolean settling window.
6. **The app writes nothing to CoreAudio.** It reads devices and registers listeners; every
   mutation goes through the `micpeg` CLI. This is what keeps principle 1 provable now that the
   app has to read the default output in order to display it.

Principles 1 and 6 are enforced structurally, not by discipline. `scripts/invariants.sh`
checks all three plus the write count, and CI runs it:

```sh
grep -rc AudioObjectSetPropertyData Sources/MicpegApp Sources/MicpegUI Sources/MicpegAudio  # 0
grep -rc DefaultOutputDevice        Sources/micpeg Sources/MicpegAudio                      # 0
grep -rc AVFoundation               Sources/micpeg Sources/MicpegAudio                      # 0
grep -rc AudioObjectSetPropertyData Sources                                                 # 1
```

The third keeps "the background agent never opens the microphone" true after the app gained a
level meter. **That README claim is now about the agent specifically** — check its wording
whenever the app's audio code changes.

The last one is the positive form of principle 1: one write in the whole project. The
script prints the directories each check actually searched, because the first draft of it
grepped a path that did not exist and reported a pass — the same shape of lie as an idle
daemon with dead listeners.

## Code style

- English identifiers, English comments, English UI strings.
- Comments explain *why*, and cite evidence — a header line number, a measured interval, the
  test that failed. The existing comments are the model: they name the incident that produced
  the code.
- Prefer bounded retries over unbounded polling; an unbounded retry breaks principle 2.
- In the app, prefer the standard SwiftUI container over custom layout every time. See
  [`docs/app-ui.md`](docs/app-ui.md) — and read Apple's current documentation rather than
  trusting that file's recollection of an API.

## Key constraints

- The judgement logic in `evaluate()` has been validated across many rounds of real-hardware
  testing. Do not refactor it for tidiness — the daemon runs a handful of times per day with
  0 idle wakeups, so there is no performance argument, and the risk is real.
- Splitting the 1,234-line `main.swift` is still a separate, test-backed task. Extracting the
  read-only CoreAudio helpers into `MicpegAudio` is *not* that task and does not authorize it.
- The tuning values (`arrivalWindowSeconds`, `debounceMs`, `reverifyDelaySeconds`,
  `postWriteGraceSeconds`, `blockTransports`) came from hardware measurement and must not be
  surfaced in the app's UI.
- The launchd label stays `com.micpeg.agent`. A different label would let a legacy agent and a
  bundled agent run at once and fight into `BACKOFF`.
- Device identifiers (USB serials, Bluetooth MACs, display UIDs) must never be committed.
  `leakcheck-result*.txt` is gitignored for this reason.

## File structure

Targets marked `(planned)` do not exist yet — see the build order at the end of
[`docs/app-design.md`](docs/app-design.md).

```
Sources/MicpegAudio/       # read-only CoreAudio helpers, shared. No writes.
Sources/micpeg/main.swift  # daemon + CLI. Owns the only setDefaultInputDevice call.
Sources/MicpegUI/          # the windows: views, models, file/device watching, the level meter.
                           #   a library target, so #Preview registers with Xcode's canvas
Sources/MicpegApp/         # @main, survey, migration, registration record. Thin.
bundle/                    # Info.plist, agent plist, entitlements — inputs to bundle.sh
scripts/install.sh         # source build + install, for developers
scripts/invariants.sh      # the structural greps above; CI runs it
scripts/bundle.sh          # assemble Micpeg.app, sign, check. Notarization is stage 5
scripts/leakcheck.sh       # 24h soak test (writes a gitignored result file)
docs/design.md             # daemon architecture + the three CoreAudio traps
docs/app-design.md         # app architecture, bundle, SMAppService, invariants
docs/app-ui.md             # app interface spec and Apple conventions
docs/verification.md       # measured numbers, test matrix, open issues
docs/ko/engineering-log.md # original Korean development log
```

Runtime files, all outside the repo:
`~/.config/micpeg/{config,state}.json`, `~/Library/Logs/micpeg.log`,
and the agent registered from `Micpeg.app/Contents/Library/LaunchAgents/`.

## Development workflow

```sh
swift build -c release                              # host arch
swift build -c release --arch arm64 --arch x86_64   # universal
./scripts/bundle.sh                                 # assemble + sign Micpeg.app

micpeg status
tail -f ~/Library/Logs/micpeg.log
launchctl print gui/$(id -u)/com.micpeg.agent       # what launchd actually resolved
launchctl kill SIGHUP gui/$(id -u)/com.micpeg.agent # reload config
/Applications/Micpeg.app/Contents/MacOS/MicpegApp status    # what SMAppService thinks
/Applications/Micpeg.app/Contents/MacOS/MicpegApp survey    # what is actually installed
/Applications/Micpeg.app/Contents/MacOS/MicpegApp migrate   # tear down the legacy agent, register
/Applications/Micpeg.app/Contents/MacOS/MicpegApp repair    # unregister + register, confirmed
/Applications/Micpeg.app/Contents/MacOS/MicpegApp link      # put micpeg on PATH, into the bundle
/Applications/Micpeg.app/Contents/MacOS/MicpegApp meter     # RMS from the default input
/Applications/Micpeg.app/Contents/MacOS/MicpegApp activity  # the Activity window's rows, as text
```

**`survey` is the one to reach for.** `status` and `launchctl print` each answer a narrower
question and both have been caught lying: `launchctl print` has shown a job still `running`
after ServiceManagement had dropped every record of it, and `SMAppService.status` has reported
`.enabled` for an app that had never registered anything — it is keyed on the label, so it
answers for whichever agent holds it, including a hand-written one. `survey` reads the plist on
disk, the launchd job, the pid's real executable path via `proc_pidpath`, the app's own record
of where it registered from, and `state.json`, and says which of those disagree. It changes
nothing.

**Do not reach for `sfltool dumpbtm` casually** — `scripts/invariants.sh` now fails if the
name appears on a code line anywhere in `Sources/`. It requests `system.privilege.admin` and the
credential is not cached, so every single invocation raises a password dialog — 26 of them in
one session while stage 2 was being worked out. Use it only when the Background Task Management
record's own contents are the question. Nothing micpeg ships ever asks for an administrator
password; registering a LaunchAgent is a per-user operation.

**Inspect the window through the accessibility API, not by looking at it** — and not with
AppleScript, whose `title of` is empty for every SwiftUI control because SwiftUI publishes
labels as `AXDescription`. Two stage 4 defects were only visible in the tree, and one
non-defect looked like a serious accessibility bug because the wrong attribute was read.

**Testing rule: an idle daemon with dead listeners is indistinguishable from a healthy one.**
Never conclude a change is safe from a quiet log. Provoke real events — connect the headset,
unplug and replug the mic, `sudo killall coreaudiod` — and read the transitions.

The same rule applies to the app, where the silent failures are: an `SMAppService` registration
that reports success but resolves nothing, a `state.json` watcher that dies on the first atomic
write, an `AVAudioEngine` that stops delivering after a device change, and a missing
`com.apple.security.device.audio-input` entitlement that suppresses the permission prompt
entirely. Test `SMAppService` from `/Applications`, not from a build directory.

The first of those is no longer hypothetical. With a legacy agent holding the label,
`register()` returns without throwing and records **nothing**, and `status` returns `.enabled`
about the legacy agent. **Never treat `SMAppService.status` as evidence that the agent is
running.** The check that means something is `state.json`'s `updated` timestamp moving.

Stage 4 added two more, both measured. **A `DispatchSource` on `state.json`'s own file
descriptor goes deaf after one write** — the daemon writes atomically, so the descriptor stays
open on an inode that is no longer at the path. Watch the directory. And **a level meter needs
its threshold calibrated against a working microphone**: a quiet room reads RMS ~0.0017 while a
device delivering nothing reads exactly 0.00000, so a plausible-looking 0.01 tells a working
microphone it is silent. `MicpegApp meter` exists to keep that honest.

Stage 3 added another, and it is subtler because the evidence looks good. **A running
daemon whose executable is inside this bundle does not mean the registration is intact.** A
shell `mv` carries the bundle's inode, so the process that was already running reports the
*new* path while launchd still fails to spawn the next one (`EX_CONFIG`), and nothing repairs
it — measured at 70 s and counting. Only the path the app recorded for itself when it
registered catches that, which is why `RegistrationRecord` exists. Confirming a registration
takes three things together: a pid, that pid's executable inside this bundle, and a
`state.json` written *after* the call.

`docs/app-design.md` ends with a list of assumptions that are documented but **not yet observed
on hardware**. Confirm them before building on them, and record results in
`docs/verification.md`.
