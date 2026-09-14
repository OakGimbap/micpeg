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

# The pattern above does not match its sibling — `DefaultSystemOutputDevice` is
# Default·System·OutputDevice — and README names both. Nothing needs the system output, the
# window included.
absent "nothing names the default system output" \
       "DefaultSystemOutputDevice" \
       Sources/micpeg Sources/MicpegAudio Sources/MicpegApp Sources/MicpegUI

# Keeps "the background agent never opens the microphone" literally true now that the
# app has a level meter.
# The pattern is `AVF`, not `AVFoundation`: the app's own capture code imports **AVFAudio**,
# so a check spelled `AVFoundation` would have let `import AVFAudio` plus an AVAudioEngine into
# the daemon target while reporting ok — an invariant that passes by looking at the wrong word.
absent "the daemon cannot open an audio stream" \
       "AVF" \
       Sources/micpeg Sources/MicpegAudio

# AVFAudio is one way to open a stream, not the only one, and a list of forbidden names is only
# as good as the names someone thought of. AudioToolbox's AudioQueue and an AUHAL audio unit
# both capture, and neither says `AVF`. So the daemon's imports are checked as an allowlist —
# CLAUDE.md: "The daemon links CoreAudio + Foundation only" — and a planted
# `import AudioToolbox` fails it where the `AVF` check above let it through.
import_scope=$(scope_of Sources/micpeg Sources/MicpegAudio)
imports=$(code_lines 'import ' Sources/micpeg Sources/MicpegAudio \
    | grep -E '^[^:]*:[0-9]+:[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*import[[:space:]]' \
    | grep -v -E '^[^:]*:[0-9]+:import (CoreAudio|Darwin|Foundation|MicpegAudio)[[:space:]]*$')
if [ -n "$imports" ]; then
    printf '%s\n' "$imports"
    echo "FAIL: the daemon imports only CoreAudio, Darwin, Foundation and MicpegAudio —$import_scope"
    fail=1
else
    echo "ok:   the daemon imports only CoreAudio, Darwin, Foundation and MicpegAudio —$import_scope"
fi

# CoreAudio itself can capture, through an IOProc on the device, and it is the one framework the
# daemon has to import — so the allowlist cannot see this. A planted
# AudioDeviceCreateIOProcIDWithBlock passed every check above.
for api in AudioDeviceCreateIOProc AudioDeviceStart; do
    absent "the daemon cannot open an audio stream ($api)" "$api" \
           Sources/micpeg Sources/MicpegAudio
done

# Stage 2 measured that `sfltool dumpbtm` demands system.privilege.admin and that authd
# caches nothing, so every invocation is one more password dialog — 26 of them in a single
# session of diagnostics. Nothing micpeg ships may ever ask for an administrator password:
# registering a LaunchAgent is per-user and needs none.
absent "nothing shipped invokes sfltool" \
       "sfltool" \
       Sources/micpeg Sources/MicpegApp Sources/MicpegUI Sources/MicpegAudio

# Nothing micpeg ships opens a network connection. README spends four bullets on what the agent
# does not do with the microphone, and the same argument is worth nothing from a process that also
# talks to a server on a schedule. The decision this enforces is in docs/app-design.md: there is no
# built-in update check, because a version number is not worth an outbound connection from a
# process that holds a microphone grant. Without a check, "Micpeg never connects to anything" is a
# sentence in a README; with one, it is a property — the same move already made for
# DefaultOutputDevice and AVF.
#
# Not `http`: Sources/MicpegUI/SettingsWindow.swift holds a https:// URL it hands to
# NSWorkspace.open, and that connection is the browser's. Opening a link is not reaching out.
for api in URLSession NSURLConnection NWConnection 'Network\.' CFSocket CFStream getaddrinfo; do
    absent "nothing shipped opens a network connection ($(printf '%s' "$api" | tr -d '\\'))" "$api" \
           Sources/micpeg Sources/MicpegAudio Sources/MicpegApp Sources/MicpegUI
done

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

# Writing is not the only way to change a file. These are the other FileManager and Foundation
# calls that copy, move, link, create or delete one — none of them appeared in the two checks
# above, so a planted `removeItem` or `copyItem` passed. The app deletes exactly one file in its
# life, the legacy plist, and that deletion is checked below, once `only_in` exists. `\.moveItem`
# because the bare word is inside `removeItem`, and the first run of this loop failed on the one
# deletion it was written to allow.
for api in copyItem '\.moveItem' replaceItem linkItem createSymbolicLink createDirectory \
           trashItem 'write(toFile' 'FileHandle(forWriting' 'FileHandle(forUpdating' 'unlink('; do
    absent "the app changes no files ($(printf '%s' "$api" | tr -d '\\'))" "$api" \
           Sources/MicpegApp Sources/MicpegUI
done

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

# The app deletes files in exactly two operations, and both are the point of the file they live in.
#
# Migration.swift removes the legacy LaunchAgent plist — stage 3's whole purpose, and not
# optional: §8 measured a plist left on disk switching a registration back on within a second.
#
# Uninstall.swift removes what a removal has to remove, because dragging the app to the Trash does
# not: §3 and §28 measured the daemon surviving on its inode, the launchd job surviving as
# unspawnable, and the Background Task Management record and its Login Items entry surviving the
# Trash entirely. Only SMAppService.unregister() clears that record, so only the app can do it,
# which is why this could not be a `micpeg` subcommand — the daemon's import allowlist above means
# the CLI can never call ServiceManagement.
#
# Anywhere else, a deletion is a bug. And widening this list by moving code into Migration.swift
# to satisfy the letter would leave this comment describing something that is not true, which is
# the failure this whole script was written against.
only_in "only Migration.swift and Uninstall.swift delete a file" \
        'Sources/MicpegApp/(Migration|Uninstall)\.swift' "removeItem" \
        Sources/MicpegApp Sources/MicpegUI

# `Data(contentsOf:)` cannot be forbidden — it is how config.json, state.json and the legacy plist
# are read, in five places. What can be held down is where a URL with a *scheme* is written at all:
# the two files that hand one to NSWorkspace, which opens it in the browser or in System Settings.
# A third file constructing one would be something reaching out on its own.
addressable='Sources/MicpegUI/SettingsWindow\.swift|Sources/MicpegUI/SystemSettings\.swift'
only_in "only SettingsWindow.swift and SystemSettings.swift construct a URL from a string" \
        "$addressable" 'URL(string:' \
        Sources/micpeg Sources/MicpegAudio Sources/MicpegApp Sources/MicpegUI

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
