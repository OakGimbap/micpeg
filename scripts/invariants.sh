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
        # Whole-line comments do not count. These checks are about what the code does, and
        # the sentence explaining why a call is forbidden necessarily names the call — an
        # invariant that fires on its own rationale puts pressure on the rationale, which is
        # backwards. The awk strips the `path:line:` prefix before testing, so a mention on a
        # line that also carries code still fails, and a `//` inside a URL does not hide one.
        found=$(grep -rn -- "$pattern" "$d" | awk '{
            rest = $0
            sub(/^[^:]*:[0-9]+:/, "", rest)
            if (rest !~ /^[[:space:]]*(\/\/|\/\*|\*)/) print
        }')
        if [ -n "$found" ]; then printf '%s\n' "$found"; hit=1; fi
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

# Stage 2 measured that `sfltool dumpbtm` demands system.privilege.admin and that authd
# caches nothing, so every invocation is one more password dialog — 26 of them in a single
# session of diagnostics. Nothing micpeg ships may ever ask for an administrator password:
# registering a LaunchAgent is per-user and needs none.
absent "nothing shipped invokes sfltool" \
       "sfltool" \
       Sources/micpeg Sources/MicpegApp Sources/MicpegUI Sources/MicpegAudio

# "Your pinned microphone survives the upgrade" is the entire reason the config was left where
# the daemon already looks for it, and stage 3's migration is the moment it could be lost. The
# app reads state.json out of the same directory, so the check names the one file that matters
# rather than the directory.
absent "the app never touches the daemon's config" \
       "config.json" \
       Sources/MicpegApp Sources/MicpegUI

# The bundle templates carry two mistakes that assemble and sign without complaint.
#
# A `~` in a launchd path is not ignored: launchd keeps it literally, cannot open it, and
# refuses the whole job with EX_CONFIG. Measured, docs/verification.md.
if [ -f bundle/com.micpeg.agent.plist ]; then
    if grep -n '<string>~' bundle/com.micpeg.agent.plist; then
        echo "FAIL: a launchd path in bundle/com.micpeg.agent.plist starts with ~; launchd"
        echo "      does not expand it and refuses the job (EX_CONFIG)"
        fail=1
    else
        echo "ok:   no tilde paths in bundle/com.micpeg.agent.plist"
    fi
fi

# APFS is case-insensitive by default, so Contents/MacOS cannot hold two executables whose
# names differ only by case. scripts/bundle.sh checks the assembled tree; this checks the
# names before anything is built.
if [ -f bundle/Info.plist ]; then
    exe=$(plutil -extract CFBundleExecutable raw -o - bundle/Info.plist 2>/dev/null || echo "")
    lower_exe=$(printf '%s' "$exe" | tr '[:upper:]' '[:lower:]')
    if [ "$lower_exe" = "micpeg" ]; then
        echo "FAIL: CFBundleExecutable is '$exe', which collides with the daemon's 'micpeg'"
        echo "      on a case-insensitive filesystem"
        fail=1
    else
        echo "ok:   CFBundleExecutable '$exe' does not collide with 'micpeg'"
    fi
fi

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
