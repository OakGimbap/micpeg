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
- Minimum macOS 14 once the app target lands. SwiftPM's `platforms:` is package-wide, so the
  daemon inherits it; `@Observable` is the reason it is 14 and not 13. Until then the package
  still declares macOS 12, so stage 1 does not make README's version claim false on its own.
  See `docs/app-design.md`.
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
Sources/MicpegUI/          # (planned) SwiftUI views (library target, so previews work)
Sources/MicpegApp/         # (planned) @main, wiring, migration. Thin.
scripts/install.sh         # source build + install, for developers
scripts/invariants.sh      # the structural greps above; CI runs it
scripts/bundle.sh          # (planned) assemble Micpeg.app, sign, notarize
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
```

**Testing rule: an idle daemon with dead listeners is indistinguishable from a healthy one.**
Never conclude a change is safe from a quiet log. Provoke real events — connect the headset,
unplug and replug the mic, `sudo killall coreaudiod` — and read the transitions.

The same rule applies to the app, where the silent failures are: an `SMAppService` registration
that reports success but resolves nothing, a `state.json` watcher that dies on the first atomic
write, an `AVAudioEngine` that stops delivering after a device change, and a missing
`com.apple.security.device.audio-input` entitlement that suppresses the permission prompt
entirely. Test `SMAppService` from `/Applications`, not from a build directory.

`docs/app-design.md` ends with a list of assumptions that are documented but **not yet observed
on hardware**. Confirm them before building on them, and record results in
`docs/verification.md`.
