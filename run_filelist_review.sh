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
# directories or repos. A chunk that already has a full review is skipped, so
# running the same command again resumes. Always report-only (--no-fix).
#
# Simpler than the chunk driver: it retries a refused agent a few times but does
# not wait out a long quota reset, and it does not salvage a finished debate.

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
    sed -n '3,24p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-1}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)      TARGET="$2"; shift 2 ;;
        -o|--out)      OUT="$2"; shift 2 ;;
        -t|--timeout)  TIMEOUT_MIN="$2"; shift 2 ;;
        --max-lines)   SRC_LINES="$2"; shift 2 ;;
        --attempts)    MAX_ATTEMPTS="$2"; shift 2 ;;
        --retry-wait)  RETRY_WAIT="$2"; shift 2 ;;
        -h|--help)     usage 0 ;;
        *)             LISTS+=("$1"); shift ;;
    esac
done

[[ -n "$TARGET" && -n "$OUT" && ${#LISTS[@]} -gt 0 ]] || usage
[[ -d "$TARGET" ]] || { echo "no target directory: $TARGET" >&2; exit 1; }
TARGET="$(cd "$TARGET" && pwd)"

# Resolve the lists before the cd below, so relative paths mean what the caller typed.
ABS_LISTS=()
for list in "${LISTS[@]}"; do
    [[ -f "$list" ]] || { echo "no file list: $list" >&2; exit 1; }
    ABS_LISTS+=("$(cd "$(dirname "$list")" && pwd)/$(basename "$list")")
done
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

# chunk_is_reviewed: a synthesis block is not enough, an agent may have been refused.
. "$SCRIPT_DIR/lib/transient.sh"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# All state lives next to the script, whatever directory this was started from.
cd "$SCRIPT_DIR" || exit 1

failed=0
for list in "${ABS_LISTS[@]}"; do
    chunk="$(basename "$list" .files)"
    chunk_out="$OUT/$chunk"
    if chunk_is_reviewed "$chunk_out"; then
        log "$chunk: already reviewed, skipping"
        continue
    fi

    attempt=1
    done_ok=0
    while [[ $attempt -le $MAX_ATTEMPTS ]]; do
        # Never clear artifacts/ under a live review; see reset_all in adversarial_review.sh.
        if [[ -f .review.lock ]] && kill -0 "$(cat .review.lock 2>/dev/null)" 2>/dev/null; then
            log "another review holds .review.lock; aborting"
            exit 1
        fi
        rm -f artifacts/iter*.md logs/iter*.log 2>/dev/null || true
        "$REVIEW_SH" --reset-circuit > /dev/null 2>&1 || true

        log "$chunk: attempt $attempt of $MAX_ATTEMPTS"
        SOURCE_FILE_LIST="$list" MAX_SOURCE_LINES="$SRC_LINES" \
            "$REVIEW_SH" --no-fix -m 1 -t "$TIMEOUT_MIN" -v "$TARGET" \
            > "$OUT/$chunk.attempt$attempt.log" 2>&1
        rc=$?

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
        log "$chunk: no complete review (exit $rc), see $OUT/$chunk.attempt$attempt.log"
        attempt=$((attempt + 1))
        [[ $attempt -le $MAX_ATTEMPTS ]] && sleep "$RETRY_WAIT"
    done
    [[ $done_ok -eq 1 ]] || failed=$((failed + 1))
done

if "$SCRIPT_DIR/aggregate_review.sh" "$OUT" > "$OUT/aggregate.log" 2>&1; then
    log "report: $OUT/REPORT.md"
else
    log "aggregate failed, see $OUT/aggregate.log"
fi
log "finished ($failed chunk(s) without a complete review)"
[[ $failed -eq 0 ]]
