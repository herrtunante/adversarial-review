#!/usr/bin/env bash
#
# supervise_review.sh - keep a chunked review going across outages that outlast
# the driver's own wait.
#
# run_chunked_review.sh waits up to two hours for a refused or unreachable agent
# CLI to come back, then exits so a dead quota cannot pin it forever. That is the
# right behaviour for the driver, but it means an overnight quota reset, or a
# laptop that slept through the wait, ends the review. This wrapper restarts the
# driver with --resume after such an exit, so the run carries on whenever the
# agents are available again.
#
# It also lets a new driver version be staged without touching the running one:
# bash reads a script incrementally, so editing run_chunked_review.sh while it
# runs can corrupt the run. Put the new version in run_chunked_review.next.sh;
# it is moved into place only in the gap after a driver exits.
#
# Usage (always detached, so a killed shell does not take it down):
#   nohup ./supervise_review.sh --target DIR -o OUT_DIR MANIFEST >/dev/null 2>&1 &

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRIVER="$SCRIPT_DIR/run_chunked_review.sh"
STAGED="$SCRIPT_DIR/run_chunked_review.next.sh"

TARGET=""
OUT=""
MANIFEST=""
TIMEOUT_MIN=15
RETRY_WAIT=1800        # after a driver gives up on a dead CLI
CRASH_WAIT=300         # after any other unexpected exit
MAX_RESTARTS=48        # 24h of 30-minute retries, then stop
MAX_FINAL_PASSES=2     # re-runs once the driver reports completion with gaps

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)     TARGET="$2"; shift 2 ;;
        -o|--out)     OUT="$2"; shift 2 ;;
        -t|--timeout) TIMEOUT_MIN="$2"; shift 2 ;;
        *)            MANIFEST="$1"; shift ;;
    esac
done

[[ -n "$TARGET" && -n "$OUT" && -n "$MANIFEST" ]] || {
    echo "usage: $0 --target DIR -o OUT_DIR MANIFEST" >&2
    exit 1
}

cd "$SCRIPT_DIR" || exit 1
mkdir -p "$OUT"
LOG="$OUT/driver.log"
SUPLOG="$OUT/supervise.log"

say() { echo "[supervise] $(date '+%m-%d %H:%M') $*" | tee -a "$SUPLOG" >> "$LOG"; }

# Is a driver for this output directory alive?
#
# Git Bash's ps prints every script as a bare /usr/bin/bash, so the real command
# lines are read from /proc. Only processes whose command line starts with
# "bash" count: the tool shells that launched a driver stay alive as its parent
# and carry the same text inside a `bash -c "source ..."` string.
driver_running() {
    local p c
    for p in /proc/[0-9]*; do
        c=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null) || continue
        case "$c" in
            *shell-snapshots*) continue ;;
            bash\ *run_chunked_review.sh*"$OUT"*) return 0 ;;
        esac
    done
    return 1
}

# Chunks in the manifest whose phase-4 report has no real status block.
incomplete_chunks() {
    local id n=0
    while IFS='|' read -r id _; do
        id="$(echo "$id" | xargs)"
        [[ -z "$id" || "$id" == \#* ]] && continue
        grep -q -- '---SYNTHESIS_STATUS---' "$OUT/$id/artifacts/iter1_4_synthesis.md" 2>/dev/null \
            || n=$((n + 1))
    done < <(sed 's/\r$//; s/#.*//' "$MANIFEST")
    echo "$n"
}

# What did the most recent driver run say at the end? Only lines after the last
# supervisor marker count, so an old run's ending is never mistaken for the
# latest one's.
last_run_tail() {
    sed 's/\x1b\[[0-9;]*m//g' "$LOG" 2>/dev/null \
      | awk '/^\[supervise\] .* starting driver/ { buf = "" } { buf = buf $0 "\n" } END { printf "%s", buf }'
}

if driver_running; then
    say "a driver for $OUT is already running - waiting for it to exit"
    while driver_running; do sleep 60; done
    say "that driver has exited"
fi

restarts=0
final_passes=0
while :; do
    tail_text="$(last_run_tail)"
    left=$(incomplete_chunks)

    if [[ "$left" -eq 0 ]]; then
        say "all chunks complete - nothing left to do"
        break
    fi

    if grep -q "did not recover" <<< "$tail_text"; then
        restarts=$((restarts + 1))
        if (( restarts > MAX_RESTARTS )); then
            say "agent CLI still unavailable after $MAX_RESTARTS restarts - stopping; $left chunk(s) left"
            break
        fi
        say "agent CLI unavailable - retrying in $((RETRY_WAIT / 60)) min (restart $restarts/$MAX_RESTARTS, $left chunk(s) left)"
        sleep "$RETRY_WAIT"
    elif grep -q "run complete" <<< "$tail_text"; then
        final_passes=$((final_passes + 1))
        if (( final_passes > MAX_FINAL_PASSES )); then
            say "driver finished but $left chunk(s) still failed after $MAX_FINAL_PASSES extra passes - stopping"
            break
        fi
        say "driver finished with $left incomplete chunk(s) - running another pass ($final_passes/$MAX_FINAL_PASSES)"
    elif [[ -n "$tail_text" ]]; then
        restarts=$((restarts + 1))
        if (( restarts > MAX_RESTARTS )); then
            say "driver keeps exiting unexpectedly - stopping; $left chunk(s) left"
            break
        fi
        say "driver exited unexpectedly - restarting in $((CRASH_WAIT / 60)) min"
        sleep "$CRASH_WAIT"
    fi

    # Never start a second driver on the same output: that is how two runs once
    # interleaved and produced a report built from the wrong package.
    if driver_running; then
        say "another driver appeared for $OUT - waiting for it instead of starting one"
        while driver_running; do sleep 60; done
        continue
    fi

    if [[ -f "$STAGED" ]]; then
        if bash -n "$STAGED"; then
            mv -f "$STAGED" "$DRIVER" && chmod +x "$DRIVER"
            say "installed the staged driver update"
        else
            say "staged driver update has a syntax error - keeping the current driver"
        fi
    fi

    say "starting driver ($left chunk(s) left)"
    "$DRIVER" --target "$TARGET" -t "$TIMEOUT_MIN" --resume -o "$OUT" "$MANIFEST" >> "$LOG" 2>&1
    say "driver exited with code $?"
done
