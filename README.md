# Micpeg

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

## What Micpeg does

A small app that lets you pick a microphone, and a ~4 MB background helper that watches the
CoreAudio default-input property and puts it back when macOS hands it to a Bluetooth device.

- **Input only.** The background helper's source never contains `DefaultOutputDevice` or
  `DefaultSystemOutputDevice`, and CI checks that. The app reads the default output only to
  display it, and writes nothing to CoreAudio at all. Your AirPods still take over audio output,
  as they should.
- **Respects your choices.** Pick a different microphone yourself and Micpeg yields. It only
  reverses transitions it can attribute to the system.
- **Effectively free.** 3 idle wakeups, ~4 MB `phys_footprint` and 0.59 s of CPU across 24
  hours of real use. The helper parks on `CFRunLoopRun()` with no polling and no repeating timers
  — it does nothing at all until CoreAudio sends a notification. See
  [docs/verification.md](docs/verification.md).
- **The background helper never opens the microphone.** It sets a routing preference; it does not
  capture. No orange recording indicator, no permission prompt, no interference with whatever app
  currently holds the mic. The app opens it only while you run its input test, and asks for
  permission the first time.
- **It never connects to anything.** No update check, no analytics, no network code of any kind —
  CI fails the build if any appears. The only link it can open is the one to this page, in your
  browser.

## Requirements

macOS 14 (Sonoma) or later.

> **Honest scope note:** Micpeg builds for macOS 14+, but it has only been exercised on real
> hardware on macOS 26 (26.6), on Apple Silicon. In particular, whether
> `kAudioHardwarePropertyServiceRestarted` (the HAL-restart recovery hook) actually fires on
> macOS 14 and 15 is unverified. If it does not, the listener simply never gets called —
> degraded, not harmful.

## Install

1. Download `Micpeg.dmg` from [the latest release](https://github.com/OakGimbap/micpeg/releases/latest).
2. Open it and drag **Micpeg** to the **Applications** folder.
3. Open Micpeg from Applications.
4. Choose the microphone you want to keep, and press **Keep**.

That is the whole setup. macOS will tell you that a login item was added — that is the background
helper, and it is what keeps the microphone after you quit the app.

Open it from the disk image rather than dragging it first and Micpeg says so and refuses to set
anything up: macOS runs an app opened in place from a read-only copy that disappears when the
image is ejected, and a helper registered from there would quietly stop working.

If you use Homebrew: `brew install --cask oakgimbap/tap/micpeg`.

## Using it

Micpeg is an app you open a few times, not one you leave running. Quitting it changes nothing —
the background helper is a login item and keeps going.

- **Change the microphone:** open Micpeg, press **Change Microphone**, pick one.
- **Turn it off for a while:** press **Pause**. **Resume** puts it back.
- **See what it has been doing:** Window ▸ Activity (⌥⌘L) lists every switch it reversed and
  every choice it yielded to.
- **Check the microphone actually works:** press **Start Test** and speak. The meter moves.
- **Turn the helper off entirely:** System Settings ▸ General ▸ Login Items & Extensions. Micpeg
  notices and tells you it is switched off.

## Updating

Download the new disk image and drag it over the copy in Applications, or
`brew upgrade --cask micpeg`. The registration survives being replaced in place.

Replacing the app restarts the background helper, and a restarted helper does not remember that
you had switched to another microphone by hand — it applies your kept microphone again. If you
were deliberately using something else, check after updating.

## Removing Micpeg

Open Micpeg, go to **Settings** (⌘,) and press **Remove…**. That turns off the background helper,
removes the login item, and deletes Micpeg's settings and its log. Micpeg then quits and shows
itself in the Finder so you can drag it to the Trash.

**Do this before deleting the app, not after.** Dragging Micpeg to the Trash on its own leaves the
login item behind — measured on macOS 26.6, it survives moving the app, trashing it, and emptying
the Trash. The same applies to `brew uninstall`: remove it in the app first.

## What Micpeg deliberately does not do

- Touch the default output or system output — not even as an option. It is not in the config
  schema, so it cannot be switched on by mistake.
- Force a fallback when your chosen mic is unplugged. With no target present Micpeg does nothing
  and macOS behaves normally.
- Run a polling loop. A `StartInterval 5` agent would wake up 17,280 times a day.
- Reach the network, in any form.

## Known limitations

- **A deliberate Bluetooth mic choice made within ~15 s of connecting it gets reverted once.**
  There is no signal anywhere in CoreAudio that says who initiated a change
  (`log stream --predicate 'subsystem == "com.apple.coreaudio"'` produces zero lines for these
  transitions), so this is a heuristic. Pick it again a moment later, or press Pause.
- The same applies for ~15 s after login or a `coreaudiod` restart.
- **Two unexplained incidents, one of which the app does not reveal.** On 2026-09-10 the helper
  reported that it was keeping the microphone while the default input actually sat on a Bluetooth
  headset for ~1.5 h with no log output. On 2026-09-11 the same shape recurred for 42 minutes and
  ended with the helper treating that headset as a settled choice and yielding to it. Both
  followed one of the helper's own writes away from the headset. Sleep, `coreaudiod` restart,
  process restart, queue deadlock and a dead listener were all ruled out; a dropped notification
  and a judgement made against a stale value are the two remaining explanations, and five
  reproduction attempts failed. Three silently-give-up paths were hardened as insurance. In the
  second shape the window looks correct — it says another microphone is in use — and protection is
  simply off until you disconnect the headset. Pressing Pause and then Resume restores it
  instantly in both cases.

## How it works

Three `AudioObjectAddPropertyListenerBlock` listeners on the system object — device list, default
input, and HAL restart — feeding a five-state machine. Whether a change was automatic or
deliberate is decided primarily by **transport type**, not by timing: Bluetooth is the only path
by which macOS takes the default input on its own. Timing is a secondary signal, and the strongest
evidence of all is Micpeg's own write clock — if the default moves 400 ms after Micpeg set it, no
human did that.

Full rationale, including three design defects found and fixed before shipping:
**[docs/design.md](docs/design.md)**. Measured numbers and the test matrix are in
[docs/verification.md](docs/verification.md). The original development log (Korean) is at
[docs/ko/engineering-log.md](docs/ko/engineering-log.md).

## For developers

Inside the app bundle there is a command-line tool, `micpeg`. It is the background helper, and it
is what the app runs for every change it makes — the app itself writes nothing to CoreAudio, which
is a rule CI enforces rather than a convention. It can also be installed and driven on its own,
without the app.

Its commands, its configuration file, and how to build and install it from source are in
**[docs/cli.md](docs/cli.md)**. Building Micpeg itself is in
[CONTRIBUTING.md](CONTRIBUTING.md).

## Contributing

Bug reports and focused pull requests are welcome. A few of this project's rules are enforced by
CI rather than by review — read [CONTRIBUTING.md](CONTRIBUTING.md) first, it is short.

When reporting a problem, attach the log — Micpeg ▸ Settings ▸ Log File ▸ **Show in Finder** — and
say what the Activity window showed. **Do not paste the output of `micpeg list`:** a device UID
embeds a USB serial number or a Bluetooth MAC address, and an issue is public.

## License

MIT — see [LICENSE](LICENSE).
