# The `micpeg` command line

English only, like the rest of `docs/` and `CONTRIBUTING.md`. The two READMEs are the one
translated pair; this is a developer document and is not mirrored in Korean.

`micpeg` is the program the background agent runs, and the tool `Micpeg.app` shells out to for
every write it makes. It is not a separate product: it ships inside the app bundle at
`Micpeg.app/Contents/MacOS/micpeg`, and nothing in the app's interface mentions it. Everything
below is for people working on Micpeg or running it without the app.

Why the app drives the CLI rather than talking to CoreAudio itself is in
[`docs/app-design.md`](app-design.md), "The GUI ↔ CLI contract"; `scripts/invariants.sh` enforces
it, and the single `AudioObjectSetPropertyData` call in the whole project lives here.

## The one thing to know first

**`micpeg install` and `micpeg uninstall` refuse whenever `Micpeg.app` manages the agent**, in
both directions: the copy inside the bundle refuses outright, and a copy outside one refuses while
the label is held by an app's registration. `scripts/install.sh` refuses for the same reason.

One launchd label cannot have two registration paths. Measured (`docs/verification.md` §1, §26,
§28): with a legacy agent holding `com.micpeg.agent`, `SMAppService.register()` returns without
throwing and records nothing, `SMAppService.status` reports `.enabled` *about the legacy agent*,
and `launchctl bootstrap` of the legacy plist while the app holds the label fails with
`Bootstrap failed: 5: Input/output error`. The guards are what keep that from happening quietly.

So: if the app is installed, change things in the app. `pick`, `on`, `off`, `status` and `list`
work either way — only the two that create or destroy a registration are guarded.

## Running it from the bundle

```sh
/Applications/Micpeg.app/Contents/MacOS/micpeg status
```

Or put it on your `PATH` as a symlink into the bundle, so an app update is picked up rather than
serving a stale copy:

```sh
/Applications/Micpeg.app/Contents/MacOS/MicpegApp link
```

This is offered here and in the `MicpegApp link` transcript, and deliberately nowhere in the app's
interface — see the comment in `Sources/MicpegApp/Migration.swift`.

## Installing the agent from source, without the app

For developers. It builds only the `micpeg` product, so a settings app that does not compile
against the macOS 14 SDK cannot hold the agent hostage.

```sh
git clone https://github.com/OakGimbap/micpeg.git
cd micpeg
./scripts/install.sh
```

That builds the binary, copies it to `~/.local/bin/micpeg`, writes
`~/Library/LaunchAgents/com.micpeg.agent.plist`, seeds the config from your **current** default
input, and starts the agent. No `sudo` — everything stays under your home directory. For a
universal binary: `MICPEG_UNIVERSAL=1 ./scripts/install.sh`.

The install prefix is fixed at `~/.local/bin`.

To update: `git pull && ./scripts/install.sh`. The script stages the freshly built binary itself
and re-bootstraps the agent, because `micpeg install` only copies when the destination is missing
and a direct `cp` onto a running executable fails with `ETXTBSY`.

To remove: `micpeg uninstall`, then
`rm -rf ~/.config/micpeg ~/Library/Logs/micpeg.log ~/.local/bin/micpeg`.

Checking it:

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

## Commands

| Command | What it does |
|---|---|
| `micpeg status` | Current state, pinned target, live default input, daemon liveness |
| `micpeg list` | Every input device with its transport type and UID |
| `micpeg pick [uid]` | Make the current default input the pinned target, replacing the previous one. Given a `uid`, pin that device instead — it must be connected and publish an input scope |
| `micpeg on` / `off` | Resume / pause pinning (also clears a yield) |
| `micpeg link` | Symlink `~/.local/bin/micpeg` to the running binary. `--force` replaces a real file already sitting there — that file is the standalone CLI install |
| `micpeg install` | Write config + LaunchAgent and bootstrap the agent. Refused when the app manages it |
| `micpeg uninstall` | Bootout the agent and remove its LaunchAgent and its state file. Refused when the app manages it |
| `micpeg daemon` | Run in the foreground (used by launchd) |
| `micpeg version` | The version, from the bundle's `Info.plist`. A source build has none and says so |

**Do not paste `micpeg list` into a bug report.** A UID embeds a USB serial number or a Bluetooth
MAC address, and an issue is public. `micpeg status` is the one to paste.

## The app's own subcommands

`Micpeg.app/Contents/MacOS/MicpegApp` takes a verb too. These are the app, not the daemon, and
they are how registration is inspected without a window.

| Command | What it does |
|---|---|
| `MicpegApp survey` | Reads the plist on disk, the launchd job, the pid's real executable via `proc_pidpath`, the app's own record of where it registered, and `state.json`, and says which of those disagree. Changes nothing |
| `MicpegApp status` | What `SMAppService` thinks. Narrower, and has been caught lying |
| `MicpegApp migrate` | Tear down a command-line install, then register |
| `MicpegApp repair` | Unregister and register again, confirmed |
| `MicpegApp link` | Put `micpeg` on `PATH` as a link into the bundle |
| `MicpegApp meter` | RMS from the default input, for calibrating the level meter |
| `MicpegApp activity` | The Activity window's rows, as text |

**`survey` is the one to reach for.** `SMAppService.status` is keyed on the label, so it answers
for whichever agent holds it, including a hand-written one; a `launchctl print` has shown a job
`running` after ServiceManagement had dropped every record of it. The check that means something
is `state.json`'s `updated` timestamp moving.

## Configuration

`~/.config/micpeg/config.json` — see [`config.example.json`](../config.example.json). Reload
without restarting with `launchctl kill SIGHUP gui/$(id -u)/com.micpeg.agent`, or just run
`micpeg on`.

| Key | Default | Meaning |
|---|---|---|
| `enabled` | `true` | Master switch. `micpeg off` sets this |
| `input.priority` | *(from install)* | Ordered list of `{uid, name}`. The first one present wins. UID is matched first; `name` is a fallback. `micpeg pick` writes a list of one; a longer list is for editing by hand |
| `blockTransports` | `["bluetooth", "bluetoothle"]` | Transports micpeg will reverse. Everything else is treated as a deliberate choice |
| `arrivalWindowSeconds` | `15` | A blocked device that appeared this recently is an automatic switch, not your decision |
| `debounceMs` | `300` | Coalesces notification bursts |
| `reverifyDelaySeconds` | `1.0` | Re-checks once after writing, in case the write was swallowed |
| `postWriteGraceSeconds` | `3.0` | If the default moves this soon after micpeg wrote it, it is macOS flipping back — not a human |

A device UID survives reboots and USB port changes (a USB mic's UID embeds its serial number),
which is why micpeg targets UIDs rather than names or device IDs.

**Do not add `virtual` or `unknown` to `blockTransports`.** Elgato's own guidance tells you to
select a Wave Link *virtual* device as your default input when using MicrophoneFX, and Continuity
iPhone Mic reports as `ccwd`. Blocking those fights the user.

**The last five values came from hardware measurement** and must not change without another one.
They are deliberately absent from the app's interface — see [`docs/app-ui.md`](app-ui.md),
"Never in this window".
