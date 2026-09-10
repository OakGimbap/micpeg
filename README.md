# micpin

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

## What micpin does

A ~4 MB launchd agent that watches the CoreAudio default-input property and puts it back
when macOS hands it to a Bluetooth device.

- **Input only.** The strings `DefaultOutputDevice` and `DefaultSystemOutputDevice` do not
  appear anywhere in the source. Your AirPods still take over audio output, as they should.
- **Respects your choices.** Pick a different microphone yourself and micpin yields. It only
  reverses transitions it can attribute to the system.
- **Effectively free.** 0 idle wakeups, ~4 MB `phys_footprint`, 0.59 s of CPU across 24 hours
  of real use. It parks on `CFRunLoopRun()` with no timers and no polling — it does nothing at
  all until CoreAudio sends a notification. See [docs/verification.md](docs/verification.md).
- **Never opens the microphone.** It sets a routing preference; it does not capture. No orange
  recording indicator, no TCC prompt, no interference with whatever app currently holds the mic.

## Requirements

- macOS 12 (Monterey) or later
- Swift 5.7+ toolchain (Xcode or the Swift command-line tools)

> **Honest scope note:** micpin builds for macOS 12+, but it has only been exercised on real
> hardware on macOS 26. In particular, whether `kAudioHardwarePropertyServiceRestarted`
> (the HAL-restart recovery hook) actually fires on older releases is unverified. If it does
> not, the listener simply never gets called — degraded, not harmful.

## Install

Connect the microphone you want to pin and select it as your default input, then:

```sh
git clone https://github.com/OakGimbap/micpin.git
cd micpin
./scripts/install.sh
```

That builds the binary, copies it to `~/.local/bin/micpin`, writes
`~/Library/LaunchAgents/com.micpin.agent.plist`, seeds the config from your **current**
default input, and starts the agent. No `sudo` — everything stays under your home directory.

For a universal (Apple Silicon + Intel) binary: `MICPIN_UNIVERSAL=1 ./scripts/install.sh`

Make sure `~/.local/bin` is on your `PATH`, then check it:

```sh
micpin status
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
| `micpin status` | Current state, pinned target, live default input, daemon liveness |
| `micpin list` | Every input device with its transport type and UID |
| `micpin pick` | Make the current default input the pinned target |
| `micpin on` / `off` | Resume / pause pinning (also clears a yield) |
| `micpin install` | Write config + LaunchAgent and bootstrap the agent |
| `micpin uninstall` | Bootout the agent and remove its LaunchAgent |
| `micpin daemon` | Run in the foreground (used by launchd) |

To change which mic is pinned: select it in System Settings, then run `micpin pick`.

## Configuration

`~/.config/micpin/config.json` — see [`config.example.json`](config.example.json).
Send `launchctl kill SIGHUP gui/$(id -u)/com.micpin.agent` to reload without restarting,
or just run `micpin on`.

| Key | Default | Meaning |
|---|---|---|
| `enabled` | `true` | Master switch. `micpin off` sets this. |
| `input.priority` | *(from install)* | Ordered list of `{uid, name}`. The first one present wins. UID is matched first; `name` is a fallback. |
| `blockTransports` | `["bluetooth", "bluetoothle"]` | Transports micpin will reverse. Everything else is treated as a deliberate choice. |
| `arrivalWindowSeconds` | `15` | A blocked device that appeared this recently is an automatic switch, not your decision. |
| `debounceMs` | `300` | Coalesces notification bursts. |
| `reverifyDelaySeconds` | `1.0` | Re-checks once after writing, in case the write was swallowed. |
| `postWriteGraceSeconds` | `3.0` | If the default moves this soon after micpin wrote it, it is macOS flipping back — not a human. |

A device UID survives reboots and USB port changes (a USB mic's UID embeds its serial
number), which is why micpin targets UIDs rather than names or device IDs.

**Do not add `virtual` or `unknown` to `blockTransports`.** Elgato's own guidance tells you
to select a Wave Link *virtual* device as your default input when using MicrophoneFX, and
Continuity iPhone Mic reports as `ccwd`. Blocking those fights the user.

## How it works

Three `AudioObjectAddPropertyListenerBlock` listeners on the system object — device list
(`dev#`), default input (`dIn `), and HAL restart (`srst`) — feeding a five-state machine
(`ABSENT` / `PINNED` / `YIELDED` / `PAUSED` / `BACKOFF`).

Whether a change was automatic or deliberate is decided primarily by **transport type**, not
by timing: Bluetooth is the only path by which macOS takes the default input on its own.
Timing is a secondary signal, and the strongest evidence of all is micpin's own write clock —
if the default moves 400 ms after micpin set it, no human did that.

Full rationale, including three design defects found and fixed before shipping:
**[docs/design.md](docs/design.md)**. The original development log (Korean) is at
[docs/ko/engineering-log.md](docs/ko/engineering-log.md).

## What micpin deliberately does not do

- Touch the default output or system output — not even as an option. It is not in the config
  schema, so it cannot be switched on by mistake.
- Force a fallback when your target mic is unplugged. With no target present micpin goes
  `ABSENT` and does nothing; macOS behaves normally.
- Run a polling loop. A `StartInterval 5` agent would wake up 17,280 times a day.

## Known limitations

- **A deliberate Bluetooth mic choice made within ~15 s of connecting it gets reverted once.**
  There is no signal anywhere in CoreAudio that says who initiated a change
  (`log stream --predicate 'subsystem == "com.apple.coreaudio"'` produces zero lines for these
  transitions), so this is a heuristic. Pick it again a moment later, or run `micpin off`.
- The same applies for ~15 s after login or a `coreaudiod` restart.
- The install prefix is fixed at `~/.local/bin`.
- One unexplained incident: on 2026-09-10 the agent reported `PINNED` while the default input
  actually sat on a Bluetooth headset for ~1.5 h with no log output. Sleep, `coreaudiod`
  restart, process restart, queue deadlock and a dead listener were all ruled out; a dropped
  notification is the remaining hypothesis. Three silently-give-up paths were hardened as
  insurance. `micpin status` detects it and `micpin on` fixes it instantly.

## Uninstall

```sh
micpin uninstall
rm -rf ~/.config/micpin ~/Library/Logs/micpin.log ~/.local/bin/micpin
```

## License

MIT — see [LICENSE](LICENSE).
