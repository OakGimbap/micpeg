# micpeg

**Keep your USB microphone as the macOS default input, even when AirPods connect.**

[한국어 README](README.ko.md)

---

## The problem

When you connect a Bluetooth headset, macOS moves **both** the default output and the
default **input** to it. That is usually right for output and almost always wrong for input:
you connected AirPods to listen to something, not to downgrade your microphone.

It matters most for apps that use the OS default input and give you no device picker.
Claude Code's voice mode is one of them — it resolves the device at the moment you press
push-to-talk, so a mic that silently moved to your earbuds produces a worse recording with
no visible sign that anything changed.

There is no first-party setting to turn this off. `com.apple.coreaudio` and
`com.apple.audio.AudioMIDISetup` have no preference domain at all, and a full sweep of
`defaults domains` turns up no suppression key.

## What micpeg does

A ~4 MB launchd agent that watches the CoreAudio default-input property and puts it back
when macOS hands it to a Bluetooth device.

- **Input only.** The background agent's source never contains `DefaultOutputDevice` or
  `DefaultSystemOutputDevice`, and CI checks that. The settings app reads the default output
  only to display it, and writes nothing to CoreAudio at all. Your AirPods still take over
  audio output, as they should.
- **Respects your choices.** Pick a different microphone yourself and micpeg yields. It only
  reverses transitions it can attribute to the system.
- **Effectively free.** 3 idle wakeups, ~4 MB `phys_footprint` and 0.59 s of CPU across 24
  hours of real use. It parks on `CFRunLoopRun()` with no polling and no repeating timers — it
  does nothing at all until CoreAudio sends a notification. See
  [docs/verification.md](docs/verification.md).
- **The agent never opens the microphone.** It sets a routing preference; it does not capture.
  No orange recording indicator, no TCC prompt, no interference with whatever app currently
  holds the mic. The settings app opens it only while you run its input test, and asks for
  permission the first time.

## Two pieces

- **`micpeg`** — the launchd agent and its command-line interface. This is the program, and it
  is finished. Everything below installs and drives this.
- **`Micpeg.app`** — a small SwiftUI settings app: pick a microphone, confirm the agent is
  working, run an input test. It is built and exercised, but **not distributed yet.** There is
  no signed download; `./scripts/bundle.sh` assembles it and signs it with whatever development
  certificate you already have, which is enough to run it yourself and not enough to hand to
  anyone else. A Developer ID build is the next piece of work.

## Requirements

- macOS 14 (Sonoma) or later
- Swift 5.9+ toolchain (Xcode or the Swift command-line tools)

The agent needs neither: it links CoreAudio and Foundation and would run on far older releases.
The floor comes from the settings app — `@Observable` is macOS 14 — and SwiftPM applies
`platforms:` package-wide, so the agent inherits it.

> **Honest scope note:** micpeg builds for macOS 14+, but it has only been exercised on real
> hardware on macOS 26 (26.6). In particular, whether `kAudioHardwarePropertyServiceRestarted`
> (the HAL-restart recovery hook) actually fires on macOS 14 and 15 is unverified. If it does
> not, the listener simply never gets called — degraded, not harmful.

## Install

Connect the microphone you want to pin and select it as your default input, then:

```sh
git clone https://github.com/OakGimbap/micpeg.git
cd micpeg
./scripts/install.sh
```

That builds the binary, copies it to `~/.local/bin/micpeg`, writes
`~/Library/LaunchAgents/com.micpeg.agent.plist`, seeds the config from your **current**
default input, and starts the agent. No `sudo` — everything stays under your home directory.

This installs the agent, not the app. The script refuses to run if `Micpeg.app` is already
managing the agent: one launchd label cannot have two registration paths.

For a universal (Apple Silicon + Intel) binary: `MICPEG_UNIVERSAL=1 ./scripts/install.sh`

Make sure `~/.local/bin` is on your `PATH`, then check it:

```sh
micpeg status
```

```
enabled:       true
default input: Elgato Wave:1 [usb ]
target[0]:     Elgato Wave:1  — present
state:         PINNED  (default input is the target)
updated:       2026-09-10 16:12:05.732
daemon:        pid = 20138
```

### Updating

```sh
git pull
./scripts/install.sh
```

The script stages the freshly built binary itself and then re-bootstraps the agent, so an
upgrade actually takes effect.

## Commands

| Command | What it does |
|---|---|
| `micpeg status` | Current state, pinned target, live default input, daemon liveness |
| `micpeg list` | Every input device with its transport type and UID |
| `micpeg pick` | Make the current default input the pinned target, replacing the previous one |
| `micpeg on` / `off` | Resume / pause pinning (also clears a yield) |
| `micpeg install` | Write config + LaunchAgent and bootstrap the agent |
| `micpeg uninstall` | Bootout the agent and remove its LaunchAgent |
| `micpeg daemon` | Run in the foreground (used by launchd) |

