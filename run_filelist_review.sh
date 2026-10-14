#!/usr/bin/env bash
#
# run_filelist_review.sh - review a target in chunks that are each defined by a
# file list, one adversarial_review.sh run per list, archived in the layout
# aggregate_review.sh reads.
#
# Usage:
#   ./run_filelist_review.sh --target <project> -o <out_dir> [OPTIONS] <list.files>...
#
#   -t, --timeout MIN   per-agent timeout (default: 30)
#   --max-lines N       per-file line cap (default: 2500)
#   --attempts N        tries per chunk before moving on (default: 3)
#   --retry-wait SEC    pause between tries (default: 300)
#
# A list holds one path per line relative to --target; blank lines and
# # comments are ignored. The chunk id is the list's file name without .files.
#
# Use this instead of run_chunked_review.sh when a manifest cannot express the
# split: the code sits in one directory, or the files are scattered across
# directories or repos. A chunk that already has a full review of the same list
# and target is skipped, so running the same command again resumes. Always
# report-only (--no-fix).
#
# Simpler than the chunk driver: it retries a refused agent a few times but does
# not wait out a long quota reset, and it does not salvage a finished debate.
#
# Exit codes: 0 every chunk reviewed and the report built, 1 bad arguments, a
# chunk without a complete review, or the aggregate failed, 4 another driver,
# wrapper or review is working in this checkout, 130/143 stopped by INT/TERM.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REVIEW_SH="$SCRIPT_DIR/adversarial_review.sh"

TARGET=""
OUT=""
TIMEOUT_MIN=30
SRC_LINES=2500
MAX_ATTEMPTS=3
RETRY_WAIT=300
LISTS=()

usage() {
    sed -n '3,29p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-1}"
}

# A flag that takes a value must be followed by one. Without the check a flag given last died with "unbound
# variable", and one followed by another flag swallowed that flag as its value.
need_arg() {
    if [[ $# -lt 2 || -z "$2" || "$2" == -* ]]; then
        echo "$1 needs a value" >&2
        exit 1
    fi
}
# No leading zero: bash arithmetic would read 08 as a bad octal number.
need_int() {
    if [[ ! "$2" =~ ^[1-9][0-9]*$ ]]; then
        echo "$1 must be a positive integer, got '$2'" >&2
        exit 1
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)      need_arg "$@"; TARGET="$2"; shift 2 ;;
        -o|--out)      need_arg "$@"; OUT="$2"; shift 2 ;;
        -t|--timeout)  need_arg "$@"; need_int "$1" "$2"; TIMEOUT_MIN="$2"; shift 2 ;;
        --max-lines)   need_arg "$@"; need_int "$1" "$2"; SRC_LINES="$2"; shift 2 ;;
        --attempts)    need_arg "$@"; need_int "$1" "$2"; MAX_ATTEMPTS="$2"; shift 2 ;;
        --retry-wait)  need_arg "$@"; need_int "$1" "$2"; RETRY_WAIT="$2"; shift 2 ;;
        -h|--help)     usage 0 ;;
        # Without this arm an unknown or misspelt option was taken for a file list.
        -*)            echo "unknown option: $1" >&2; exit 1 ;;
        *)             LISTS+=("$1"); shift ;;
    esac
done

# A chunk's scope is its file list and nothing else. The review reads all of these from the environment, so a
# value exported in the caller's shell would be inherited by every chunk: CHANGED_ONLY is tested before the file
# list in the collector and would replace the list with the target's uncommitted files, still archived as a
# complete review. SOURCE_FILE_LIST and MAX_SOURCE_LINES are set on every review started below, report-only is
# passed as --no-fix, and with a file list the collector uses none of the other caps or the exclude regex.
unset CHANGED_ONLY FROM_PHASE NO_FIX SOURCE_FILE_LIST
unset MAX_SOURCE_FILES MAX_SOURCE_LINES MAX_SOURCE_SHELL_FILES MAX_SOURCE_SHELL_LINES MAX_SOURCE_EXCLUDE

