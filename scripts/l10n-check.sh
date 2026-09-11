#!/bin/zsh
# Every string the app localizes has a Korean translation.
#
#   ./scripts/l10n-check.sh
#
# Run by CI and runnable locally. The keys come from the compiler, not from a pattern over the
# source: with `-emit-localized-strings` it writes one .stringsdata file per source file,
# listing every literal passed to an API that looks strings up. That is each
# `String(localized:)` in Sources/MicpegUI/Strings.swift, and also any `Text("…")` or
# `.accessibilityLabel("…")` written with a literal — which is how a string meant to be
# verbatim shows up here instead of being looked up at run time and never found. The first run
# found one: the Activity row's accessibility label, an interpolated literal that had been a
# key, "%@ %@", all along.
#
# A key with no translation is what this exists for. Nothing reports one at run time; the
# Korean window simply shows one English sentence. Entries the code no longer uses are listed
# but do not fail the check: they cost nothing at run time, and the list says what to tidy.
#
# The daemon must localize nothing. It runs from Contents/MacOS, so its Bundle.main is the app,
# and a `String(localized:)` there would write Korean into a log that ActivityLog parses as
# English.
#
# Every step prints what it read, for the reason scripts/invariants.sh gives: a check that
# passes by looking at nothing is the same lie as an idle daemon with dead listeners.
set -eu
setopt null_glob
cd "$(dirname "$0")/.."

table=bundle/ko.lproj/Localizable.strings
build=.build/l10n-check
keys="$PWD/$build/keys"

# A build of its own, so these flags never invalidate the release build's cache. Warm, it
# recompiles only what changed, and each file it recompiles rewrites its own .stringsdata.
swift build --scratch-path "$build" \
    -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$keys" \
    > /dev/null

found=$(mktemp)
translated=$(mktemp)
trap 'rm -f "$found" "$translated"' EXIT

files=0
for data in "$keys"/*.stringsdata; do
    source=$(plutil -extract source raw -o - "$data")
    # A warm build keeps the .stringsdata of a source that has since been deleted or renamed,
    # and its keys are no longer the code's.
    [ -f "$source" ] || continue
    files=$((files + 1))
    tables=$(plutil -extract tables raw -o - "$data")
    [ -z "$tables" ] && continue
    case "${source#$PWD/}" in
        Sources/micpeg/*|Sources/MicpegAudio/*)
            echo "FAIL: ${source#$PWD/} localizes a string; the daemon's output must stay English"
            exit 1 ;;
    esac
    if [ "$tables" != "Localizable" ]; then
        echo "FAIL: ${source#$PWD/} uses a table other than Localizable: $tables"
        exit 1
    fi
    # `raw` on an array prints its length.
    count=$(plutil -extract tables.Localizable raw -o - "$data")
    for (( i = 0; i < count; i++ )); do
        plutil -extract "tables.Localizable.$i.key" raw -o - "$data" >> "$found"
    done
done

# The table's keys, read through plutil the way the bundle reads them. xml1 puts each key of
# this flat dictionary on a line of its own and escapes three characters.
plutil -convert xml1 -o - "$table" \
    | sed -n 's|^[[:space:]]*<key>\(.*\)</key>$|\1|p' \
    | sed -e 's/&lt;/</g' -e 's/&gt;/>/g' -e 's/&amp;/\&/g' \
    > "$translated"

LC_ALL=C sort -u -o "$found" "$found"
LC_ALL=C sort -u -o "$translated" "$translated"
code_count=$(wc -l < "$found" | tr -d ' ')
table_count=$(wc -l < "$translated" | tr -d ' ')
echo "read: $code_count keys from the .stringsdata of $files source files in ${keys#$PWD/}"
echo "read: $table_count entries from $table"

if [ "$files" -eq 0 ] || [ "$code_count" -eq 0 ]; then
    echo "FAIL: the compiler reported no keys, so this check would pass by reading nothing"
    exit 1
fi

unused=$(LC_ALL=C comm -13 "$found" "$translated")
if [ -n "$unused" ]; then
    printf '%s\n' "$unused" | sed 's/^/  unused: /'
    echo "note: $(printf '%s\n' "$unused" | wc -l | tr -d ' ') entries in $table are no longer used"
fi

missing=$(LC_ALL=C comm -23 "$found" "$translated")
if [ -n "$missing" ]; then
    printf '%s\n' "$missing" | sed 's/^/  missing: /'
    echo "FAIL: $(printf '%s\n' "$missing" | wc -l | tr -d ' ') keys have no Korean translation and would be shown in English"
    exit 1
fi
echo "ok:   every key the app localizes has a Korean translation"
