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
# Passed straight through to the driver. A chunk whose files are longer than the default line cap needs this, or
# the agents review a truncated file and never know it.
EXTRA_ARGS=()
ONLY_GLOB=""           # the driver's --only, also needed here to count what is left
RETRY_WAIT=1800        # after a driver gives up on a dead CLI
CRASH_WAIT=300         # after any other unexpected exit
MAX_RESTARTS=48        # 24h of 30-minute retries, then stop
MAX_FINAL_PASSES=2     # re-runs once the driver reports completion with gaps

usage_line() {
    echo "usage: $0 --target DIR -o OUT_DIR [-t MIN] [--max-lines N] [--max-files N] [--only GLOB] MANIFEST"
}

# A flag that takes a value must be followed by one. Without the check a flag given last died with "unbound
# variable", and one followed by another flag swallowed that flag as its value.
need_arg() {
    if [[ $# -lt 2 || -z "$2" || "$2" == -* ]]; then
        echo "[supervise] $1 needs a value" >&2
        exit 1
    fi
}
# No leading zero: bash arithmetic would read 08 as a bad octal number.
need_int() {
    if [[ ! "$2" =~ ^[1-9][0-9]*$ ]]; then
        echo "[supervise] $1 must be a positive integer, got '$2'" >&2
        exit 1
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)     need_arg "$@"; TARGET="$2"; shift 2 ;;
        -o|--out)     need_arg "$@"; OUT="$2"; shift 2 ;;
        -t|--timeout) need_arg "$@"; need_int "$1" "$2"; TIMEOUT_MIN="$2"; shift 2 ;;
        --max-lines|--max-files)
                      need_arg "$@"; need_int "$1" "$2"; EXTRA_ARGS+=("$1" "$2"); shift 2 ;;
        --only)       need_arg "$@"; ONLY_GLOB="$2"; EXTRA_ARGS+=("$1" "$2"); shift 2 ;;
        # Said out loud: taken as a positional, as it used to be, --fix silently gave a report-only run.
        --fix)        echo "[supervise] --fix is not supported: the supervisor is report-only." >&2
                      echo "[supervise] An unattended run that restarts itself must not write into the target; use run_chunked_review.sh --fix by hand." >&2
                      exit 1 ;;
        -h|--help)    usage_line; exit 0 ;;
        # Only the options above are passed on to the driver. Anything else starting with '-' used to be taken
        # for the manifest.
        -*)           echo "[supervise] unknown option: $1" >&2; usage_line >&2; exit 1 ;;
        *)            MANIFEST="$1"; shift ;;
    esac
done

[[ -n "$TARGET" && -n "$OUT" && -n "$MANIFEST" ]] || {
    usage_line >&2
    exit 1
}

# Make the three paths absolute while the caller's directory is still current:
# the cd below would otherwise reinterpret a relative --target, -o or manifest
# against this script's directory. OUT_ARG keeps the caller's spelling, because
# a driver started by hand may carry it on its command line (see driver_running).
[[ -d "$TARGET" ]]   || { echo "[supervise] target not found: $TARGET" >&2; exit 1; }
[[ -f "$MANIFEST" ]] || { echo "[supervise] manifest not found: $MANIFEST" >&2; exit 1; }
OUT_ARG="$OUT"
TARGET="$(cd "$TARGET" && pwd)" || exit 1
mkdir -p "$OUT" || exit 1
OUT="$(cd "$OUT" && pwd)" || exit 1
MANIFEST="$(cd "$(dirname "$MANIFEST")" && pwd)/$(basename "$MANIFEST")" || exit 1

# chunk_is_reviewed and the rules behind it, shared with the driver so the two agree on what "done" means.
# Without this the function is simply undefined here, every call exits 127, and incomplete_chunks counts every
# chunk in the manifest as unfinished - which is what made this restart a twenty-chunk run that needed seven.
. "$SCRIPT_DIR/lib/transient.sh"

cd "$SCRIPT_DIR" || exit 1
LOG="$OUT/driver.log"
SUPLOG="$OUT/supervise.log"

say() { echo "[supervise] $(date '+%m-%d %H:%M') $*" | tee -a "$SUPLOG" >> "$LOG"; }

