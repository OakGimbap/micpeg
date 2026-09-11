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

# code_lines <pattern> <dir>...
#
# Every line matching <pattern> in <dir>... that is not a whole-line comment, as
# `path:line:content`. One definition of "a line of code mentioning X", because both checks
# below need it and the two copies had already drifted: only one of them passed `--` to grep or
# reported the directories it had searched.
#
# Whole-line comments do not count. These checks are about what the code does, and the sentence
# explaining why a call is forbidden necessarily names the call — an invariant that fires on
# its own rationale puts pressure on the rationale, which is backwards. The awk strips the
# `path:line:` prefix before testing, so a mention on a line that also carries code still
# counts, and a `//` inside a URL does not hide one.
code_lines() {
    pattern=$1
    shift
    for d in "$@"; do
        [ -d "$d" ] || continue
        grep -rn -- "$pattern" "$d"
    done | awk '{
        rest = $0
        sub(/^[^:]*:[0-9]+:/, "", rest)
        if (rest !~ /^[[:space:]]*(\/\/|\/\*|\*)/) print
    }'
}

# scope_of <dir>... — the directories that actually exist, for the "it looked at nothing"
# problem this file was written after.
scope_of() {
    scope=""
    for d in "$@"; do
        [ -d "$d" ] && scope="$scope $d"
    done
    printf '%s' "$scope"
}

# absent <label> <pattern> <dir>...
absent() {
    label=$1
    pattern=$2
    shift 2
    scope=$(scope_of "$@")
    found=$(code_lines "$pattern" "$@")
    if [ -z "$scope" ]; then
        echo "skip: $label — no target present yet"
    elif [ -n "$found" ]; then
        printf '%s\n' "$found"
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
# The pattern is `AVF`, not `AVFoundation`: the app's own capture code imports **AVFAudio**,
# so a check spelled `AVFoundation` would have let `import AVFAudio` plus an AVAudioEngine into
# the daemon target while reporting ok — an invariant that passes by looking at the wrong word.
absent "the daemon cannot open an audio stream" \
       "AVF" \
       Sources/micpeg Sources/MicpegAudio

# Stage 2 measured that `sfltool dumpbtm` demands system.privilege.admin and that authd
# caches nothing, so every invocation is one more password dialog — 26 of them in a single
# session of diagnostics. Nothing micpeg ships may ever ask for an administrator password:
# registering a LaunchAgent is per-user and needs none.
absent "nothing shipped invokes sfltool" \
       "sfltool" \
       Sources/micpeg Sources/MicpegApp Sources/MicpegUI Sources/MicpegAudio

# The app reads config.json — app-ui.md's "unconfigured" state is defined by an empty priority
# list, and state.json cannot answer it: an unset target and a target that is merely unplugged
# both read as "(absent)". Reading it is fine. Writing it is not, and the first draft of this
# check said "config.json" and so forbade both.
#
# The replacement is stronger than a check aimed at that one file: **the app writes no file
# contents at all.** Every mutation goes through the CLI (app-design.md's routing table), so
# there is nothing for the app to write, and the pinned device cannot be lost to a bug in code
# that was only ever supposed to display it. Its one filesystem change is removing the legacy
# plist during migration, which is a deletion and is the whole point of stage 3.
absent "the app writes no file contents" \
       "\.write(to:" \
       Sources/MicpegApp Sources/MicpegUI
absent "the app creates no files" \
       "createFile" \
       Sources/MicpegApp Sources/MicpegUI

# only_in <label> <allowed> <pattern> <dir>...
#
# `absent`, except in the files <allowed> names: an extended regex matched against the whole
# path.
only_in() {
    label=$1
    allowed=$2
    pattern=$3
    shift 3
    scope=$(scope_of "$@")
    found=$(code_lines "$pattern" "$@" | grep -v -E -- "^($allowed):")
    if [ -z "$scope" ]; then
        echo "skip: $label — no target present yet"
    elif [ -n "$found" ]; then
        printf '%s\n' "$found"
        echo "FAIL: $label —$scope"
        fail=1
    else
        echo "ok:   $label —$scope"
    fi
}

# The exceptions to the two checks above, named so that they stay the only ones. The app keeps
# two things in its own defaults domain, com.micpeg.app, and each has one file: where it
# registered from (RegistrationRecord.swift, stage 3's proof of a move), and its display
# language (AppLanguage.swift), as `AppleLanguages`, the key System Settings writes for a
# per-app language. Neither is a file write, so neither check above can see them. Every other
# mutation goes through the CLI, and a third file naming UserDefaults, or what writes through
# it, would be a store nobody decided to have. The first draft excused AppLanguage.swift alone,
# on the belief that the language was the first value the app stored; it failed on
# RegistrationRecord.swift the first time it ran.
stores='Sources/MicpegApp/RegistrationRecord\.swift|Sources/MicpegUI/AppLanguage\.swift'
for store in UserDefaults AppStorage SceneStorage CFPreferences; do
    only_in "only RegistrationRecord.swift and AppLanguage.swift name $store" \
            "$stores" "$store" \
            Sources/MicpegApp Sources/MicpegUI
done

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
# rather than a habit. Count it — through the same definition of "a line of code" as above, so
# the two cannot drift again, and printing the scope for the same reason `absent` does.
count_scope=$(scope_of Sources)
writes=$(code_lines AudioObjectSetPropertyData Sources | wc -l | tr -d ' ')
if [ "$writes" = "1" ]; then
    echo "ok:   exactly one CoreAudio write —$count_scope"
else
    echo "FAIL: expected exactly 1 CoreAudio write in Sources/, found $writes —$count_scope"
    fail=1
fi

exit $fail
