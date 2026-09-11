#!/bin/zsh
# Assemble, sign and check Micpeg.app.
#
#   ./scripts/bundle.sh                     # universal (arm64 + x86_64)
#   MICPEG_HOST_ARCH=1 ./scripts/bundle.sh  # this Mac's architecture only, for iteration
#   MICPEG_SIGN_IDENTITY="Developer ID Application: …" ./scripts/bundle.sh
#
# Signing is not optional here. SMAppService.h, -registerAndReturnError:
#   "If the app bundle is not properly code signed, this API will return error
#    kSMErrorInvalidSignature"
# Notarization is required for LaunchDaemons only, so an agent can be exercised with a
# development certificate. Distribution needs Developer ID; that is stage 5.
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

if [ -z "${MICPEG_SIGN_IDENTITY:-}" ]; then
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

echo
echo "--- architectures and deployment target ---"
for exe in "$CONTENTS/MacOS/MicpegApp" "$CONTENTS/MacOS/micpeg"; do
    printf '%-34s %s\n' "${exe#$APP/}" "$(lipo -archs "$exe")"
done
otool -l "$CONTENTS/MacOS/micpeg" | grep -A3 LC_BUILD_VERSION | grep -E "minos|sdk" | head -2

echo
echo "--- spctl (informational) ---"
# Expected to fail with a development certificate: Gatekeeper wants Developer ID plus
# notarization. Reported rather than asserted, because a pass here is a stage 5 concern and
# a silent skip would be the wrong habit.
spctl --assess --type execute -vv "$APP" 2>&1 || true

echo
echo "built $APP"
