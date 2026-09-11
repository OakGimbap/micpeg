#!/bin/zsh
# One-shot soak test: wait until a wall-clock deadline, then measure the running
# micpeg agent against a baseline captured when the timer was armed. Ends by
# itself; leaves only the result file.
#
#   ./scripts/leakcheck.sh <deadline_epoch> <base_kb> <base_at> <base_cpu> <base_log_lines>
#
# Arm it 24h out with:
#   L="gui/$(id -u)/com.micpeg.agent"
#   P=$(launchctl print "$L" | awk '/pid = /{print $3; exit}')
#   ./scripts/leakcheck.sh $(( $(date +%s) + 86400 )) \
#       "$(footprint -f bytes -p $P | awk '/phys_footprint:/{print int($2 / 1024)}')" \
#       "$(date '+%Y-%m-%d %H:%M:%S')" \
#       "$(ps -o time= -p $P | tr -d ' ')" \
#       "$(wc -l < ~/Library/Logs/micpeg.log | tr -d ' ')" &
DEADLINE=$1; BASE_KB=$2; BASE_AT=$3; BASE_CPU=$4; BASE_LOG=$5

REPO="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$REPO/leakcheck-result.txt"   # gitignored: contains local device names
LOGF="$HOME/Library/Logs/micpeg.log"

# Poll the wall clock rather than one long sleep: sleep(86400) does not advance while
# the machine is asleep, so it would fire late by however long the Mac napped.
while [ "$(date +%s)" -lt "$DEADLINE" ]; do sleep 300; done

L="gui/$(id -u)/com.micpeg.agent"
P=$(launchctl print "$L" 2>/dev/null | awk '/pid = /{print $3; exit}')

{
  echo "micpeg 24h soak check — $(date '+%Y-%m-%d %H:%M:%S')"
  echo "baseline: $BASE_AT / ${BASE_KB} KB / CPU ${BASE_CPU} / log ${BASE_LOG} lines"
  echo "=========================================================="
  if [ -z "$P" ]; then
    echo "FAIL: agent is not running. Check: launchctl print $L"
  else
    ps -o pid,rss,time,etime -p "$P"
    echo
    # `-f bytes`, then KB here. footprint's default format picks its own unit — `4769 KB`,
    # and `16 MB` once it passes about 9.8 MiB — and taking the number without the unit read
    # a 16 MB footprint as 16 KB, so the one check meant to catch a leak passed every leak big
    # enough to matter.
    KB=$(footprint -f bytes -p "$P" 2>/dev/null | awk '/phys_footprint:/{print int($2 / 1024)}')
    CPU=$(ps -o time= -p "$P" | tr -d ' ')
    RUNS=$(launchctl print "$L" 2>/dev/null | awk '/runs = /{print $3; exit}')
    # IDLEW is a LIFETIME COUNTER, not a per-sample rate. Reading it as a rate is what
    # produced a bogus FAIL on day 1: 58 wakeups over 24h is 2.4/hour, not 58/second.
    IDLEW=$(top -l 2 -s 5 -pid "$P" -stats pid,idlew 2>/dev/null \
            | awk -v p="$P" '$1==p{v=$2} END{if (v=="") v="?"; print v}')
    ELAPSED_H=$(( ($(date +%s) - (DEADLINE - 86400)) / 3600 ))
    [ "$ELAPSED_H" -lt 1 ] && ELAPSED_H=1
    LINES=$(wc -l < "$LOGF" | tr -d ' ')
    CPU_S=$(echo "$CPU" | awk -F: '{if (NF==3) print $1*3600+$2*60+$3; else print $1*60+$2}')

    echo "phys_footprint : ${KB} KB        (baseline ${BASE_KB}, pass < 8192)"
    echo "CPU TIME       : ${CPU}          (baseline ${BASE_CPU}, pass < 5s cumulative)"
    echo "idle wakeups   : ${IDLEW} lifetime  (~$(( IDLEW / ELAPSED_H ))/hour, informational)"
    echo "launchd runs   : ${RUNS}          (an increase means a crash restart)"
    echo "log lines      : ${LINES}         (baseline ${BASE_LOG})"
    echo
    echo "--- ARRIVED count per device (lifetime; watches for device flapping) ---"
    grep "ARRIVED" "$LOGF" | sed 's/.*ARRIVED //; s/ \[.*//' | sort | uniq -c | sort -rn | head -8
    echo
    # Correctness, not just cost: on 2026-09-10 the daemon reported PINNED while the
    # default input actually sat on the Bluetooth headset for ~1.5h. A single daily
    # sample is a weak net for that, but it costs nothing to look.
    #
    # Each field is read on its own and compared as a string. The first version split the
    # `micpeg status` line on ':' and matched the result as a regex, and a device name can hold
    # either: `Elgato Wave:1` became `Elgato Wave`, so every healthy run on the machine this was
    # written for reported FAIL — the same output as the incident it exists to catch.
    SF="$HOME/.config/micpeg/state.json"
    field() { python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$SF" "$1" 2>/dev/null; }
    STATE=$(field state); TARGET=$(field target); FILE_INPUT=$(field currentInput)
    # The daemon's own executable — its first `txt` mapping — rather than whatever `micpeg` is
    # on PATH: the app installs nothing there unless asked, and a missing CLI used to fail this
    # check for every device.
    CLI=$(lsof -p "$P" -a -d txt -Fn 2>/dev/null | awk '/^n/{print substr($0, 2); exit}')
    LIVE=""
    [ -n "$CLI" ] && LIVE=$("$CLI" status 2>/dev/null | sed -n 's/^default input: *//p' | sed -E 's/ \[[^]]*\]$//')
    echo "--- state consistency ---"
    echo "  state file    : $STATE | $TARGET | $FILE_INPUT"
    echo "  live default  : ${LIVE:-(could not be read)}   (from ${CLI:-no executable found} status)"
    MISMATCH=""
    if [ "$STATE" = "PINNED" ]; then
      if [ -z "$LIVE" ]; then
        MISMATCH="state=PINNED and the live default input could not be read"
      elif [ "$LIVE" != "$TARGET" ]; then
        MISMATCH="state=PINNED but live input differs from target"
      fi
    fi
    [ -n "$MISMATCH" ] && echo "  WARN: $MISMATCH" || echo "  consistent"
    echo
    V="PASS"
    [ -n "$MISMATCH" ] && V="FAIL ($MISMATCH)"
    [ -n "$KB" ] && [ "$KB" -ge 8192 ] && V="FAIL (memory ${KB}KB)"
    [ -n "$CPU_S" ] && [ "${CPU_S%.*}" -ge 5 ] && V="FAIL (CPU ${CPU})"
    echo "verdict: $V"
  fi
  echo
  echo "--- recent log ---"
  tail -6 "$LOGF"
} > "$OUT" 2>&1

for i in 1 2 3; do afplay /System/Library/Sounds/Glass.aiff; sleep 0.4; done
osascript -e "display notification \"micpeg 24h soak check complete\" with title \"micpeg\" subtitle \"$OUT\" sound name \"Glass\"" 2>/dev/null
