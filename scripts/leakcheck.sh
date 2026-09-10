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
#       "$(footprint -p $P | awk '/phys_footprint:/{print $2}')" \
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
    KB=$(footprint -p "$P" 2>/dev/null | awk '/phys_footprint:/{print $2}')
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
    ST=$(python3 -c "import json;d=json.load(open('$HOME/.config/micpeg/state.json'));print(d['state'],'|',d['target'],'|',d['currentInput'])" 2>/dev/null)
    LIVE=$(micpeg status 2>/dev/null | awk -F': *' '/^default input/{print $2}' | sed 's/ \[.*//')
    echo "--- state consistency ---"
    echo "  state file    : $ST"
    echo "  live default  : $LIVE"
    MISMATCH=""
    case "$ST" in
      PINNED*) echo "$ST" | grep -q "| *$LIVE *\$" || MISMATCH="state=PINNED but live input differs from target" ;;
    esac
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
