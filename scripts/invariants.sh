#!/bin/sh
# The structural invariants from CLAUDE.md, checked rather than trusted.
#
#   ./scripts/invariants.sh [repo-root]
#
# Run by CI and runnable locally. Every check prints the directories it actually
# searched: an invariant that passes because it looked at nothing is the same class of
# lie as an idle daemon with dead listeners, and this file was written after exactly
# that happened (an unquoted "$DIRS" does not word-split under zsh, so the first draft
# grepped one non-existent path and reported PASS).
set -u
cd "${1:-$(dirname "$0")/..}" || exit 1

fail=0

# absent <label> <pattern> <dir>...
absent() {
    label=$1
    pattern=$2
    shift 2
    scope=""
    hit=0
    for d in "$@"; do
        [ -d "$d" ] || continue
        scope="$scope $d"
        if grep -rn -- "$pattern" "$d"; then hit=1; fi
    done
    if [ -z "$scope" ]; then
        echo "skip: $label — no target present yet"
    elif [ "$hit" -eq 1 ]; then
        echo "FAIL: $label —$scope"
        fail=1
    else
        echo "ok:   $label —$scope"
    fi
}

# The app reads CoreAudio and registers listeners; every mutation goes through the CLI.
absent "the app writes nothing to CoreAudio" \
       "AudioObjectSetPropertyData" \
       Sources/MicpegApp Sources/MicpegUI Sources/MicpegAudio

# Input only. The app has to read the default output to display it, so this check is
# about the daemon and the shared helpers, not about the whole repo.
absent "the daemon never names the default output" \
       "DefaultOutputDevice" \
       Sources/micpeg Sources/MicpegAudio

# Keeps "the background agent never opens the microphone" literally true now that the
# app has a level meter.
absent "the daemon cannot open an audio stream" \
       "AVFoundation" \
       Sources/micpeg Sources/MicpegAudio

# One call to setDefaultInputDevice is the whole argument that input-only is structural
# rather than a habit. Count it.
writes=$(grep -rc AudioObjectSetPropertyData Sources | awk -F: '{n+=$2} END {print n+0}')
if [ "$writes" = "1" ]; then
    echo "ok:   exactly one CoreAudio write in Sources/"
else
    echo "FAIL: expected exactly 1 CoreAudio write in Sources/, found $writes"
    fail=1
fi

exit $fail
