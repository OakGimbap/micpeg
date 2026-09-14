# Interface — the settings app

What the app looks like, and the Apple conventions it is required to follow.

[`app-design.md`](app-design.md) covers the architecture. This document covers the window.

---

## Read Apple's documentation first, and trust it over this file

Everything below about SwiftUI APIs and macOS conventions is written from documentation, not
from a running build. **Fetch and read the current sources before implementing** — API
availability moves, and the system's visual language has changed materially in recent releases.

| Topic | Source |
|---|---|
| macOS platform conventions | https://developer.apple.com/design/human-interface-guidelines/designing-for-macos |
| Layout, margins, spacing | https://developer.apple.com/design/human-interface-guidelines/layout |
| Components (buttons, lists, labels) | https://developer.apple.com/design/human-interface-guidelines/components |
| Writing / UI voice | https://developer.apple.com/design/human-interface-guidelines/writing |
| Settings windows | https://developer.apple.com/design/human-interface-guidelines/settings — readable as `…/tutorials/data/design/human-interface-guidelines/settings.json` |
| Accessibility | https://developer.apple.com/design/human-interface-guidelines/accessibility |
| App icons | https://developer.apple.com/design/human-interface-guidelines/app-icons |
| `Form`, `LabeledContent`, `Canvas` | https://developer.apple.com/documentation/swiftui |
| `AVAudioEngine` | https://developer.apple.com/documentation/avfaudio/avaudioengine |

Where this document and Apple's documentation disagree, Apple wins — but say so, and correct
this file. Where a claim here is marked *unverified*, verify it rather than propagating it.

**Stage 4 note on how much of this was actually obtainable.** The API rows were read from the
SDK Xcode ships, which is Apple's own documentation and more precise than the web pages:
`SwiftUI.swiftinterface`/`SwiftUICore.swiftinterface` for the containers and `Canvas`
(`macOS 12.0`, fine here), and `AVAudioEngine.h`/`AVAudioNode.h`/`AVAudioApplication.h` for the
audio. **The HIG rows could not be fetched at all** — developer.apple.com/design renders in
JavaScript and the DocC JSON endpoint 404s. No spacing or margin numbers were taken from
memory or from search results; the window sets one width and delegates every other measurement
to `Form`, which is what the Layout section below already required. See
[`verification.md`](verification.md).

## The governing idea

micpeg does the job that **System Settings → Sound** should have done. Matching that pane's
visual language is not imitation; it is the correct answer to "where does this belong".

Concretely: grouped rows in rounded containers, secondary captions below a group, system font
at semantic sizes, the user's accent color, no custom chrome. On macOS this is what
`Form` + `.formStyle(.grouped)` produces, with `LabeledContent` for each row.

**Rendering the same information in a bare `VStack` of `Text` is what makes a Mac app look
homemade.** The native feel comes from choosing the right container, not from styling.

Open System Settings → Sound → Input side by side while building. It is the reference.

## Language

**English is the development language, and Korean ships beside it.** The repository is
English-primary (`README.md` is English, `README.ko.md` is the translation, and `CLAUDE.md`
requires English identifiers and comments), so the English is written first, and it is the key
the Korean is looked up by.

- Every user-facing string lives in `Sources/MicpegUI/Strings.swift` as `String(localized:)`.
  Do not hardcode strings inside view bodies. A literal passed to `Text` or
  `.accessibilityLabel` is itself a lookup key, so text that is already translated goes through
  `Text(verbatim:)`.
- The Korean is `bundle/ko.lproj/Localizable.strings`, copied into the bundle by `bundle.sh` and
  found through `Bundle.main`. It is not a SwiftPM resource: the generated `Bundle.module` looks
  at the root of the `.app`, where a bundle cannot be signed, and otherwise calls `fatalError`.
- `scripts/l10n-check.sh` compares the keys the compiler extracts with the table and fails on a
  missing one — whose silent form is one English sentence in a Korean window. CI runs it.
- Korean follows `README.ko.md`'s register — statements in 합니다, instructions in 하세요 — and
  macOS's own Korean for system terms. A device name is followed by 을(를), 이(가) or (으)로, as
  macOS writes it, because its last sound is not known.
