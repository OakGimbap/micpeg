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
| Accessibility | https://developer.apple.com/design/human-interface-guidelines/accessibility |
| App icons | https://developer.apple.com/design/human-interface-guidelines/app-icons |
| `Form`, `LabeledContent`, `Canvas` | https://developer.apple.com/documentation/swiftui |
| `AVAudioEngine` | https://developer.apple.com/documentation/avfaudio/avaudioengine |

Where this document and Apple's documentation disagree, Apple wins — but say so, and correct
this file. Where a claim here is marked *unverified*, verify it rather than propagating it.

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

**UI strings are English.** The repository is English-primary (`README.md` is English,
`README.ko.md` is the translation, and `CLAUDE.md` requires English identifiers and comments),
and the app is being published for a general audience.

Keep every user-facing string in one place so a Korean localization can follow without a
rewrite. Do not hardcode strings inside view bodies.

## Window

One window. `WindowGroup`, not `Settings` — this is the app's main window, not a preferences
pane. Fixed to its content size (`.windowResizability(.contentSize)`); there is nothing to
resize.

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
activity    most recent daemon action, expandable
actions     Change Microphone · pause
```

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
│   ┌──────────────────────────────────────┐ │
│   │  2:14 PM  Reverted a switch to      ⌄│ │
│   │           AirPods Pro                │ │
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

## Container mapping

Use the standard component in every case. This table is a starting point — confirm current
availability against Apple's documentation.

| Element | API |
|---|---|
| Window | `WindowGroup` + `.windowResizability(.contentSize)` |
| Grouped rows | `Form { Section { … } }` + `.formStyle(.grouped)` |
| Label/value row | `LabeledContent` |
| Caption below a group | the section's footer |
| Device list (sheet) | `List` + an inset list style |
| Primary action | `.buttonStyle(.borderedProminent)`, large control size |
| Secondary action | `.buttonStyle(.bordered)` |
| Icon-only action | `.buttonStyle(.borderless)` + `.help()` + an accessibility label |
| Banner | a labeled row with an SF Symbol, styled by severity |
| Device picker | `.sheet` |
| Level meter | `Canvas` |
| Icons | SF Symbols only — `mic`, `speaker.wave.2`, `checkmark.circle.fill`, `info.circle`, `exclamationmark.triangle`, `pause.circle` |
| Colors | semantic only — `.primary`, `.secondary`, `.tint`. Red exclusively for `BACKOFF` and approval failure |

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
- After a few seconds below a silence threshold, name the likely causes:

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
