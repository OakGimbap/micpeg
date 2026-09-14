#!/bin/sh
# Select the Xcode that ships the macOS 14 SDK.
#
#   ./scripts/pin-xcode.sh            # report which Xcode it would be
#   ./scripts/pin-xcode.sh --select   # ...and make it active (xcode-select, needs sudo)
#
# CLAUDE.md's code-style rule — mark every SwiftUI view @MainActor — exists because the macOS 14
# SDK isolates only a view's `body` to the main actor, so this toolchain catches isolation errors
# a current local toolchain accepts without a warning. That only holds while the build really does
# use the macOS 14 SDK, and the runner image's default Xcode drifts. Select by SDK version rather
# than by Xcode version, so an image refresh that drops one point release fails over instead of
# silently moving onto a newer SDK.
#
# This lives in a script rather than inline in a workflow because there are now two workflows that
# must use the *same* toolchain: ci.yml proves the code compiles against that SDK, and release.yml
# builds the artifact users run. Two inline copies drift, and the first time they drift the shipped
# binary is not the one CI gated. One file cannot.
set -e
cd "$(dirname "$0")/.."

# GitHub annotates a line beginning ::error:: and a developer's terminal does not. Both should
# read as a sentence either way.
err() {
    [ -n "${GITHUB_ACTIONS:-}" ] && printf '::error::%s\n' "$1" || printf 'error: %s\n' "$1" >&2
}

pick=""
sdk=""
# Xcode_15.3.app first: it is the version this project has actually been exercised against. The
# glob is the failover, not the plan.
for app in /Applications/Xcode_15.3.app /Applications/Xcode*.app; do
    [ -d "$app" ] || continue
    found="$(DEVELOPER_DIR="$app/Contents/Developer" xcrun --sdk macosx --show-sdk-version 2>/dev/null || true)"
    case "$found" in
        14.*) pick="$app"; sdk="$found"; break ;;
    esac
done

if [ -z "$pick" ]; then
    err "no installed Xcode ships the macOS 14 SDK any more. This is the only place that SDK is"
    err "exercised — pick a replacement, update CLAUDE.md, and say so in the commit."
    ls -d /Applications/Xcode*.app 2>/dev/null || echo "no /Applications/Xcode*.app at all"
    exit 1
fi

echo "selected $pick (macOS SDK $sdk)"

if [ "${1:-}" = "--select" ]; then
    sudo xcode-select -s "$pick"
    # Printing a toolchain is not the same as having one. Assert what was actually selected,
    # because the isolation rule above depends on this and nothing else checks it.
    active="$(xcrun --sdk macosx --show-sdk-version)"
    case "$active" in
        14.*) ;;
        *) err "expected the macOS 14 SDK after xcode-select, got $active"; exit 1 ;;
    esac
    swift --version
    xcodebuild -version
    echo "macOS SDK: $active"
elif [ -n "$1" ]; then
    err "unknown argument: $1"
    exit 2
fi