[[ -n "$TARGET" && -n "$OUT" && ${#LISTS[@]} -gt 0 ]] || usage
[[ -d "$TARGET" ]] || { echo "no target directory: $TARGET" >&2; exit 1; }
TARGET="$(cd "$TARGET" && pwd)"

# Resolve the lists before the cd below, so relative paths mean what the caller typed.
ABS_LISTS=()
SEEN_IDS=" "
for list in "${LISTS[@]}"; do
    [[ -f "$list" ]] || { echo "no file list: $list" >&2; exit 1; }
    # The chunk id names a directory under the output that is deleted and rewritten, so it has to be
    # a plain name, and two lists with the same file name would overwrite each other.
    cid="$(basename "$list" .files)"
    [[ "$cid" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ && "$cid" != *..* ]] \
        || { echo "file list name gives an unusable chunk id '$cid': $list" >&2; exit 1; }
    [[ "$SEEN_IDS" != *" $cid "* ]] \
        || { echo "two file lists give the same chunk id '$cid': $list" >&2; exit 1; }
    SEEN_IDS+="$cid "
    ABS_LISTS+=("$(cd "$(dirname "$list")" && pwd)/$(basename "$list")")
done
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

# chunk_is_reviewed: a synthesis block is not enough, an agent may have been refused.
. "$SCRIPT_DIR/lib/transient.sh"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# Was the archived review in $1 of a different scope from the list $2 against --target? Prints what changed and
# returns 0 if so, returns 1 when it is the same. Skipping on chunk_is_reviewed alone reused the old report after
# the list was edited or --target changed, as long as -o and the list's file name stayed the same.
#
# Line 1 of artifacts/scope.stamp is the target the review ran against; its source hash on line 2 is deliberately
# not compared, so a change to the code does not redo finished chunks. files.list is the scope, compared byte for
# byte after dropping CRs. A chunk reviewed before scope stamps existed has none: it is reused on its file list,
# with a note that its target could not be checked.
archived_scope_change() {
    local chunk_out="$1" list="$2" stamp="$1/artifacts/scope.stamp" first=""
    if [[ -f "$stamp" ]]; then
        IFS= read -r first < "$stamp" || true
        first="${first%$'\r'}"
        if [[ "$first" != "$TARGET" ]]; then
            echo "it was a review of $first, --target is now $TARGET"
            return 0
        fi
    fi
    if [[ ! -f "$chunk_out/files.list" ]]; then
        echo "it has no files.list to compare with"
        return 0
    fi
    if [[ "$(tr -d '\r' < "$chunk_out/files.list")" != "$(tr -d '\r' < "$list")" ]]; then
        echo "its file list differs from $list"
        return 0
    fi
    [[ -f "$stamp" ]] || log "$(basename "$chunk_out"): reviewed before scope stamps existed - its file list matches, its target cannot be checked" >&2
    return 1
}

# All state lives in one directory, whatever directory this was started from: next to the script unless
# AR_STATE_DIR says otherwise (see adversarial_review.sh, which reads the same variable). Exported so every review
# started below uses it. The paths taken from the command line were made absolute above.
STATE_DIR="${AR_STATE_DIR:-$SCRIPT_DIR}"
if ! mkdir -p "$STATE_DIR" 2>/dev/null || ! cd "$STATE_DIR"; then
    echo "AR_STATE_DIR is not a usable directory: $STATE_DIR" >&2
    exit 1
fi
STATE_DIR="$(pwd)"
export AR_STATE_DIR="$STATE_DIR"

# --- driver lock ---------------------------------------------------------------
#
# The same lock run_chunked_review.sh takes, for the same reason: .review.lock
# belongs to adversarial_review.sh and is absent between two reviews, which is
# when artifacts/ is cleared and archived here. A directory, because mkdir
# either creates it or fails with nothing in between; the pid inside says who
# holds it. adversarial_review.sh refuses to start under a live lock unless
# AR_DRIVER_LOCK_PID says the holder started it.
DRIVER_LOCK="$STATE_DIR/.driver.lock"
DRIVER_LOCK_HELD=0
REVIEW_PID=""

acquire_driver_lock() {
    local holder="" tries=0 took_over=0
    while ! mkdir "$DRIVER_LOCK" 2>/dev/null; do
        holder="$(cat "$DRIVER_LOCK/pid" 2>/dev/null | tr -d '\r\n ' || true)"
        if [[ "$holder" =~ ^[0-9]+$ ]] && kill -0 "$holder" 2>/dev/null; then
            echo "another driver or wrapper is running in this checkout (pid $holder holds $DRIVER_LOCK)" >&2
            echo "wait for it to finish, or use a separate git worktree; nothing was touched" >&2
            echo "if no such run exists (see /proc, not ps), remove that directory and start again" >&2
            exit 4
        fi
        # No pid yet: the holder may be between its mkdir and its write.
        tries=$((tries + 1))
        if [[ -z "$holder" && $tries -le 5 ]]; then
            sleep 1
            continue
        fi
        if (( tries > 10 )); then
            echo "cannot take $DRIVER_LOCK - remove it by hand if no run is alive" >&2
            exit 4
        fi
        log "removing stale driver lock left by pid ${holder:-unknown}"
        rm -rf "$DRIVER_LOCK"
        took_over=1
    done
    # The directory can vanish between the mkdir and this write, when another
    # process was already removing what it took for a stale lock.
    if ! { echo $$ > "$DRIVER_LOCK/pid"; } 2>/dev/null; then
        echo "another driver removed $DRIVER_LOCK while it was being taken - nothing was touched" >&2
        exit 4
    fi
    DRIVER_LOCK_HELD=1
    # Two processes can both find the same dead pid and both remove the lock; the
    # second then deletes the first one's fresh lock. Look again after a moment
    # and stand down if the pid inside is no longer ours.
    if [[ $took_over -eq 1 ]]; then
        sleep 1
        holder="$(cat "$DRIVER_LOCK/pid" 2>/dev/null | tr -d '\r\n ' || true)"
        if [[ "$holder" != "$$" ]]; then
            DRIVER_LOCK_HELD=0
            echo "another driver took $DRIVER_LOCK at the same moment (pid ${holder:-unknown}) - nothing was touched" >&2
            exit 4
        fi
    fi
    export AR_DRIVER_LOCK_PID=$$
}

release_driver_lock() {
    [[ "$DRIVER_LOCK_HELD" == "1" ]] || return 0
    DRIVER_LOCK_HELD=0
    # Only our own: after a takeover race the directory may belong to someone else.
    if [[ "$(cat "$DRIVER_LOCK/pid" 2>/dev/null | tr -d '\r\n ' || true)" == "$$" ]]; then
        rm -rf "$DRIVER_LOCK"
    fi
    return 0
}

# adversarial_review.sh traps TERM itself, stops its agents and removes .review.lock.
on_signal() {
    local sig="$1" code="$2" n=0
    trap '' INT TERM
    log "received $sig - stopping the running review and releasing the driver lock"
    if [[ -n "$REVIEW_PID" ]] && kill -0 "$REVIEW_PID" 2>/dev/null; then
        kill -TERM "$REVIEW_PID" 2>/dev/null || true
        while kill -0 "$REVIEW_PID" 2>/dev/null && (( n < 20 )); do
            sleep 1
            n=$((n + 1))
        done
        kill -0 "$REVIEW_PID" 2>/dev/null && kill -KILL "$REVIEW_PID" 2>/dev/null
    fi
    exit "$code"
}

# Held from before the first clear of artifacts/ until after the aggregate.
trap release_driver_lock EXIT
trap 'on_signal INT 130' INT
trap 'on_signal TERM 143' TERM
acquire_driver_lock

failed=0
for list in "${ABS_LISTS[@]}"; do
    chunk="$(basename "$list" .files)"
    chunk_out="$OUT/$chunk"
    if chunk_is_reviewed "$chunk_out"; then
        if why="$(archived_scope_change "$chunk_out" "$list")"; then
            log "$chunk: the archived review is of another scope ($why) - reviewing it again"
        else
            log "$chunk: already reviewed, skipping"
            continue
        fi
    fi

    attempt=1
    done_ok=0
    while [[ $attempt -le $MAX_ATTEMPTS ]]; do
        # Never clear artifacts/ under a live review; see reset_all in adversarial_review.sh.
        if [[ -f .review.lock ]] && kill -0 "$(cat .review.lock 2>/dev/null)" 2>/dev/null; then
            log "another review holds .review.lock; aborting"
            exit 4
        fi
        # scope.stamp belongs to the artifacts it was written with: left behind, it would vouch for the next chunk's.
        # tracking.json goes too: a review that exits before it writes one would otherwise be archived with the
        # previous chunk's status.
        rm -f artifacts/iter*.md artifacts/scope.stamp logs/iter* tracking.json 2>/dev/null || true
        "$REVIEW_SH" --reset-circuit > /dev/null 2>&1 || true

        log "$chunk: attempt $attempt of $MAX_ATTEMPTS"
        # In the background and waited for: bash runs a trapped TERM only after a foreground command returns,
        # which would hold the stop back until the review was over.
        SOURCE_FILE_LIST="$list" MAX_SOURCE_LINES="$SRC_LINES" \
            "$REVIEW_SH" --no-fix -m 1 -t "$TIMEOUT_MIN" -v "$TARGET" \
            > "$OUT/$chunk.attempt$attempt.log" 2>&1 &
        REVIEW_PID=$!
        wait "$REVIEW_PID"
        rc=$?
        REVIEW_PID=""

        rm -rf "$chunk_out"; mkdir -p "$chunk_out"
        cp -r artifacts logs "$chunk_out/" 2>/dev/null || true
        cp tracking.json "$chunk_out/" 2>/dev/null || true
        # What the chunk covered; aggregate_review.sh also uses it to tell a chunk directory from any other.
        cp "$list" "$chunk_out/files.list" 2>/dev/null || true

        if chunk_is_reviewed "$chunk_out"; then
            log "$chunk: done (exit $rc)"
            done_ok=1
            break
        fi
        # Every listed path was missing, so there was nothing to review. Retrying cannot change that.
        if [[ "$(jq -r '.status // ""' "$chunk_out/tracking.json" 2>/dev/null | tr -d '\r')" == "empty_scope" ]]; then
            log "$chunk: nothing to review (empty scope), not retrying; check the paths in $list"
            break
        fi
        log "$chunk: no complete review (exit $rc), see $OUT/$chunk.attempt$attempt.log"
        attempt=$((attempt + 1))
        if [[ $attempt -le $MAX_ATTEMPTS ]]; then
            # Interruptible, for the same reason as the review above.
            sleep "$RETRY_WAIT" &
            wait $!
        fi
    done
    [[ $done_ok -eq 1 ]] || failed=$((failed + 1))
done

# A run whose report could not be built has not finished, even with every chunk reviewed.
agg_ok=1
if "$SCRIPT_DIR/aggregate_review.sh" "$OUT" > "$OUT/aggregate.log" 2>&1; then
    log "report: $OUT/REPORT.md"
else
    agg_ok=0
    log "aggregate failed, see $OUT/aggregate.log"
fi
log "finished ($failed chunk(s) without a complete review)"
[[ $failed -eq 0 && $agg_ok -eq 1 ]]
