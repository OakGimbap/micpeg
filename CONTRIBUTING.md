# Contributing

micpeg is a finished background agent and an unfinished settings app. Bug reports and focused
pull requests are both welcome.

Read this first. The project has a few rules that are enforced by CI rather than by review, and
they are easy to trip over on a first pull request — they are not written down anywhere a
contributor would naturally look.

## Before you open a pull request

```sh
swift build -c release      # host architecture
./scripts/invariants.sh     # the structural rules below
./scripts/l10n-check.sh     # every localizable string has a Korean entry
./scripts/id-check.sh       # no device identifier is committed
```

CI runs the same three scripts. They are fast, and they fail with a file and a line.

## A green local build is not a green CI build

CI builds against the **macOS 14 SDK**, which is stricter than a current local toolchain about
main-actor isolation: it isolates only a view's `body` to the main actor. The first time the
settings app reached CI, it failed to compile code the local toolchain had accepted without a
warning.

**Mark every SwiftUI view `@MainActor`.** That is the rule that keeps this from happening again.

## The structural rules

`scripts/invariants.sh` enforces these by grepping the source. It does not trust the code to be
polite, and it prints the directories it actually searched — an earlier draft passed by grepping
a path that did not exist.

- **Input only.** `kAudioHardwarePropertyDefaultInputDevice` is the sole write target in the
  project, and there is **exactly one** `AudioObjectSetPropertyData` call in all of `Sources/`.
- **The app writes nothing to CoreAudio.** It reads devices and registers listeners; every
  mutation goes through the `micpeg` CLI.
- **The background agent never opens the microphone**, and never reads the default output.

If a change needs to break one of these, the invariant is the thing to discuss first — open an
issue before writing the code.

## There are no automated tests

There is no `Tests/` directory, and CI runs no `swift test`. The daemon's judgement logic was
validated on real hardware instead; the measurements are in
[`docs/verification.md`](docs/verification.md).

So **a change to the judgement path in `evaluate()` needs real-hardware verification**, not a
green build. An idle daemon with dead listeners is indistinguishable from a healthy one, so a
quiet log proves nothing: provoke real events — connect a Bluetooth headset, unplug and replug
the microphone, `sudo killall coreaudiod` — and read the transitions in
`~/Library/Logs/micpeg.log`. Say in the pull request what you provoked and what you saw.

The tuning values (`arrivalWindowSeconds`, `debounceMs`, `reverifyDelaySeconds`,
`postWriteGraceSeconds`, `blockTransports`) came from hardware measurement. Please do not change
them without one.

## Housekeeping

- No `.xcodeproj` in the repository. Xcode may open `Package.swift` when SwiftUI previews are
  wanted, but the project file stays out.
- No third-party dependencies, anywhere.
- English identifiers, English comments, English UI strings — with a Korean entry in
  `bundle/ko.lproj` for anything the app displays. Every user-facing string goes through `Copy`
  in `Strings.swift`; text that is already translated goes into `Text(verbatim:)`, because a
  literal is a lookup key.
- Comments explain *why*, and cite evidence: a header line number, a measured interval, the test
  that failed.
- **Never commit a device identifier** — USB serials, Bluetooth MAC addresses, display UIDs.
  `scripts/id-check.sh` will stop you. The same applies to issue reports: `micpeg list` prints
  UIDs that embed them, while `micpeg status` prints device names only.

[`CLAUDE.md`](CLAUDE.md) is the long version of all of this, including the three CoreAudio traps
that each cost a full round of real-hardware testing to find. It is worth reading before changing
anything in the judgement path.
