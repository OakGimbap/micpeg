# Contributing

Micpeg is a macOS app and the finished background agent it drives. The app is the product —
it is what users download, and it is the only supported way to install the agent. The `micpeg`
command-line tool inside the bundle is what the app runs for every change it makes; it is
documented in [`docs/cli.md`](docs/cli.md) and is not a user-facing product.

Bug reports and focused pull requests are both welcome.

Read this first. The project has a few rules that are enforced by CI rather than by review, and
they are easy to trip over on a first pull request — they are not written down anywhere a
contributor would naturally look.

## Before you open a pull request

```sh
swift build -c release                  # host architecture
./scripts/invariants.sh                 # the structural rules below
./scripts/l10n-check.sh                 # every localizable string has a Korean entry
./scripts/id-check.sh                   # no device identifier is committed
MICPEG_ADHOC=1 ./scripts/bundle.sh      # the bundle assembles, signs and passes its own checks
```

CI runs all of these. They are fast, and they fail with a file and a line.

The last one is worth running even for a change that does not touch the app: `bundle.sh` is where
the icon, the localisation tables, the `BundleProgram` path and the entitlement split are checked,
and `MICPEG_ADHOC=1` makes it work without any certificate at all.

You need a Swift 5.9+ toolchain — Xcode or the Swift command-line tools. The macOS 14 floor comes
from the app (`@Observable`), and SwiftPM applies `platforms:` package-wide, so the agent inherits
it; it links only CoreAudio and Foundation and would run on far older releases.

**Two install paths, and they refuse each other on purpose.** `./scripts/install.sh` builds and
installs the standalone command-line agent into `~/.local/bin`; `./scripts/bundle.sh` assembles
`Micpeg.app`, which registers the agent through `SMAppService`. One launchd label cannot have two
registration paths, so `install.sh` refuses while the app manages the agent, and `micpeg install`
and `micpeg uninstall` refuse from inside a bundle. [`docs/cli.md`](docs/cli.md) has the detail.

Releases are a third path: `MICPEG_RELEASE=1 ./scripts/bundle.sh`, then `./scripts/notarize.sh`,
then `./scripts/dmg.sh`. They need a Developer ID Application certificate, and
`.github/workflows/release.yml` runs them on a tag.

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
- **Nothing shipped opens a network connection.** No `URLSession`, no sockets, no update check.
  Only two files may build a `URL` from a string at all, and both hand it to `NSWorkspace` for the
  browser or System Settings to open.
- **The app changes no files**, with two named exceptions: `Migration.swift` removes the legacy
  LaunchAgent plist, and `Uninstall.swift` removes what a removal has to remove. It also stores
  exactly two values, in the two files that own them.
- **Nothing ever asks for an administrator password.** Registering a LaunchAgent is a per-user
  operation; `sfltool` is forbidden outright.

If a change needs to break one of these, the invariant is the thing to discuss first — **open an
issue before writing the code.** Widening an allowlist counts, and so does moving code into a file
that is already excused in order to satisfy the letter: that leaves the check's own comment
describing something untrue, which is the failure `invariants.sh` was written against.

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
