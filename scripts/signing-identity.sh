#!/bin/zsh
# Print the Developer ID Application identity to sign a release with, or fail saying why.
#
#   ./scripts/signing-identity.sh          # print it
#   MICPEG_SIGN_IDENTITY="…" ./scripts/…   # print that instead, after checking it is one
#
# A script rather than a copy in each of scripts/bundle.sh and scripts/dmg.sh, for the reason
# scripts/pin-xcode.sh gives: two copies of a rule drift, and the first time these two drift the
# app and the disk image around it are signed by different certificates — which Gatekeeper notices
# and the build does not.
#
# "Exactly one, or name it" is the rule, not "the first one". A Mac that has rotated a certificate
# holds two valid Developer ID Application identities, and `awk … exit` taking whichever the
# keychain lists first is how a release goes out signed with the one being retired.
set -e

if [ -n "${MICPEG_SIGN_IDENTITY:-}" ]; then
    case "$MICPEG_SIGN_IDENTITY" in
        "Developer ID Application"*) printf '%s\n' "$MICPEG_SIGN_IDENTITY"; exit 0 ;;
        *) echo "error: MICPEG_SIGN_IDENTITY is not a Developer ID Application certificate." >&2
           echo "       Got: $MICPEG_SIGN_IDENTITY" >&2
           exit 1 ;;
    esac
fi

ids=("${(@f)$(security find-identity -v -p codesigning \
              | awk -F'"' '/"Developer ID Application/ {print $2}')}")
ids=(${ids:#})

if (( ${#ids} == 0 )); then
    echo "error: no valid Developer ID Application identity in the keychain." >&2
    echo "       A release needs one; scripts/bundle.sh without MICPEG_RELEASE will sign with" >&2
    echo "       a development certificate instead." >&2
    exit 1
fi
if (( ${#ids} != 1 )); then
    echo "error: ${#ids} valid Developer ID Application identities; set MICPEG_SIGN_IDENTITY" >&2
    echo "       to say which one:" >&2
    printf '       %s\n' "${ids[@]}" >&2
    exit 1
fi
printf '%s\n' "$ids[1]"
