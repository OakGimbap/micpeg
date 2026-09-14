#!/bin/zsh
# Submit a signed artifact to Apple's notary service, wait, and staple the ticket to it.
#
#   ./scripts/notarize.sh build/Micpeg.app          # zips it, submits, staples the .app
#   ./scripts/notarize.sh build/Micpeg-0.9.0.dmg    # submits, staples the .dmg
#
# Separate from scripts/bundle.sh on purpose. bundle.sh is offline, hermetic and runs every few
# minutes while something is being changed; this needs the network, a credential, and minutes.
# Keeping the seam means a failure here is never confused with a failure there.
#
# **Both artifacts are submitted, in this order.** Notarizing only the DMG is what most guides
# show, and it leaves the app with no ticket of its own once the user drags it out: Gatekeeper's
# first-launch assessment then falls back to an *online* lookup, which can fail on a Mac with no
# network, behind a captive portal, or on an afternoon when Apple's notary endpoint is slow. A
# stapled .app launches correctly with the Wi-Fi off. The DMG needs its own ticket too — a
# Developer ID-signed but unnotarized image is quarantined and refused on mount. The second
# submission is cheap: the service has already seen every hash inside it.
#
# Credentials, either shape:
#   a developer's Mac — one-time setup, the password never reaches this script:
#     xcrun notarytool store-credentials micpeg-notary \
#         --apple-id <you> --team-id <TEAMID> --password <app-specific password>
#   CI — an App Store Connect API key, role Developer is enough:
#     APPLE_API_KEY (path to the .p8), APPLE_API_KEY_ID, APPLE_API_ISSUER_ID
set -e
cd "$(dirname "$0")/.."

target="${1:-}"
[ -n "$target" ] || { echo "usage: $0 <path to .app or .dmg>" >&2; exit 2; }
[ -e "$target" ] || { echo "error: no such file: $target" >&2; exit 1; }

case "$target" in
    *.app)
        # The notary service takes an archive, not a bundle, and `ditto -c -k --keepParent` is the
        # archiver Apple's own documentation names — zip(1) does not preserve the symlinks and
        # extended attributes a signed bundle depends on. The zip is transport only: a ticket
        # cannot be stapled to it, which is why `target` and `submit` are different things below.
        submit="$target.zip"
        rm -f "$submit"
        ditto -c -k --keepParent "$target" "$submit"
        ;;
    *.dmg) submit="$target" ;;
    *) echo "error: notarize a .app or a .dmg, not $target" >&2; exit 2 ;;
esac

if [ -n "${APPLE_API_KEY:-}" ]; then
    creds=(--key "$APPLE_API_KEY" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER_ID")
    echo "credentials: App Store Connect API key ${APPLE_API_KEY_ID}"
else
    profile="${MICPEG_NOTARY_PROFILE:-micpeg-notary}"
    creds=(--keychain-profile "$profile")
    echo "credentials: keychain profile $profile"
fi

echo "submitting $submit"
set +e
out=$(xcrun notarytool submit "$submit" "${creds[@]}" --wait --timeout 30m 2>&1)
status=$?
set -e
printf '%s\n' "$out"

# `submit --wait` prints "status: Invalid" and nothing else actionable. The reason — "the executable
# does not have the hardened runtime enabled", "the signature does not include a secure timestamp",
# "the binary is not signed with a valid Developer ID certificate" — exists only in this log, and
# in CI it is otherwise unrecoverable without re-running the whole thing by hand. Not optional.
if [ $status -ne 0 ] || ! printf '%s' "$out" | grep -q 'status: Accepted'; then
    id=$(printf '%s' "$out" | awk '/^ *id: /{print $2; exit}')
    echo "error: notarization did not succeed. The reason is only in the log:" >&2
    [ -n "$id" ] && xcrun notarytool log "$id" "${creds[@]}" >&2
    exit 1
fi

# The ticket goes on the thing users keep, never on the transport zip.
xcrun stapler staple "$target"
xcrun stapler validate "$target"

# Stapling writes into the artifact. It should not disturb the signature — the ticket lives in a
# place codesign does not seal — but "should not" is not this project's standard.
codesign --verify --strict --verbose=2 "$target"

# The assertion scripts/bundle.sh deliberately does not make, made here, where it is finally true.
case "$target" in
    *.app) spctl --assess --type execute -vv "$target" ;;
    *.dmg) spctl --assess --type open --context context:primary-signature -vv "$target" ;;
esac

echo
echo "notarized and stapled $target"
