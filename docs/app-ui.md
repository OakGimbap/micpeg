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

### Unconfigured

```
┌────────────────────────────────────────────┐
│ ●○○                                micpeg  │
│                                            │
│   When a Bluetooth headset connects,       │
│   macOS moves your microphone to it.       │
│   Choose the microphone to keep.           │
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
│ │ Version                    0.1.0 (1)│ │
│ │ License          MIT License  [View]│ │
│ │ Source Code  github.com/OakGimbap/… │ │
│ └─────────────────────────────────────┘ │
│   Micpeg uses no third-party code, so   │
│   there are no other licenses to list.  │
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
it.

## Never in this window

- `arrivalWindowSeconds`, `debounceMs`, `reverifyDelaySeconds`, `postWriteGraceSeconds`,
  `blockTransports`. Each was derived from hardware measurement; a settings panel advertises
  that they are safe to change. They stay in `config.json`
- Any control over audio **output**. It is displayed, never touched — see the invariants in
  [`app-design.md`](app-design.md)
- Internal state names, `OSStatus` values, four-character codes, file paths in prose. `usb` and
  `bltn` transport tags are fine; they match what the CLI shows
