#!/bin/zsh
# Assemble, sign and check Micpeg.app.
#
#   ./scripts/bundle.sh                     # universal (arm64 + x86_64)
#   MICPEG_HOST_ARCH=1 ./scripts/bundle.sh  # this Mac's architecture only, for iteration
#   MICPEG_SIGN_IDENTITY="Developer ID Application: …" ./scripts/bundle.sh
#   MICPEG_RELEASE=1 ./scripts/bundle.sh    # refuse anything Gatekeeper would reject
#   MICPEG_ADHOC=1 ./scripts/bundle.sh      # ad-hoc signature, for CI's structural checks
#
# Signing is not optional here. SMAppService.h, -registerAndReturnError:
#   "If the app bundle is not properly code signed, this API will return error
#    kSMErrorInvalidSignature"
# Notarization is required for LaunchDaemons only, so an agent can be exercised with a
# development certificate. Distribution needs Developer ID, and this script stops at a signed
# bundle: scripts/notarize.sh submits it and staples the ticket, scripts/dmg.sh packages it.
#
# MICPEG_ADHOC exists so CI can run everything below on every pull request. An ad-hoc signature
# still carries --options runtime and --entitlements, so the structural checks, the entitlement
# split and the hardened-runtime assertion all mean the same thing; only Gatekeeper's opinion
# differs, and this script never asserts that anyway.
#
# Every check below prints what it looked at. scripts/invariants.sh exists because an
# earlier check passed by searching a path that did not exist, and the same rule applies
# to a bundle that assembles without complaint.
set -e
cd "$(dirname "$0")/.."

APP="build/Micpeg.app"
CONTENTS="$APP/Contents"

# ---------------------------------------------------------------- build

ARGS=(-c release --arch arm64 --arch x86_64)
[ -n "${MICPEG_HOST_ARCH:-}" ] && ARGS=(-c release)

swift build "${ARGS[@]}"
BIN="$(swift build "${ARGS[@]}" --show-bin-path)"
for exe in MicpegApp micpeg; do
    [ -x "$BIN/$exe" ] || { echo "build produced no $exe at $BIN" >&2; exit 1; }
done

# ---------------------------------------------------------------- assemble

# A stale tree would leave a previously signed executable in place and the signature check
# below would pass on the wrong bytes.
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Library/LaunchAgents" "$CONTENTS/Resources"

# No renaming happens here, and that is deliberate. SwiftPM already produces MicpegApp and
# micpeg, so there is no copy step whose destination could collide with another.
cp "$BIN/MicpegApp" "$CONTENTS/MacOS/MicpegApp"
cp "$BIN/micpeg"    "$CONTENTS/MacOS/micpeg"
cp bundle/Info.plist "$CONTENTS/Info.plist"
cp bundle/com.micpeg.agent.plist "$CONTENTS/Library/LaunchAgents/com.micpeg.agent.plist"

