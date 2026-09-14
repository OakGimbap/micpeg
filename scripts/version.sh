#!/bin/sh
# Read — never store — the version, from the one place it lives.
#
#   ./scripts/version.sh                 # "0.9.0 2"
#   ./scripts/version.sh --short         # "0.9.0"
#   ./scripts/version.sh --build         # "2"
#   ./scripts/version.sh --expect v0.9.0 # exit 1 unless the tag is v + the short version
#   ./scripts/version.sh --check-bump    # exit 1 unless CFBundleVersion rose since the last tag
#
# bundle/Info.plist is authoritative, because it already was: Sources/MicpegUI/SettingsWindow.swift
# reads CFBundleShortVersionString back through Bundle.main for the About row, and a `micpeg`
# running from inside the bundle gets the same value for `--version` for free. A VERSION file or a
# script that stored the number would be a second copy, and a second copy is how you ship a release
# whose About box and whose download name disagree.
#
# --check-bump exists because "remember to bump the build number" is not a check. This project's
# rule is that documentation is not evidence; the same applies to intentions.
set -e
cd "$(dirname "$0")/.."

PLIST=bundle/Info.plist

read_key() {
    plutil -extract "$1" raw -o - "$PLIST" 2>/dev/null || {
        echo "error: $PLIST has no $1" >&2
        exit 1
    }
}

SHORT="$(read_key CFBundleShortVersionString)"
BUILD="$(read_key CFBundleVersion)"

case "${1:-}" in
    "")        echo "$SHORT $BUILD" ;;
    --short)   echo "$SHORT" ;;
    --build)   echo "$BUILD" ;;
    --expect)
        tag="$2"
        if [ -z "$tag" ]; then
            echo "error: --expect needs a tag" >&2
            exit 2
        fi
        if [ "$tag" != "v$SHORT" ]; then
            echo "error: tag $tag does not match $PLIST." >&2
            echo "       The rule is: the tag is v + CFBundleShortVersionString, so this tag" >&2
            echo "       wants CFBundleShortVersionString = ${tag#v}, and it is $SHORT." >&2
            exit 1
        fi
        echo "ok:   $tag matches CFBundleShortVersionString $SHORT (build $BUILD)"
        ;;
    --check-bump)
        # HEAD^ rather than HEAD: on a tagged commit, `git describe HEAD` finds that very tag and
        # would compare the release against itself.
        prev="$(git describe --tags --abbrev=0 HEAD^ 2>/dev/null || true)"
        if [ -z "$prev" ]; then
            echo "ok:   no earlier tag to compare against — this is the first release"
            exit 0
        fi
        was="$(git show "$prev:$PLIST" 2>/dev/null | plutil -extract CFBundleVersion raw -o - - 2>/dev/null || true)"
        if [ -z "$was" ]; then
            echo "ok:   $prev carried no CFBundleVersion to compare against"
            exit 0
        fi
        # Integers, not strings: "10" sorts before "9" as text, and a build number that appears to
        # go backwards would fail a release for no reason.
        if [ "$BUILD" -le "$was" ] 2>/dev/null; then
            echo "error: CFBundleVersion is $BUILD, and $prev already shipped $was." >&2
            echo "       Every release needs a higher build number — macOS caches by it." >&2
            exit 1
        fi
        echo "ok:   CFBundleVersion $was ($prev) -> $BUILD"
        ;;
    *)
        echo "error: unknown argument: $1" >&2
        exit 2
        ;;
esac
