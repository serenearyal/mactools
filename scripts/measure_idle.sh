#!/bin/bash
#
# What MacTools costs while it sits there.
#
# For each state the app can be in it launches ONE extra instance of the
# installed Release bundle in the background, lets it settle, watches it with
# `top` for a minute and prints the mean CPU, the idle wakeups per second, the
# power score and the memory footprint. It ends with a pass/fail table against
# the budgets in README.md.
#
# Rules it obeys, because it runs on the machine somebody is working on:
#   * `open -g -n --args --no-activate` - it never takes the front, and every
#     window it opens is ordered in without activation.
#   * it only ever kills the pid it started itself. The pid is the one that
#     appeared between the two `pgrep` calls around the launch, and it is
#     checked for this run's tag in its command line before the signal, so the
#     user's own MacTools (same bundle, same name) is never touched.
#
# The popover states host the popover's own view tree in a borderless window
# off the corner of the screen (`--popover-offscreen`): a real NSPopover never
# appears for an app that is not active. Same view, same observation, same
# sampling demand, so the number is the popover's.
#
# Usage: scripts/measure_idle.sh [output-file]
#   ONLY="popover"   run only the states whose name contains that text
#   EXTRA="--power-rules off"   extra arguments for every instance it launches
set -uo pipefail

APP="/Applications/MacTools.app"
OUT="${1:-build/measure/results.txt}"
SETTLE="${SETTLE:-10}"
# 13 samples 5 s apart, the first one dropped: one minute of measurement.
SAMPLES="${SAMPLES:-13}"
INTERVAL=5
TAG="measure-$$-$(date +%s)"
ONLY="${ONLY:-}"
EXTRA="${EXTRA:-}"

cd "$(dirname "$0")/.." || exit 1
mkdir -p "$(dirname "$OUT")"

if [ ! -d "$APP" ]; then
    echo "error: $APP is missing; run 'make install CONFIG=Release' first" >&2
    exit 1
fi

# state name | budget in % CPU | launch arguments
#
# `--menu-bar-label on` is what makes the table repeatable. Whether the menu
# bar has room for one more status item depends on what else is in it at that
# second, and an item the system parks behind the notch draws for nobody, so
# the app stops sampling for it - which is the point of the "icon only" row
# below, and would silently flatter every other row.
STATES=(
    "closed|0.5|--menu-bar-label on"
    "closed icon only|0.1|--menu-bar-label off"
    "popover dashboard|2.0|--menu-bar-label on --popover-offscreen --popover-section dashboard"
    "popover tools|2.0|--menu-bar-label on --popover-offscreen --popover-section tools"
    "window overview|3.0|--menu-bar-label on --show-window --window-front --tab overview"
    "window processes|4.0|--menu-bar-label on --show-window --window-front --tab processes"
    "window windows|1.0|--menu-bar-label on --show-window --window-front --tab windows"
)

RESULTS=()

