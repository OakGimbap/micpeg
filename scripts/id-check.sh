#!/bin/zsh
# No device identifier may be committed — USB serials, Bluetooth MAC addresses, display UIDs.
# CLAUDE.md states the rule; this is the enforcement, and CI runs it.
#
# The previous form of this check lived inline in ci.yml and matched exactly one shape:
# an upper-case hyphen-separated MAC with an :input/:output suffix. It let through the
# lower-case form, the colon-separated form, the USB serial and the display UUID — three of
# the four things the rule names. A guard weaker than the rule it enforces is the same shape
# of lie as an invariant that passes by looking at the wrong word.
#
# Method: strip the documented placeholders from every line first, then look at what is left.
# Matching and then excluding whole lines would let a real identifier hide on a line that also
# carries a placeholder.
set -u

cd "$(dirname "$0")/.."

# docs/ko/engineering-log.md:531 records why the serial placeholder is `X` and not hex: written
# out as AA-BB-CC-DD-EE-FF it tripped this very check on its own example and failed builds #1
# and #2. Both spellings are deliberate documentation, not leaks.
placeholders='AA-BB-CC-DD-EE-FF|AA:BB:CC:DD:EE:FF|XX-XX-XX-XX-XX-XX|XXXXXXXXXXXX'

# A Bluetooth device UID is the MAC, either case, either separator. The :input/:output suffix
# is not required — a bare MAC is just as much of a leak.
mac='[0-9A-Fa-f]{2}([-:][0-9A-Fa-f]{2}){5}'
# A USB device UID is AppleUSBAudioEngine:<vendor>:<model>:<n>:<serial>:<n,n>. Anchoring on the
# trailing <n,n> is what tells the serial field from the vendor and model names, which are
# public product strings and are used on purpose in config.example.json.
usb='AppleUSBAudioEngine:[^"]*:[A-Za-z0-9]{6,}:[0-9]+,[0-9]+'
# A display or aggregate device UID is a bare UUID.
uuid='[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}'
# A home directory path carries the account name. Scripts use $HOME.
home='/Users/[A-Za-z0-9._-]+'

fail=0

check() {
  local label="$1" pattern="$2"
  local hits
  hits="$(git grep -nIE "$pattern" -- . \
            | sed -E "s/($placeholders)//g" \
            | grep -E "$pattern" || true)"
  if [ -n "$hits" ]; then
    echo "FAIL: $label"
    print -r -- "$hits" | sed 's/^/      /'
    echo "::error::$label"
    fail=1
  else
    echo "ok:   no $label"
  fi
}

echo "searching: $(git ls-files | wc -l | tr -d ' ') tracked files"

check "Bluetooth MAC address"            "$mac"
check "USB device UID with a serial"     "$usb"
check "bare UUID (display/aggregate UID)" "$uuid"
check "home directory path with a username" "$home"

if git ls-files | grep -q 'leakcheck-result'; then
  echo "FAIL: soak-test output is committed; it contains local device names"
  echo "::error::soak-test output is committed"
  fail=1
else
  echo "ok:   no soak-test output committed"
fi

if git ls-files | grep -q '\.DS_Store'; then
  echo "FAIL: .DS_Store is committed"
  echo "::error::.DS_Store is committed"
  fail=1
else
  echo "ok:   no .DS_Store committed"
fi

exit $fail