To change which mic is pinned: select it in System Settings, then run `micpeg pick`.

## Configuration

`~/.config/micpeg/config.json` — see [`config.example.json`](config.example.json).
Send `launchctl kill SIGHUP gui/$(id -u)/com.micpeg.agent` to reload without restarting,
or just run `micpeg on`.

| Key | Default | Meaning |
|---|---|---|
| `enabled` | `true` | Master switch. `micpeg off` sets this. |
| `input.priority` | *(from install)* | Ordered list of `{uid, name}`. The first one present wins. UID is matched first; `name` is a fallback. `micpeg pick` writes a list of one; a longer list is for editing by hand. |
| `blockTransports` | `["bluetooth", "bluetoothle"]` | Transports micpeg will reverse. Everything else is treated as a deliberate choice. |
| `arrivalWindowSeconds` | `15` | A blocked device that appeared this recently is an automatic switch, not your decision. |
| `debounceMs` | `300` | Coalesces notification bursts. |
| `reverifyDelaySeconds` | `1.0` | Re-checks once after writing, in case the write was swallowed. |
| `postWriteGraceSeconds` | `3.0` | If the default moves this soon after micpeg wrote it, it is macOS flipping back — not a human. |

A device UID survives reboots and USB port changes (a USB mic's UID embeds its serial
number), which is why micpeg targets UIDs rather than names or device IDs.

**Do not add `virtual` or `unknown` to `blockTransports`.** Elgato's own guidance tells you
to select a Wave Link *virtual* device as your default input when using MicrophoneFX, and
Continuity iPhone Mic reports as `ccwd`. Blocking those fights the user.

## How it works

Three `AudioObjectAddPropertyListenerBlock` listeners on the system object — device list
(`dev#`), default input (`dIn `), and HAL restart (`srst`) — feeding a five-state machine
(`ABSENT` / `PINNED` / `YIELDED` / `PAUSED` / `BACKOFF`).

Whether a change was automatic or deliberate is decided primarily by **transport type**, not
by timing: Bluetooth is the only path by which macOS takes the default input on its own.
Timing is a secondary signal, and the strongest evidence of all is micpeg's own write clock —
if the default moves 400 ms after micpeg set it, no human did that.

Full rationale, including three design defects found and fixed before shipping:
**[docs/design.md](docs/design.md)**. The original development log (Korean) is at
[docs/ko/engineering-log.md](docs/ko/engineering-log.md).

## What micpeg deliberately does not do

- Touch the default output or system output — not even as an option. It is not in the config
  schema, so it cannot be switched on by mistake.
- Force a fallback when your target mic is unplugged. With no target present micpeg goes
  `ABSENT` and does nothing; macOS behaves normally.
- Run a polling loop. A `StartInterval 5` agent would wake up 17,280 times a day.

## Known limitations

- **A deliberate Bluetooth mic choice made within ~15 s of connecting it gets reverted once.**
  There is no signal anywhere in CoreAudio that says who initiated a change
  (`log stream --predicate 'subsystem == "com.apple.coreaudio"'` produces zero lines for these
  transitions), so this is a heuristic. Pick it again a moment later, or run `micpeg off`.
- The same applies for ~15 s after login or a `coreaudiod` restart.
- The install prefix is fixed at `~/.local/bin`.
- **Two unexplained incidents, one of which `micpeg status` does not reveal.** On 2026-09-10
  the agent reported `PINNED` while the default input actually sat on a Bluetooth headset for
  ~1.5 h with no log output. On 2026-09-11 the same shape recurred for 42 minutes and ended with
  the daemon classifying that headset as a settled device and yielding to it. Both followed one
  of the daemon's own writes away from the headset. Sleep, `coreaudiod` restart, process
  restart, queue deadlock and a dead listener were all ruled out; a dropped notification and a
  judgement made against a stale value are the two remaining explanations, and five reproduction
  attempts failed. Three silently-give-up paths were hardened as insurance. In the first shape
  `micpeg status` shows a `state:` and a `default input:` that disagree. In the second it
  reports `YIELDED` and looks correct — protection is simply off until you disconnect the
  headset. `micpeg on` restores it instantly in both cases.

## Uninstall

```sh
micpeg uninstall
rm -rf ~/.config/micpeg ~/Library/Logs/micpeg.log ~/.local/bin/micpeg
```

## License

MIT — see [LICENSE](LICENSE).
