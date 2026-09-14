#!/bin/zsh
# Package the notarized app into the disk image users download.
#
#   ./scripts/dmg.sh                      # build/Micpeg-<version>.dmg
#   MICPEG_DMG_UNSIGNED=1 ./scripts/dmg.sh  # skip the ticket and the signature, for exercising
#                                           # the packaging without a Developer ID
#
# Run *after* scripts/notarize.sh has stapled build/Micpeg.app, so the app inside carries its own
# ticket and launches on a Mac with no network. This script asserts that rather than assuming it.
#
# No background image and no window layout, and that is settled. Getting one needs either
# osascript driving Finder to place icons in a mounted read-write image — a CI runner has no
# logged-in Finder to talk to, and a developer's Mac raises an Apple Events TCC prompt that cannot
# be answered headlessly — or a committed .DS_Store holding icon coordinates, which is an
# unreviewable binary that breaks silently when the volume name changes. The /Applications symlink
# is the drag target, and the default two-icon window is a thing every Mac user already knows.
set -e
cd "$(dirname "$0")/.."

APP="build/Micpeg.app"
VERSION=$(./scripts/version.sh --short)
DMG="build/Micpeg-$VERSION.dmg"
STAGE="build/dmg-stage"

[ -d "$APP" ] || { echo "error: $APP is not there; run ./scripts/bundle.sh first" >&2; exit 1; }

if [ -n "${MICPEG_DMG_UNSIGNED:-}" ]; then
    echo "note: MICPEG_DMG_UNSIGNED — no ticket is required and the image is not signed."
    echo "      This image is for exercising the packaging. Do not publish it."
else
    # The one thing that cannot be checked later: an app packaged before its ticket was stapled
    # looks identical and fails on a Mac with no network.
    xcrun stapler validate "$APP"
    IDENTITY=$(./scripts/signing-identity.sh)
fi

# A DMG left attached from a previous run is the most common local failure here
# ("hdiutil: Resource busy"), and an interrupted run is exactly when it happens.
mount=""
cleanup() { [ -n "$mount" ] && hdiutil detach "$mount" -quiet 2>/dev/null || true; }
trap cleanup EXIT

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
# ditto, not cp -R: it preserves the extended attributes and the symlinks a signed bundle is
# sealed over, and a copy that quietly drops one produces an image whose app fails to verify.
ditto "$APP" "$STAGE/Micpeg.app"
ln -s /Applications "$STAGE/Applications"

# HFS+ rather than APFS: hdiutil's APFS + UDZO combination has a history of images that attach
# oddly, and at a macOS 14 floor APFS buys nothing. -ov because a stale image would otherwise stop
# the run dead.
hdiutil create -volname "Micpeg $VERSION" \
               -srcfolder "$STAGE" \
               -fs HFS+ -format UDZO -imagekey zlib-level=9 \
               -ov "$DMG"

if [ -z "${MICPEG_DMG_UNSIGNED:-}" ]; then
    # No --options runtime: a disk image is not code, and the hardened runtime is meaningless on
    # one. The timestamp is not — the notary service rejects a signature without it.
    codesign --force --timestamp --sign "$IDENTITY" "$DMG"
    codesign --verify --strict --verbose=2 "$DMG"
fi

# ---------------------------------------------------------------- check the artifact

# Mount it and look, rather than trusting the commands above. The same rule the rest of this repo
# runs on: what was intended is not evidence of what was produced.
echo
echo "--- mounted image ---"
mount=$(hdiutil attach "$DMG" -nobrowse -readonly | awk -F'\t' '/\/Volumes\//{print $NF}')
echo "attached at $mount"

[ -L "$mount/Applications" ] || {
    echo "error: no /Applications symlink in the image; there is nothing to drag onto." >&2
    exit 1; }
echo "ok:   /Applications symlink present"

[ -d "$mount/Micpeg.app" ] || { echo "error: no Micpeg.app in the image" >&2; exit 1; }
codesign --verify --strict --deep --verbose=2 "$mount/Micpeg.app"
echo "ok:   the app in the image verifies"

if [ -z "${MICPEG_DMG_UNSIGNED:-}" ]; then
    xcrun stapler validate "$mount/Micpeg.app"
    echo "ok:   the app in the image carries its own notarization ticket"
fi

printf 'ok:   %-24s %s\n' "architectures" "$(lipo -archs "$mount/Micpeg.app/Contents/MacOS/micpeg")"
printf 'ok:   %-24s %s\n' "version in the image" \
       "$(plutil -extract CFBundleShortVersionString raw -o - "$mount/Micpeg.app/Contents/Info.plist")"

hdiutil detach "$mount" -quiet
mount=""

echo
echo "built $DMG ($(du -h "$DMG" | cut -f1))"
shasum -a 256 "$DMG" | tee "$DMG.sha256"