- The choice is made in [Settings](#settings) and stored as `AppleLanguages` in the app's own
  defaults domain: the key System Settings › Language & Region › Applications writes, so the two
  are one setting. It takes effect when the app reopens, because the frameworks choose a bundle's
  language as the process starts.
- The daemon localizes nothing. Its log is a format `ActivityLog` parses.

## Window

One main window, and a `Window` scene — neither `WindowGroup` nor `Settings`. It is the app's
main window, not a preferences pane, and there is exactly one of it. A `WindowGroup` put **File ▸
New Micpeg Window (⌘N)** in the menu and made as many windows as it was asked for; hiding the
command would have left the group able to make more, and a `Window` cannot. Window tabbing is off
(`NSWindow.allowsAutomaticWindowTabbing = false`) for the same reason: View ▸ Show Tab Bar and
Window ▸ Merge All Windows are the other way a Mac app grows windows. With a `Window` as the main
scene SwiftUI builds no File menu at all; Close (⌘W) is in the Window menu
([`verification.md`](verification.md) §24). Fixed to its content size
(`.windowResizability(.contentSize)`), with scrolling disabled: there is nothing to resize, and
nothing to scroll ([`verification.md`](verification.md) §25).

Two other windows exist, once each: Activity, which is separate because of this rule (see
[Activity](#activity)), and [Settings](#settings).

Follow the HIG's macOS window margins rather than inventing spacing. Let `Form` supply the
inner rhythm; do not add manual padding between its rows.

`applicationShouldTerminateAfterLastWindowClosed = true`, via `NSApplicationDelegateAdaptor`.

## One window, several states

| State | Source |
|---|---|
| Can't run from here | the bundle is on a read-only or removable volume |
| Unconfigured | no `config.json`, or an empty priority list |
| Active (`PINNED`) | `state.json` |
| Waiting (`ABSENT`) | `state.json` |
| Standing by (`YIELDED`) | `state.json` |
| Paused (`PAUSED`) | `state.json` |
| Conflict (`BACKOFF`) | `state.json` |
| Needs approval | `SMAppService` status is `.requiresApproval` |

The skeleton is constant. Only the banner and the body change.

```
header      app name + status
banner      absent when healthy; expands for every exception
body        Output / Input rows, or the device list when unconfigured
meter       level + test control
actions     Change Microphone · pause
```

Activity is not in the skeleton. It was, as a disclosure under the meter, and it was the only
element able to change the window's height; with the window sized to its content, expanding it
resized the window itself. It has its own window now — see [Activity](#activity).

### Can't run from here

Outranks everything, including the banner, and replaces the whole body:

```
  ⬇  Micpeg needs to be in your Applications folder
     It's running from a location it can't be installed from. Quit Micpeg,
     move it to the Applications folder, and open it from there.
```

Measured at 460×160 on macOS 26.6 from a mounted disk image: two static texts, no device list,
no Keep button, no banner.

A state rather than an alert, because an alert is dismissible and a dismissed alert leaves the
user pressing Keep from the same place. **No button.** The only one available would reveal the
bundle in the Finder, and from a translocated launch that puts a randomised
`/private/var/folders/…/AppTranslocation/` path on screen and points at a directory the user
cannot act on — which is this section's own rule broken by another route. The app also cannot
move itself: `scripts/invariants.sh` forbids `moveItem` in the app, and nothing Micpeg ships asks
for an administrator password.

This is not "you are not in /Applications". §28 measured that a move does not break a registration
on macOS 26.6, and warning someone in `~/Downloads` about a problem that does not exist there is
noise — it would also block running `build/Micpeg.app` during development. One tier, for a volume
that cannot hold an installation.

### Unconfigured

```
┌────────────────────────────────────────────┐
│ ●○○                                micpeg  │
│                                            │
│   When a Bluetooth headset connects,       │
│   macOS moves your microphone to it.       │
│   Choose the microphone to keep.           │
│   It stays selected from then on,          │
│   including after you disconnect the       │
│   headset.                                 │
│                                            │
│   ┌──────────────────────────────────────┐ │
│   │  ◉  Elgato Wave:1              usb   │ │
│   │  ──────────────────────────────────  │ │
│   │  ○  MacBook Pro Microphone     bltn  │ │
│   │  ──────────────────────────────────  │ │
│   │  ○  AirPods Pro                bltn ⚠│ │
│   └──────────────────────────────────────┘ │
│     Don't see it? Connect it and it will   │
│     appear here.                           │
│                                            │
│   [        Keep Elgato Wave:1        ]     │
│                                            │
│     Enabling adds a background helper.     │
│     macOS will tell you that a login item  │
│     was added.                             │
└────────────────────────────────────────────┘
```

The `⚠` marks a device on a blocked transport. Pinning a Bluetooth device while Bluetooth is in
`blockTransports` produces an agent that can never act — the CLI already warns about this in
`warnIfTargetIsBlocked()`. Match that behavior: warn and confirm, do not silently disable.

The closing sentence pre-announces the system notification about background items. Without it,
that notification reads as something installing itself behind the user's back.

The third line of the opening says what will be true *afterwards*. The headline states the problem
and the instruction says what to do; someone who has just downloaded this has no sentence telling
them what they get. It deliberately says nothing about what connecting a headset does to output —
the claim that pinning the input keeps AirPods in A2DP is embargoed until it is observed on
hardware, and a line like this one is exactly where it would get smuggled in.

**The button is titled "Keep Microphone" when nothing is selected**, not "Keep None". It is
disabled either way, so the title is only ever read — but `suggestedChoice` returns nil when the
current input is on a blocked transport, which is precisely a fresh install on a Mac whose only
input is a headset, and "Keep None" was the first sentence that user saw.

**The device list scrolls past six devices**, inside a fixed cap, while the headline, the footer
and the Keep button stay put. The window is sized to its content with scrolling disabled, so a
longer list is *clipped*, not scrolled, and the row that goes off the bottom is the Keep button —
which §22 measured stays in the accessibility tree while off screen, so nothing automated notices.
Ten inputs is not exotic: an aggregate device, a multi-channel interface, Continuity Mic and a
webcam reach it. The threshold is not measured; §29 is where the long list gets looked at.

### Active

```
┌────────────────────────────────────────────┐
│ ●○○                                micpeg  │
│                                            │
│   ┌──────────────────────────────────────┐ │
│   │  Output          AirPods Pro         │ │
│   │  ──────────────────────────────────  │ │
│   │  Input           Elgato Wave:1    ✓  │ │
│   └──────────────────────────────────────┘ │
│     Matches the microphone you chose.      │
│                                            │
│   ┌──────────────────────────────────────┐ │
│   │  ▁▂▅█▇▄▂▁▁▂▆█▅▃▁    [ Test Microphone ]│
│   └──────────────────────────────────────┘ │
│                                            │
│              [ Change Microphone ]   [ ⏸ ] │
└────────────────────────────────────────────┘
```

Output and Input sitting one above the other is the whole product in two lines: *listening on
AirPods, speaking through the good microphone.* Leaving the window open while connecting a
headset shows Output change and Input hold — the most convincing demonstration available, and
it costs nothing beyond live values.

### Exception banners

Tone differs per state, and only one of them is a warning.

**Waiting** — the state a laptop user sees most often. It must not read as a fault.

```
│   ⓘ  Elgato Wave:1 isn't connected. It will │
│      be pinned again as soon as you         │
│      reconnect it.                          │
```

Informational styling, secondary color. No red, no warning symbol.

**Standing by** — the only exception the user might want to undo.

```
│   ⓘ  You selected AirPods Pro yourself, so  │
│      pinning stopped. It resumes when you   │
│      disconnect AirPods Pro or reconnect    │
│      Elgato Wave:1.        [ Pin Again ]    │
```

**Paused**

```
│   ⏸  Paused. macOS can move your microphone │
│      freely.               [ Resume ]       │
```

**Conflict** — the only genuine warning.

```
│   ⚠  Reverted three times in five seconds.  │
│      Another app may also be changing the   │
│      input device. Pausing for 60 seconds.  │
│                            [ Open Log ]     │
```

**Needs approval** — `SMAppService` reports `.requiresApproval`.

```
│   ⚠  Turned off in Login Items, so nothing  │
│      is running.   [ Open Login Items ]     │
```

The button opens System Settings directly. Telling a user to "go to System Settings" without
taking them there is where this flow usually dies.

### Removing Micpeg

```
              Remove Micpeg?

  This turns off the background helper, removes the
  login item, and deletes Micpeg's settings and its
  log. Micpeg then quits and shows itself in the
  Finder, so you can move it to the Trash.

              [ Cancel ]  [ Remove ]
```

A `confirmationDialog` with a destructive role, the same shape as the main window's
blocked-device confirmation.

- **Why it exists at all.** Dragging Micpeg to the Trash is not a removal. §3 measured the daemon
  surviving on its inode and the launchd job surviving as unspawnable; §28 measured the Background
  Task Management record and its Login Items entry surviving a move, the Trash, *and* emptying the
  Trash. The user is left with a switch in System Settings for an app that no longer exists. Only
  `SMAppService.unregister()` clears it, so only the app can do this.
- **In Settings, not the main window.** The main window answers "is it working?", and this is not
  that question. Not a second pane either — see the one-pane argument above; a fourth section is a
  row, a pane is machinery.
- **The word is Remove, never Uninstall.** The bundle stays where it is: `scripts/invariants.sh`
  forbids `trashItem` in the app, and a process deleting the executable it is running from is a
  bad idea independent of any rule. Revealing it in the Finder and quitting is the honest ending,
  and the dialog says so before anything happens.
- **The footer earns its line.** The helper's whole job is writing the default input, so anyone
  removing it wants to know whether their microphone is about to change. It is not.
- **What it clears:** the registration, the launchd job, the legacy plist if one is there,
  `~/.config/micpeg/{config,state}.json` (and the directory, only if it is then empty),
  `~/Library/Logs/micpeg.log`, `~/.local/bin/micpeg` *only when it is this bundle's own symlink*,
  and the two values in `com.micpeg.app`. A regular file at `~/.local/bin/micpeg` is the
  standalone command-line install and is left alone — it is the user's.
- **A Homebrew `zap` is not equivalent**, and the Cask says so in its caveats: `uninstall
  launchctl:` boots the job out but cannot clear a record that is not a file, and a cask cannot
  tell a symlink into the bundle from a standalone install. The supported order is Remove in the
  app, then `brew uninstall`.

## Activity

What happened to the microphone, in a window of its own: Window ▸ Activity (⌥⌘L), and the
**Show Activity** button on the banner that reports a failed restore. Sized by the user
(`.windowResizability(.contentMinSize)`); the list scrolls, and nothing in it can move its own
frame. [`verification.md`](verification.md) §23 has the measurements that moved it out of the
main window.

### A row is a picture

```
Today
  ↺  AirPods Pro → Elgato Wave:1                      Just now
  ●  MacBook Pro Microphone → Elgato Wave:1         12 min ago
  ●  → MacBook Pro Microphone                       13 min ago
  ▶  Resumed → Elgato Wave:1                          10:14 AM
  ⏸  Paused                                           10:12 AM
Yesterday
  ⚠  Couldn't switch back                             11:40 PM
  ⏻  Started  Elgato Wave:1  ×3                       11:02 PM
```

- **The badge says who acted.** Tinted `arrow.uturn.backward.circle.fill` is Micpeg putting the
  microphone back — the thing the app exists to do, so it alone takes the accent colour. The
  person badge is the user, in this app or in System Settings. Devices coming and going and the
  daemon starting are secondary. Problems are orange; red stays reserved, per the table below.
- **A device is its transport's symbol and its name**: `headphones` for Bluetooth, `laptopcomputer`
  for built-in, `iphone` for Continuity, `mic.fill` otherwise.
- Rows where no device moved carry a two- or three-word label: Paused, Started, Couldn't switch
  back.
- Adjacent identical rows collapse into one with `×N` rather than disappearing.
- The sentence the first version printed is still there, as the row's accessibility label.
  VoiceOver reads the words; everyone else reads the picture. Combine the row's children and it
  reads every symbol's own name too — "Right arrow" — so the row ignores them instead.

### Time

To the minute, never the second: **Just now** under a minute, **12 min ago** under an hour, then
the clock time, under a day header — Today, Yesterday, then the date. One `TimelineView` drives
the window, anchored on the newest entry so that row leaves "Just now" at exactly sixty seconds.

### Who acted is read from the trigger, not guessed

Every REVERT line in the log names its trigger, and `SIGHUP` — the config being reloaded — is the
user picking something in this app. The first version showed those as "Moved your microphone
back", crediting Micpeg with the user's own choice: in the screenshot that prompted this
section, all ten rows were the user or a daemon restart. `ActivityLog.swift` has the whole
classification and the three facts about the log it rests on.

## Settings

⌘, — SwiftUI's `Settings` scene, which puts **Settings…** in the app menu. It holds the app's
own preference, the way into Activity, and what Micpeg is. It is not a second place to choose the
microphone; that stays in the main window.

```
┌──────────── Micpeg Settings ────────────┐
│ ┌─────────────────────────────────────┐ │
│ │ Language           System Language ⌄│ │
│ │ Takes effect when…     [Reopen Now] │ │  ← only while the choice differs from launch
│ └─────────────────────────────────────┘ │
│ ┌─────────────────────────────────────┐ │
│ │ Activity              [Show Activity]│ │
│ │ Log File             [Show in Finder]│ │
│ └─────────────────────────────────────┘ │
│   Activity shows what happened to your  │
│   microphone. The log file is the       │
│   background helper's full record.      │
│ ┌─────────────────────────────────────┐ │
│ │ Version                    0.9.0 (2)│ │
│ │ License          MIT License  [View]│ │
│ │ Source Code  github.com/OakGimbap/… │ │
│ └─────────────────────────────────────┘ │
│   Micpeg uses no third-party code, so   │
│   there are no other licenses to list.  │
│ ┌─────────────────────────────────────┐ │
│ │ Remove Micpeg              [Remove…]│ │
│ └─────────────────────────────────────┘ │
│   Your microphone choice in System      │
│   Settings is not changed.              │
└─────────────────────────────────────────┘
```

- **One pane.** Apple's HIG: "If your settings window doesn't have multiple panes, use the title
  *App Name* Settings." Seven rows do not need a toolbar, and panes would bring the same page's
  "restore the most recently viewed pane" with them — one more stored value.
- **Activity is a button, not a pane.** The same page: a settings window "accommodates the size
  of the current pane, people don't need to expand the window". Activity is sized by the user.
- **Languages are listed by their own names** — English, 한국어 — so that someone who cannot read
  the window's current language can still find theirs.
- **The license is the file.** `bundle.sh` copies `LICENSE` into the bundle, the row's name is
  its first line, and **View** shows the rest, never translated. Micpeg has no dependencies, so
  there is nothing else to acknowledge, and the footer says so.
- The main window's container and sizing: `Form` + `.formStyle(.grouped)`, one width,
  `.fixedSize(horizontal: false, vertical: true)`, scrolling disabled.

The HIG sentences above were read from the page's DocC JSON,
`developer.apple.com/tutorials/data/design/human-interface-guidelines/settings.json`, which
answered where the rendered page did not.

## Container mapping

Use the standard component in every case. This table is a starting point — confirm current
availability against Apple's documentation.

| Element | API |
|---|---|
| Window | `Window`, not `WindowGroup` + `.windowResizability(.contentSize)`; window tabbing off |
| Settings | the `Settings` scene: one grouped `Form`, sized like the main window |
| Text that is already translated | `Text(verbatim:)` — a literal is a lookup key |
| Grouped rows | `Form { Section { … } }` + `.formStyle(.grouped)` |
| Label/value row | `LabeledContent` |
| Caption below a group | the section's footer |
| Device list (sheet) | `List` + an inset list style |
| Window sizing | `.frame(width:)` + `.fixedSize(horizontal: false, vertical: true)` on the `Form`, then `.scrollDisabled(true)`. `.fixedSize` is what sizes the window: `scrollDisabled` standing in for it, as this row once specified, left the window at a default height with the content clipped ([`verification.md`](verification.md) §22). Beside `.fixedSize` it only removes a scroll bar that had a point of travel (§25) |
| Activity | its own `Window` scene with `.contentMinSize`; a `Form` with one `Section` per day, inside one `TimelineView` |
| Primary action | `.buttonStyle(.borderedProminent)`, large control size |
| Secondary action | `.buttonStyle(.bordered)` |
| Icon-only action | `.buttonStyle(.borderless)` + `.help()` + an accessibility label |
| Banner | a labeled row with an SF Symbol, styled by severity |
| Device picker | `.sheet` |
| Level meter | `Canvas` |
| Icons | SF Symbols only — `mic`, `speaker.wave.2`, `checkmark.circle.fill`, `info.circle`, `exclamationmark.triangle`, `pause.circle`; in Activity, `arrow.uturn.backward.circle.fill`, `person.crop.circle.fill`, `play.circle.fill`, `power.circle.fill`, `mic.circle.fill`, `mic.slash.circle.fill`, `headphones`, `laptopcomputer`, `iphone`, `mic.fill`, `arrow.right` |
| Colors | semantic only — `.primary`, `.secondary`, `.tint`. Red exclusively for `BACKOFF` and approval failure |

**The device list is not "every device with an input scope".** Aggregate-transport devices are
excluded: while any application holds the default input open — including this app's own input
test — the HAL publishes a transient `CADefaultDeviceAggregate-<pid>-<n>` that has an input
scope and is not a microphone. `kAudioDevicePropertyIsHidden` does not mark it. Measured, see
[`verification.md`](verification.md).

Changing the pinned microphone happens in a **sheet**, not inline. An always-visible list
invites a misclick that silently repins, and this app is not opened often enough for the mistake
to be caught quickly.

Building with a current SDK means standard controls pick up the system's current appearance for
free. That is an argument for using them and for keeping custom drawing to the one place it is
unavoidable.

## Level meter

The only custom-drawn element, and therefore the only place the native feel can break.

```
AVAudioEngine.inputNode.installTap(bufferSize: 1024)
   → RMS per buffer
   → ring buffer (~64 slots)
   → 30 Hz timer redraws a Canvas       ← never draw from the tap callback
```

The engine follows the **system default input** — no device selection. That is deliberate: the
test must exercise the same path every other app uses, which is exactly what is being verified.

Behavior:

- Request microphone permission when the user starts a test. **Never at launch** — a permission
  prompt during onboarding, for a capability not yet in use, costs installs.
- Restart on the engine's configuration-change notification, debounced well past the daemon's
  300 ms. A revert moves the device twice roughly 400 ms apart.
- Stop the engine when the test stops, the window closes, or the app deactivates. A microphone
  indicator left lit is worse than a missing feature.
- After a few seconds below a silence threshold, name the likely causes. **Calibrate the
  threshold against a working microphone, not against zero.** Measured: a quiet room reads an
  RMS of ~0.0017 and a device that is delivering nothing reads exactly 0.00000, so a threshold
  of 0.01 tells a working microphone it is silent. `MicpegApp meter` prints these numbers.
- **A closed lid is a likely cause and belongs in the hint.** With the lid shut and an external
  display attached, the built-in microphone is still listed, still unmuted, still reports an
  input volume — and delivers zeros. The hint names that first when the silent device is the
  built-in one.

```
│   ▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁      [ Stop Test ]  │
│   ⚠ No sound is reaching this microphone.   │
│     Check its mute switch and the input     │
│     volume in System Settings.              │
```

Without that hint, one hardware mute switch — the Elgato Wave has one — reads as "micpeg is
broken".

Restraint, because it sits next to system-standard controls:

- The accent color or a semantic color. No gradients, glows, or custom palettes
- Corner radius matched to the surrounding container
- When Reduce Motion is on, stop scrolling and show a static level

System Settings → Sound → Input's own level display is the calibration point for how plain this
should look.

## Copy

Follow the HIG's writing guidance. In brief:

- Sentence case for descriptive text; title case for buttons and labels
- Full sentences take periods; short labels do not
- Second person, present tense. Say what happens, not what the program does internally
- Avoid the app's own name in body text where "it" is clearer
- No exclamation marks, no apologies, no jargon: `YIELDED`, `PINNED`, `BACKOFF` are internal
  state names and must not appear in the window

## Accessibility

Not optional, and cheap when the standard components are used.

- Every icon-only control gets an accessibility label
- **The meter is decorative.** Hide it from assistive technology and make the adjacent status
  text carry the information — this is why the silence hint is a sentence and not a color
- Color is never the only signal. `✓`, `⚠` and their captions carry meaning on their own
- Honor Reduce Motion and Increase Contrast
- The device list must be fully keyboard navigable, with a visible focus ring
- Verify with VoiceOver and with full keyboard access enabled
- **Do not read the tree with AppleScript's `title of`.** SwiftUI publishes a control's label
  as `AXDescription`, so `title` is empty for every button and the window looks unlabelled when
  it is not. Use the accessibility API directly. Stage 4 lost time to this.

## App icon

The single strongest signal of whether an app looks native, and the one SwiftUI does not
provide. Follow Apple's app-icon guidance for shape, margins and rendering; a flat glyph on a
square canvas is immediately recognizable as third-party.

Not on the critical path — it can proceed in parallel with the code — but do not ship without
it. `scripts/bundle.sh` warns when `bundle/AppIcon.iconset` is missing and **fails** under
`MICPEG_RELEASE=1`, so that rule is enforced rather than remembered.

**Shipped as an iconset compiled at bundle time, not as a committed `.icns`.** `iconutil` rejects
a member that is misnamed or the wrong size; a hand-assembled `.icns` missing its 1024px member
assembles without complaint and produces a blurry Dock icon with no error anywhere. Ten PNGs are
each independently inspectable and diffable, and `bundle/` is where `bundle.sh`'s inputs live.
`scripts/make-icon.swift` draws them — CGPaths only, because Apple's SF Symbols licence forbids
their use in app icons — on the 1024 grid Apple's template uses: an 824×824 body centred in a 1024
canvas, which leaves the 100-pixel margin the system expects for the shadow.

**The 16- and 32-pixel members are drawn differently, on purpose.** The shapes are described once
in the 1024 grid and scaled, which is right for areas and wrong for lines: the cradle's 46-unit
stroke is 5.75 px at 128 and **0.72 px at 16**, below one pixel, so it rendered as a grey smear and
the mark stopped reading as a microphone at exactly the size System Settings ▸ Login Items and ⌘Tab
use. The strokes now have a floor in rendered pixels, converted back into grid units.

Thickening alone was not enough, and the measurement is the reason to keep this paragraph: at 16
the cradle's lower arc, the stem and the stand's bar all land inside about four pixels of height,
so a heavier pen made them merge instead of resolve. Three candidates were rendered at 10× and
compared. Dropping the **stand bar** at 16 was the only one that still read as a microphone —
dropping the cradle instead reads as an exclamation mark. So 16 is the capsule and the cradle and
nothing else; 32 and up are unchanged. The shadow and the one-pixel highlight are also off below
64, where they only soften the edge the glyph needs.

If a future change makes the small members look wrong, regenerate and **look at them magnified**
before adjusting the geometry: `swift scripts/make-icon.swift` writes every size, and the 16-pixel
member is the one that decides.

`CFBundleIconFile`, never `CFBundleIconName`: the latter names an entry in a compiled asset
catalog, there is no `Assets.car` and no Xcode project to produce one, and setting it without a
catalog leaves Finder unable to resolve the icon at all.

**Known limitation, decided rather than overlooked:** macOS 26's Icon Composer `.icon` format
needs Xcode 26 and the macOS 26 SDK, which contradicts the macOS 14 SDK pin CI and the release
build both depend on. An `.icns` still renders on macOS 26 under the system's automatic
treatment.

## Never in this window

- `arrivalWindowSeconds`, `debounceMs`, `reverifyDelaySeconds`, `postWriteGraceSeconds`,
  `blockTransports`. Each was derived from hardware measurement; a settings panel advertises
  that they are safe to change. They stay in `config.json`
- Any control over audio **output**. It is displayed, never touched — see the invariants in
  [`app-design.md`](app-design.md)
- Internal state names, `OSStatus` values, four-character codes, file paths in prose. `usb` and
  `bltn` transport tags are fine; they match what the CLI shows