measure_state() {
    local name="$1" budget="$2" args="$3"

    local before after pid
    before="$(pgrep -x MacTools | sort)"
    # shellcheck disable=SC2086
    open -g -n "$APP" --args --no-activate --measure-run "$TAG" $args $EXTRA
    sleep 3
    after="$(pgrep -x MacTools | sort)"
    pid="$(comm -13 <(echo "$before") <(echo "$after"))"

    if [ -z "$pid" ] || [ "$(echo "$pid" | wc -l | tr -d ' ')" != "1" ]; then
        echo "  could not tell which pid is mine (got: ${pid//$'\n'/ }); skipping"
        RESULTS+=("$name|-|-|-|-|-|$budget|SKIPPED")
        return
    fi
    # The safety net: this pid must carry this run's tag.
    if ! ps -p "$pid" -o command= | grep -q -- "$TAG"; then
        echo "  pid $pid does not carry the tag of this run; leaving it alone"
        RESULTS+=("$name|-|-|-|-|-|$budget|SKIPPED")
        return
    fi

    echo "  pid $pid, settling ${SETTLE}s, then $((( SAMPLES - 1 ) * INTERVAL))s of top"
    sleep "$SETTLE"

    local raw
    raw="$(top -l "$SAMPLES" -s "$INTERVAL" -pid "$pid" -stats pid,cpu,idlew,power,mem 2>/dev/null \
        | grep -E "^${pid}[[:space:]]" )"

    kill "$pid" 2>/dev/null
    for _ in 1 2 3 4 5; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 1
    done
    kill -9 "$pid" 2>/dev/null

    local line_count
    line_count="$(echo "$raw" | grep -c . )"
    if [ "$line_count" -lt 2 ]; then
        echo "  top gave nothing back"
        RESULTS+=("$name|-|-|-|-|-|$budget|SKIPPED")
        return
    fi

    # The first sample of `top` covers the time since the process started, so
    # it is dropped; the rest are the deltas of one interval each.
    local stats
    # `top` reports IDLEW as a counter since the process started, so the rate
    # is the growth over the window divided by the seconds in it. CPU and
    # POWER are per-sample values and are averaged.
    stats="$(echo "$raw" | tail -n +2 | awk -v interval="$INTERVAL" '
        function tobytes(v,   u) {
            u = substr(v, length(v), 1);
            if (u == "K") return (v + 0) / 1024;
            if (u == "M") return v + 0;
            if (u == "G") return (v + 0) * 1024;
            return (v + 0) / 1048576;
        }
        {
            for (i = 2; i <= 5; i++) gsub(/[+-]$/, "", $i);
            cpu = $2 + 0; if (cpu > maxcpu) maxcpu = cpu; sumcpu += cpu;
            idlew = $3 + 0; if (n == 0) first = idlew; last = idlew;
            sumpower += $4 + 0;
            mem = tobytes($5); summem += mem;
            n++;
        }
        END {
            if (n == 0) { print "- - - - -"; exit }
            seconds = (n - 1) * interval; if (seconds <= 0) seconds = interval;
            printf "%.2f %.2f %.2f %.2f %.0f\n",
                sumcpu / n, maxcpu, (last - first) / seconds, sumpower / n, summem / n;
        }')"

    local mean max idlew power mem verdict
    read -r mean max idlew power mem <<<"$stats"
    verdict="PASS"
    awk -v a="$mean" -v b="$budget" 'BEGIN { exit !(a > b) }' && verdict="FAIL"
    echo "  cpu mean ${mean}% max ${max}%, idle wakeups ${idlew}/s, power ${power}, memory ${mem} MB"
    RESULTS+=("$name|$mean|$max|$idlew|$power|$mem|$budget|$verdict")
}

{
    echo "MacTools efficiency measurement"
    echo "date:   $(date '+%Y-%m-%d %H:%M:%S')"
    echo "bundle: $APP ($(/usr/bin/defaults read "$APP/Contents/Info.plist" CFBundleVersion 2>/dev/null || echo '?'))"
    echo "build:  $(/usr/bin/codesign -d --verbose=2 "$APP" 2>&1 | grep -i '^Identifier' || true)"
    echo "host:   $(sysctl -n machdep.cpu.brand_string), macOS $(sw_vers -productVersion)"
    echo "method: settle ${SETTLE}s, then top -l $SAMPLES -s $INTERVAL, first sample dropped"
    echo "extra:  ${EXTRA:-none}${ONLY:+ (only \"$ONLY\")}"
    echo "power:  $(pmset -g batt | head -1 | sed 's/Now drawing from //'), low power mode $(pmset -g | awk '/lowpowermode/ { print $2 }')"
    echo ""
} >"$OUT"

for state in "${STATES[@]}"; do
    IFS='|' read -r name budget args <<<"$state"
    if [ -n "$ONLY" ] && [[ "$name" != *"$ONLY"* ]]; then continue; fi
    echo "== $name"
    measure_state "$name" "$budget" "$args"
done

if [ ${#RESULTS[@]} -eq 0 ]; then
    echo "no state matched ONLY=$ONLY" >&2
    exit 1
fi

{
    printf "%-18s %8s %8s %10s %7s %9s %8s  %s\n" \
        "state" "cpu mean" "cpu max" "idlew/s" "power" "mem MB" "budget" "verdict"
    printf -- "%s\n" "---------------------------------------------------------------------------------------"
    for row in "${RESULTS[@]}"; do
        IFS='|' read -r name mean max idlew power mem budget verdict <<<"$row"
        printf "%-18s %8s %8s %10s %7s %9s %8s  %s\n" \
            "$name" "$mean" "$max" "$idlew" "$power" "$mem" "$budget" "$verdict"
    done
    echo ""
    echo "budgets: cpu mean over 60 s; idle wakeups target < 15/s in the closed state."
} | tee -a "$OUT"

echo ""
echo "written to $OUT"

for row in "${RESULTS[@]}"; do
    case "$row" in
        *"|FAIL") exit 1 ;;
    esac
done
exit 0