# What the app reads through Bundle.main: the translations — Sources/MicpegUI/Strings.swift says
# why they are not a SwiftPM resource — and the LICENSE the Settings window shows, which the MIT
# terms ask to travel with every copy.
cp -R bundle/*.lproj "$CONTENTS/Resources/"
cp LICENSE "$CONTENTS/Resources/LICENSE"

# The icon. Compiled here rather than committed as an .icns: iconutil rejects a member that is
# misnamed or the wrong size, whereas a hand-assembled .icns missing its 1024px member assembles
# without complaint and ships a blurry Dock icon. docs/app-ui.md, "App icon": do not ship without
# one — so a release build fails where a development build only says so.
ICONSET="bundle/AppIcon.iconset"
if [ -d "$ICONSET" ]; then
    iconutil -c icns -o "$CONTENTS/Resources/AppIcon.icns" "$ICONSET"
    named=$(plutil -extract CFBundleIconFile raw -o - "$CONTENTS/Info.plist" 2>/dev/null || echo "")
    [ "$named" = "AppIcon" ] || {
        echo "error: Info.plist's CFBundleIconFile is '${named:-(absent)}', not 'AppIcon';" >&2
        echo "       Finder would look for a file that is not there." >&2
        exit 1; }
    # The largest member is the one a Retina Dock and Get Info actually draw, and it is the one
    # that is silently wrong if the iconset was assembled by hand.
    px=$(sips -g pixelHeight "$ICONSET/icon_512x512@2x.png" | awk '/pixelHeight/{print $2}')
    [ "$px" = "1024" ] || {
        echo "error: $ICONSET/icon_512x512@2x.png is ${px}px tall, not 1024." >&2
        exit 1; }
    echo "ok:   Resources/AppIcon.icns compiled from $ICONSET (largest member ${px}px)"
elif [ -n "${MICPEG_RELEASE:-}" ]; then
    echo "error: $ICONSET is missing. docs/app-ui.md: do not ship without an icon." >&2
    exit 1
else
    echo "note: no $ICONSET — this build will show the generic application icon."
fi

# The collision guard. An earlier draft of docs/app-design.md put the app at
# Contents/MacOS/Micpeg next to the daemon at Contents/MacOS/micpeg; on a case-insensitive
# filesystem — the macOS default — those are one file, the second cp wins, and the bundle
# still looks assembled. This is the check that keeps the two names distinct.
count=$(ls "$CONTENTS/MacOS" | wc -l | tr -d ' ')
if [ "$count" -ne 2 ]; then
    echo "error: $CONTENTS/MacOS holds $count file(s), expected 2:" >&2
    ls -la "$CONTENTS/MacOS" >&2
    echo "       two executables whose names differ only by case collide on APFS." >&2
    exit 1
fi
if cmp -s "$CONTENTS/MacOS/MicpegApp" "$CONTENTS/MacOS/micpeg"; then
    echo "error: the two executables in Contents/MacOS are byte-identical" >&2
    exit 1
fi
echo "ok:   Contents/MacOS holds 2 distinct executables"

# BundleProgram must name something that is actually there. A missing target registers
# without complaint and leaves launchd with nothing to exec.
program=$(plutil -extract BundleProgram raw -o - "$CONTENTS/Library/LaunchAgents/com.micpeg.agent.plist")
if [ ! -x "$APP/$program" ]; then
    echo "error: BundleProgram is '$program' but $APP/$program is not executable" >&2
    exit 1
fi
echo "ok:   BundleProgram '$program' resolves inside the bundle"

# A .strings file that does not parse is dropped whole and without a word, and every string in
# that language falls back to English. plutil reads it the way the bundle will.
for table in "$CONTENTS"/Resources/*.lproj/*.strings; do
    if ! plutil -lint -s "$table"; then
        echo "error: ${table#$APP/} does not parse" >&2
        exit 1
    fi
done

# Info.plist's CFBundleLocalizations and the .lproj directories say the same thing twice, so
# check that they agree. The development language has no table: its keys are its strings.
development=$(plutil -extract CFBundleDevelopmentRegion raw -o - "$CONTENTS/Info.plist")
declared=()
i=0
while language=$(plutil -extract "CFBundleLocalizations.$i" raw -o - "$CONTENTS/Info.plist" 2>/dev/null); do
    declared+=("$language")
    i=$((i + 1))
done
for language in "${declared[@]}"; do
    [ "$language" = "$development" ] && continue
    if [ ! -f "$CONTENTS/Resources/$language.lproj/Localizable.strings" ]; then
        echo "error: Info.plist declares '$language', and there is no $language.lproj/Localizable.strings" >&2
        exit 1
    fi
done
for lproj in "$CONTENTS"/Resources/*.lproj; do
    language=${${lproj:t}:r}
    if (( ! ${declared[(Ie)$language]} )); then
        echo "error: ${lproj#$APP/} is not in Info.plist's CFBundleLocalizations" >&2
        exit 1
    fi
done
tabled=(${declared:#$development})
echo "ok:   Resources holds LICENSE and a table for each of: ${tabled[*]} (development language, no table: $development)"

# ---------------------------------------------------------------- sign

if [ -n "${MICPEG_ADHOC:-}" ] && [ -n "${MICPEG_RELEASE:-}" ]; then
    echo "error: MICPEG_ADHOC and MICPEG_RELEASE are exclusive." >&2
    exit 1
fi

if [ -n "${MICPEG_ADHOC:-}" ]; then
    # "-" is codesign's ad-hoc identity: a real signature with no certificate behind it. Enough
    # for every check below, not enough for SMAppService to register the agent.
    MICPEG_SIGN_IDENTITY="-"
    MICPEG_NO_TIMESTAMP=1
elif [ -n "${MICPEG_RELEASE:-}" ]; then
    # The "exactly one, or name it" rule lives in one place, because scripts/dmg.sh has to sign
    # with the same certificate this does.
    MICPEG_SIGN_IDENTITY=$(./scripts/signing-identity.sh)
    if [ -n "${MICPEG_NO_TIMESTAMP:-}" ]; then
        echo "error: MICPEG_NO_TIMESTAMP with MICPEG_RELEASE. The notary service rejects a" >&2
        echo "       signature with no secure timestamp, three minutes into the submission." >&2
        exit 1
    fi
elif [ -z "${MICPEG_SIGN_IDENTITY:-}" ]; then
    MICPEG_SIGN_IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/"/ {print $2; exit}')
fi
[ -n "$MICPEG_SIGN_IDENTITY" ] || {
    echo "error: no code signing identity found and MICPEG_SIGN_IDENTITY is unset." >&2
    echo "       SMAppService refuses to register an agent from an unsigned bundle." >&2
    exit 1
}
echo "signing identity: $MICPEG_SIGN_IDENTITY"
case "$MICPEG_SIGN_IDENTITY" in
    "Developer ID Application"*) ;;
    "-") echo "note: ad-hoc signature. Every check below still applies; SMAppService will not"
         echo "      register an agent from this bundle." ;;
    *) echo "note: this is not a Developer ID certificate. Good enough to register and run"
       echo "      an agent locally; Gatekeeper will reject the bundle if it is distributed." ;;
esac

TS=(--timestamp)
[ -n "${MICPEG_NO_TIMESTAMP:-}" ] && TS=(--timestamp=none)

# Inside out, and never --deep: it is deprecated and mis-signs nested code.
# The daemon is signed without entitlements on purpose — see bundle/Micpeg.entitlements.
codesign --force --options runtime "${TS[@]}" --sign "$MICPEG_SIGN_IDENTITY" \
         "$CONTENTS/MacOS/micpeg"
codesign --force --options runtime "${TS[@]}" --sign "$MICPEG_SIGN_IDENTITY" \
         --entitlements bundle/Micpeg.entitlements "$APP"

# ---------------------------------------------------------------- check

echo
echo "--- codesign --verify --strict ---"
codesign --verify --strict --verbose=2 "$APP"

echo
echo "--- entitlements ---"
ents() { codesign -d --entitlements - --xml "$1" 2>/dev/null | plutil -p - 2>/dev/null; }
app_ents=$(ents "$APP" || true)
cli_ents=$(ents "$CONTENTS/MacOS/micpeg" || true)
echo "Micpeg.app:            ${app_ents:-(none)}"
echo "Contents/MacOS/micpeg: ${cli_ents:-(none)}"

case "$app_ents" in
    *com.apple.security.device.audio-input*)
        echo "ok:   the app carries com.apple.security.device.audio-input" ;;
    *)
        echo "error: the app is missing com.apple.security.device.audio-input." >&2
        echo "       Under the hardened runtime the TCC prompt never appears and capture" >&2
        echo "       silently yields nothing." >&2
        exit 1 ;;
esac
case "$cli_ents" in
    *audio-input*)
        echo "error: the daemon carries an audio-input entitlement. The agent must not be" >&2
        echo "       permitted to open the microphone." >&2
        exit 1 ;;
    *)
        echo "ok:   the daemon carries no audio-input entitlement" ;;
esac

# get-task-allow is never in bundle/Micpeg.entitlements, and it arrives anyway the moment anyone
# signs a debug build or an Xcode-managed profile joins in. It is the most common notarization
# rejection there is, and its symptom is a failure three minutes into a submission rather than
# here, two seconds in and offline. It also leaves the shipped app attachable by a debugger.
for ents in "$app_ents" "$cli_ents"; do
    case "$ents" in
        *get-task-allow*)
            echo "error: com.apple.security.get-task-allow is present. The notary service will" >&2
            echo "       refuse this, and a build that carries it is debuggable by anything." >&2
            exit 1 ;;
    esac
done
echo "ok:   neither executable carries com.apple.security.get-task-allow"

# The hardened runtime is a signature flag, not an entitlement, so neither check above can see it
# — and without it the notary service refuses the submission and the audio-input entitlement above
# means nothing.
for exe in "$APP" "$CONTENTS/MacOS/micpeg"; do
    # ${exe#$APP/} strips nothing when exe is the bundle itself, so name it outright.
    [ "$exe" = "$APP" ] && label="Micpeg.app" || label="${exe#$APP/}"
    if codesign -d --verbose=2 "$exe" 2>&1 | grep -q 'flags=.*runtime'; then
        echo "ok:   $label is signed with the hardened runtime"
    else
        echo "error: $label is not signed with the hardened runtime." >&2
        exit 1
    fi
done

echo
echo "--- architectures and deployment target ---"
for exe in "$CONTENTS/MacOS/MicpegApp" "$CONTENTS/MacOS/micpeg"; do
    printf '%-34s %s\n' "${exe#$APP/}" "$(lipo -archs "$exe")"
done
otool -l "$CONTENTS/MacOS/micpeg" | grep -A3 LC_BUILD_VERSION | grep -E "minos|sdk" | head -2

echo
echo "--- spctl (informational) ---"
# Expected to fail here even for a correct release build: Gatekeeper wants Developer ID *plus* a
# notarization ticket, and nothing has been submitted yet. Reported rather than asserted, because
# the assertion belongs after stapling — scripts/notarize.sh runs it there — and a silent skip
# would be the wrong habit.
spctl --assess --type execute -vv "$APP" 2>&1 || true

echo
echo "built $APP"