# Is a driver for this output directory alive?
#
# Git Bash's ps prints every script as a bare /usr/bin/bash, so the real command
# lines are read from /proc, one NUL-separated argument at a time. Only processes
# whose first argument is bash count: the tool shells that launched a driver stay
# alive as its parent and carry the same text inside a `bash -c "source ..."`
# string. A driver is one with run_chunked_review.sh as an argument, and its
# output directory is the value of its last -o or --out.
#
# That value is compared as a whole path, not as text inside the command line:
# matched as a substring, reviews/run1 also matched a driver for reviews/run10,
# and the supervisor waited for hours on someone else's run. A relative value is
# resolved against that process's own working directory, so a driver in another
# worktree with the same relative -o is not taken for ours, and the comparison
# is by file identity (-ef), so a short 8.3 spelling of a Windows path matches
# the long one. A directory that cannot be found is compared by its spelling.
driver_out_is_ours() {
    local raw="$1" cwd="$2" path=""
    # Absolute: /c/..., or a Windows C:/... or C:\... (a backslash in a bracket
    # expression does not match here, hence the separate test).
    if [[ "$raw" == /* ]] || [[ "$raw" == [A-Za-z]:* && ( "${raw:2:1}" == / || "${raw:2:1}" == '\' ) ]]; then
        path="$raw"
    elif [[ -n "$cwd" ]]; then
        path="$cwd/$raw"
    fi
    if [[ -n "$path" && -d "$path" ]]; then
        [[ "$path" -ef "$OUT" ]]
        return
    fi
    [[ "$raw" == "$OUT" || "$raw" == "$OUT_ARG" ]]
}

driver_running() {
    local p arg prev n is_driver out_raw cwd
    for p in /proc/[0-9]*; do
        [[ -r "$p/cmdline" ]] || continue
        n=0; prev=""; is_driver=0; out_raw=""
        while IFS= read -r -d '' arg; do
            n=$((n + 1))
            if (( n == 1 )); then
                [[ "${arg##*/}" == bash || "${arg##*/}" == bash.exe ]] || break
            elif [[ "$arg" == *shell-snapshots* ]]; then
                is_driver=0
                break
            elif (( is_driver == 0 )) && [[ "${arg##*/}" == run_chunked_review.sh ]]; then
                is_driver=1
            elif (( is_driver == 1 )) && [[ "$prev" == -o || "$prev" == --out ]]; then
                out_raw="$arg"
            fi
            prev="$arg"
        done 2>/dev/null < "$p/cmdline"
        (( is_driver == 1 )) && [[ -n "$out_raw" ]] || continue
        cwd="$(readlink "$p/cwd" 2>/dev/null)" || cwd=""
        driver_out_is_ours "$out_raw" "$cwd" && return 0
    done
    return 1
}

# Did the driver record this chunk as empty (no source file left after exclusion)? index.tsv is append-only, so
# the chunk's last row is the one that counts. Such a chunk never gets a directory or a report, and counting it
# as unfinished would keep the supervisor restarting a driver that has nothing to do.
chunk_is_empty() {
    [[ -f "$OUT/index.tsv" ]] || return 1
    awk -F'\t' -v id="$1" '$1 == id { s = $4 } END { exit (s == "empty") ? 0 : 1 }' "$OUT/index.tsv"
}

# Chunks in the manifest the driver would still run. chunk_is_reviewed is the driver's own test, from
# lib/transient.sh: this used to ask only whether a status block existed, which answered "all chunks complete" for
# chunks whose debate had an agent missing, so the supervisor never started the driver that would have redone them.
# Chunks outside --only are not counted (the driver never runs them), nor are chunks it recorded as empty.
incomplete_chunks() {
    local id n=0
    while IFS='|' read -r id _; do
        id="$(echo "$id" | xargs)"
        [[ -z "$id" || "$id" == \#* ]] && continue
        # shellcheck disable=SC2053
        [[ -n "$ONLY_GLOB" && "$id" != $ONLY_GLOB ]] && continue
        chunk_is_empty "$id" && continue
        chunk_is_reviewed "$OUT/$id" || n=$((n + 1))
    done < <(sed 's/\r$//; s/#.*//' "$MANIFEST")
    echo "$n"
}

if driver_running; then
    say "a driver for $OUT is already running - waiting for it to exit"
    while driver_running; do sleep 60; done
    say "that driver has exited"
fi

# What to do next is decided from the exit code of the driver THIS supervisor last ran, and from nothing else.
# It used to be read back from the end of driver.log, which is append-only: a supervisor started later acted on
# the ending of an earlier session, and slept half an hour before its first driver or used up a final pass on a
# run it had never made. driver_rc is empty until a driver has been run here, so the first one starts at once.
#
# Driver exit codes: 0 every chunk reviewed or empty, 1 bad arguments or manifest, 2 chunks failed, 3 the agent
# CLI did not recover, 4 another run holds a lock in this checkout, 130/143 stopped by a signal.
#
# This script's own exit code: 0 only when every chunk the driver would run is reviewed or empty. When it gives
# up: 1 the driver rejected its arguments or the manifest, 2 chunks still unreviewed after the extra passes, or
# the driver kept exiting unexpectedly, 3 the agent CLI never came back.
restarts=0
final_passes=0
driver_rc=""
exit_code=0
while :; do
    left=$(incomplete_chunks)

    if [[ "$left" -eq 0 ]]; then
        say "all chunks complete - nothing left to do"
        break
    fi

    case "$driver_rc" in
        "") ;;
        3)
            restarts=$((restarts + 1))
            if (( restarts > MAX_RESTARTS )); then
                say "agent CLI still unavailable after $MAX_RESTARTS restarts - stopping; $left chunk(s) left"
                exit_code=3
                break
            fi
            say "agent CLI unavailable - retrying in $((RETRY_WAIT / 60)) min (restart $restarts/$MAX_RESTARTS, $left chunk(s) left)"
            sleep "$RETRY_WAIT"
            ;;
        0|2)
            final_passes=$((final_passes + 1))
            if (( final_passes > MAX_FINAL_PASSES )); then
                say "driver finished but $left chunk(s) still failed after $MAX_FINAL_PASSES extra passes - stopping"
                exit_code=2
                break
            fi
            say "driver finished with $left incomplete chunk(s) - running another pass ($final_passes/$MAX_FINAL_PASSES)"
            ;;
        1)
            # Nothing a restart can change: the same arguments and manifest would be refused again.
            say "driver rejected its arguments or the manifest (exit 1) - not retrying; $left chunk(s) left; check with the driver's --list"
            exit_code=1
            break
            ;;
        *)
            restarts=$((restarts + 1))
            if (( restarts > MAX_RESTARTS )); then
                say "driver keeps exiting unexpectedly - stopping; $left chunk(s) left"
                exit_code=2
                break
            fi
            if [[ "$driver_rc" == "4" ]]; then
                say "another run holds a lock in this checkout (driver exit 4) - retrying in $((CRASH_WAIT / 60)) min (restart $restarts/$MAX_RESTARTS)"
            else
                say "driver exited unexpectedly (code $driver_rc) - restarting in $((CRASH_WAIT / 60)) min (restart $restarts/$MAX_RESTARTS)"
            fi
            sleep "$CRASH_WAIT"
            ;;
    esac

    # Never start a second driver on the same output: that is how two runs once
    # interleaved and produced a report built from the wrong package.
    if driver_running; then
        say "another driver appeared for $OUT - waiting for it instead of starting one"
        while driver_running; do sleep 60; done
        # That driver was not ours and its exit code is unknown: look at what is left and start afresh.
        driver_rc=""
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
    # ${a[@]+"${a[@]}"}: under set -u, bash before 4.4 (Git Bash ships 4.3) treats an empty array as unset and
    # aborts the script here when none of the pass-through options was given.
    "$DRIVER" --target "$TARGET" -t "$TIMEOUT_MIN" ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} --resume -o "$OUT" "$MANIFEST" >> "$LOG" 2>&1
    driver_rc=$?
    say "driver exited with code $driver_rc"
done
exit "$exit_code"
