# CLAUDE.md

## Project

`micpin` — a macOS launchd agent that keeps a chosen microphone as the system default audio
**input**, reverting the automatic switch macOS performs when a Bluetooth headset connects.

Read [`docs/design.md`](docs/design.md) before changing anything in the judgement path. It
records three CoreAudio traps that each cost a full round of real-hardware testing to find.

## Tech stack

- Swift 5.7+, SwiftPM (`swift build -c release`). No Xcode project, no dependencies.
- Links CoreAudio + Foundation only. **AppKit must never be added.**
- Deployment target: macOS 12. Verified on real hardware only on macOS 26.

## Architecture principles

1. **Input only.** `kAudioHardwarePropertyDefaultInputDevice` is the sole write target.
   `DefaultOutputDevice` and `DefaultSystemOutputDevice` must not appear in the source, and
   output keys must not appear in the config schema — absence is the enforcement mechanism.
2. **Zero idle cost.** Park on `CFRunLoopRun()`. Never `dispatchMain()` (it `pthread_exit()`s
   the main thread and silently kills every HAL listener). No timers, no polling, no
   `StartInterval`. Any new timer must be one-shot and self-cancelling.
3. **Never cache `AudioDeviceID`.** Resolve UID → ID through `'uidd'` every time. IDs are
   reused across reconnects.
4. **Only `'dIn '` may decide the user made a choice.** `'dev#'` records arrivals and re-applies
   the pin; it never yields.
5. **Tag self-writes explicitly** with an expiring expectation, and swallow exactly one
   callback. Never a boolean settling window.

## Code style

- English identifiers and English comments.
- Comments explain *why*, and cite evidence — a header line number, a measured interval, the
  test that failed. The existing comments are the model: they name the incident that produced
  the code.
- Prefer bounded retries over unbounded polling; an unbounded retry breaks principle 2.

## Key constraints

- The judgement logic in `evaluate()` has been validated across many rounds of real-hardware
  testing. Do not refactor it for tidiness — the daemon runs a handful of times per day with
  0 idle wakeups, so there is no performance argument, and the risk is real.
- The single 1,228-line `main.swift` is deliberate for now. Splitting it is a separate,
  test-backed task.
- Device identifiers (USB serials, Bluetooth MACs, display UIDs) must never be committed.
  `leakcheck-result*.txt` is gitignored for this reason.

## File structure

```
Sources/micpin/main.swift    # entire program: daemon + CLI
scripts/install.sh           # build + micpin install
scripts/leakcheck.sh         # 24h soak test (writes a gitignored result file)
docs/design.md               # architecture + the three CoreAudio traps
docs/verification.md         # measured numbers, test matrix, open issue
docs/ko/engineering-log.md   # original Korean development log
```

Runtime files, all outside the repo:
`~/.local/bin/micpin`, `~/.config/micpin/{config,state}.json`,
`~/Library/LaunchAgents/com.micpin.agent.plist`, `~/Library/Logs/micpin.log`

## Development workflow

```sh
swift build -c release                          # host arch
swift build -c release --arch arm64 --arch x86_64   # universal
./scripts/install.sh                            # build + install + bootstrap

micpin status
tail -f ~/Library/Logs/micpin.log
launchctl kill SIGHUP gui/$(id -u)/com.micpin.agent   # reload config
```

**Testing rule: an idle daemon with dead listeners is indistinguishable from a healthy one.**
Never conclude a change is safe from a quiet log. Provoke real events — connect the headset,
unplug and replug the mic, `sudo killall coreaudiod` — and read the transitions.
