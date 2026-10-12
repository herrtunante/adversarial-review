#!/usr/bin/env bash
#
# run_chunked_review.sh - drive adversarial_review.sh over a large multi-module
# project one chunk at a time.
#
# adversarial_review.sh sends ONE flat source dump to the agents, capped at
# MAX_SOURCE_FILES per language and sorted by path. On a project with >1000
# source files that means the agents only ever see the alphabetically-first
# handful. This driver slices the project into reviewable chunks, runs a full
# 4-phase review per chunk, and archives each chunk's artifacts before the next
# chunk overwrites them.
#
# Per chunk it:
#   1. computes MAX_SOURCE_EXCLUDE so the dump contains only that chunk
#   2. resets artifacts + circuit breaker (both are global to this repo)
#   3. runs ./adversarial_review.sh with the chunk's module root as target
#   4. copies artifacts/, logs/ and tracking.json into <out>/<chunk_id>/
#
# Usage:
#   ./run_chunked_review.sh --target <project> [OPTIONS] <manifest>
#
# Manifest lines (pipe-delimited, '#' starts a comment):
#   chunk_id | module_root | include_path[,include_path...]
# module_root and include_path are relative to --target; include_path is
# relative to module_root. An empty include_path means the whole module.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REVIEW_SH="$SCRIPT_DIR/adversarial_review.sh"

TARGET_ROOT=""
OUT_DIR=""
TIMEOUT_MIN=20
MAX_ITERS=1
DRY_RUN=0
LIST_ONLY=0
ONLY_GLOB=""
RESUME=0
FIX=0
SRC_FILES=200
SRC_LINES=500

# Always dropped, whatever the chunk: build output, vendored deps, VCS, tests.
BASE_EXCLUDE='/target/|/node_modules/|/dist/|/build/|/[.]git/|/src/test/|/generated/|[.]min[.](js|css)$'

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
BOLD=$'\033[1m'
NC=$'\033[0m'
info() { echo "${BLUE}[chunk]${NC} $*"; }
ok()   { echo "${GREEN}[chunk]${NC} $*"; }
warn() { echo "${YELLOW}[chunk]${NC} $*"; }
err()  { echo "${RED}[chunk]${NC} $*" >&2; }

usage() {
    sed -n '3,25p' "$0" | sed 's/^# \{0,1\}//'
    echo ""
    echo "OPTIONS:"
    echo "  --target DIR       project being reviewed (required)"
    echo "  -o, --out DIR      output root (default: reviews/<name>-<timestamp>)"
    echo "  -t, --timeout N    minutes per agent call (default: 20)"
    echo "  -m, --max-iters N  iterations per chunk (default: 1)"
    echo "  --fix              allow phase 4 to modify the target (default: review only)"
    echo "  --only GLOB        run only chunks whose id matches GLOB"
    echo "  --resume           skip chunks that already completed in --out"
    echo "  --list             print the resolved chunk plan with sizes, run nothing"
    echo "  --dry-run          stub every agent call"
    echo "  --max-files N      per-language file cap handed to the collector (default: 200)"
    echo "  --max-lines N      per-file line cap handed to the collector (default: 500)"
}

MANIFEST=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)       TARGET_ROOT="$2"; shift 2 ;;
        -o|--out)       OUT_DIR="$2"; shift 2 ;;
        -t|--timeout)   TIMEOUT_MIN="$2"; shift 2 ;;
        -m|--max-iters) MAX_ITERS="$2"; shift 2 ;;
        --fix)          FIX=1; shift ;;
        --only)         ONLY_GLOB="$2"; shift 2 ;;
        --resume)       RESUME=1; shift ;;
        --list)         LIST_ONLY=1; shift ;;
        --dry-run)      DRY_RUN=1; shift ;;
        --max-files)    SRC_FILES="$2"; shift 2 ;;
        --max-lines)    SRC_LINES="$2"; shift 2 ;;
        -h|--help)      usage; exit 0 ;;
        -*)             err "unknown option: $1"; usage; exit 1 ;;
        *)              MANIFEST="$1"; shift ;;
    esac
done

[[ -n "$MANIFEST" ]]    || { err "manifest argument is required"; usage; exit 1; }
[[ -f "$MANIFEST" ]]    || { err "manifest not found: $MANIFEST"; exit 1; }
[[ -n "$TARGET_ROOT" ]] || { err "--target is required"; exit 1; }
[[ -d "$TARGET_ROOT" ]] || { err "target not found: $TARGET_ROOT"; exit 1; }
TARGET_ROOT="$(cd "$TARGET_ROOT" && pwd)"

if [[ -z "$OUT_DIR" ]]; then
    OUT_DIR="$SCRIPT_DIR/reviews/$(basename "$TARGET_ROOT")-$(date +%Y%m%d-%H%M%S)"
fi
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

# Escape a path fragment for use inside an extended-regex alternation.
re_escape() {
    printf '%s' "$1" | sed -e 's/[][\\.*^$(){}?+|]/\\&/g'
}

# Strip leading and trailing blanks.
trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# One include path in canonical form: surrounding blanks trimmed, empty and "."
# segments dropped, so no leading "./", no doubled or trailing slash. The result
# is empty when the path names the module root itself.
normalise_include() {
    local raw="$1" seg out="" segs=()
    raw="$(trim "$raw")"
    IFS='/' read -ra segs <<< "$raw" || true
    for seg in ${segs[@]+"${segs[@]}"}; do
        [[ -z "$seg" || "$seg" == "." ]] && continue
        out="${out:+$out/}$seg"
    done
    printf '%s' "$out"
}

# Turn a manifest include field into the global array `incs`, normalised and
# checked. An empty field or a "." entry gives the single entry "" (the whole
# module). Returns 1, with a message, for an include that leaves the module or
# is not a directory: build_exclude would silently reduce such a chunk to the
# loose files of whatever ancestor directories do exist.
resolve_includes() {
    local module_abs="$1" raw="$2" inc raw_incs=()
    incs=()
    IFS=',' read -ra raw_incs <<< "$raw" || true
    for inc in ${raw_incs[@]+"${raw_incs[@]}"}; do
        # A stray comma ("a,,b" or "a,") is not a request for the whole module.
        [[ -z "${inc//[[:space:]]/}" ]] && continue
        inc="$(normalise_include "$inc")"
        if [[ -z "$inc" ]]; then
            incs=("")
            return 0
        fi
        case "/$inc/" in
            */../*) err "include path must stay inside the module: $inc"; return 1 ;;
        esac
        if [[ ! -d "$module_abs/$inc" ]]; then
            err "include path is not a directory: $module_abs/$inc"
            return 1
        fi
        incs+=("$inc")
    done
    if [[ ${#incs[@]} -eq 0 ]]; then
        incs=("")
    fi
    return 0
}

# Build the exclusion regex that leaves only $includes visible under $module.
#
# filter_excluded uses `grep -Ev`, i.e. it can only subtract. To express "keep
# only these subtrees" we enumerate the complement: walk from the module root
# down each include path and, at every level, exclude the sibling directories
# that are not themselves on an include path.
#
# An include that is empty (or ".") means the whole module, so nothing is
# excluded beyond BASE_EXCLUDE. Includes are normalised first, so "src/main/",
# "./src/main" and "src//main" all mean "src/main". The module root is
# canonicalised with `cd && pwd`, exactly as adversarial_review.sh canonicalises
# its target: the regex is matched against the paths the collector's find
# prints, and a module of "." would otherwise never match any of them.
build_exclude() {
    local module_abs="$1"
    shift
    local includes=() keep=() parts=() segs=()
    local inc cur seg sub d is_kept parent

    module_abs="$(cd "$module_abs" 2>/dev/null && pwd)" || return 1

    for inc in "$@"; do
        inc="$(normalise_include "$inc")"
        if [[ -z "$inc" ]]; then
            printf '%s' "$BASE_EXCLUDE"
            return 0
        fi
        includes+=("$inc")
    done
    if [[ ${#includes[@]} -eq 0 ]]; then
        printf '%s' "$BASE_EXCLUDE"
        return 0
    fi

    for inc in "${includes[@]}"; do
        cur="$module_abs"
        keep+=("$cur")
        # read -a, not an unquoted expansion: a segment holding * or ? must not
        # be expanded against the current directory.
        IFS='/' read -ra segs <<< "$inc" || true
        for seg in "${segs[@]}"; do
            [[ -z "$seg" ]] && continue
            cur="$cur/$seg"
            keep+=("$cur")
        done
    done

    while IFS= read -r parent; do
        [[ -d "$parent" ]] || continue
        is_kept=0
        for inc in "${includes[@]}"; do
            [[ -n "$inc" ]] && [[ "$parent" == "$module_abs/$inc" ]] && is_kept=1 && break
        done
        [[ $is_kept -eq 1 ]] && continue

        while IFS= read -r sub; do
            [[ -z "$sub" ]] && continue
            is_kept=0
            for d in "${keep[@]}"; do
                [[ "$sub" == "$d" ]] && is_kept=1 && break
            done
            [[ $is_kept -eq 1 ]] && continue
            # Exclude the full absolute path, not the bare directory name: the
            # project itself may live under a directory called "collect", and a
            # bare "/collect/" alternative would then match every path in the
            # tree and empty the chunk.
            parts+=("$(re_escape "$sub")/")
        done < <(find "$parent" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort)
    done < <(printf '%s\n' "${keep[@]}" | sort -u)

    local joined=""
    if [[ ${#parts[@]} -gt 0 ]]; then
        joined="$(printf '%s\n' "${parts[@]}" | sort -u | paste -sd'|' -)"
    fi
    if [[ -n "$joined" ]]; then
        printf '%s|%s' "$BASE_EXCLUDE" "$joined"
    else
        printf '%s' "$BASE_EXCLUDE"
    fi
}

# Count/size what a chunk will actually feed the agents.
#
# One awk pass over the whole file list rather than head+wc per file: spawning
# two processes per source file costs minutes on Git Bash for a 1200-file tree.
chunk_stats() {
    local module_abs="$1"
    local exclude="$2"
    find "$module_abs" \
        \( -name '*.java' -o -name '*.py' -o -name '*.ts' -o -name '*.tsx' \
           -o -name '*.js' -o -name '*.jsx' -o -name '*.sh' \) \
        -type f ! -path '*/.*' 2>/dev/null \
      | grep -Ev "$exclude" \
      | head -n "$SRC_FILES" \
      | awk -v maxlines="$SRC_LINES" '
            # Read the file list on stdin and open each file ourselves, so the
            # whole chunk is measured by a single process regardless of how many
            # files it holds (xargs would split the list and print one line per
            # batch).
            {
                files++
                n = 0
                while ((getline line < $0) > 0) {
                    if (++n > maxlines) break
                    bytes += length(line) + 1
                }
                close($0)
            }
            END { printf "%d %d\n", files + 0, int(bytes / 1024) }
        '
}

# A chunk counts as done only if its phase-4 report carries a real status block.
# tracking.json alone is not enough: when an agent CLI refuses the call, every
# phase still "completes" and writes a one-line refusal into the artifact, and
# the run is recorded as report_only. Resuming on that evidence silently keeps
# the damaged chunk.
chunk_is_complete() { chunk_is_reviewed "$1"; }

# Is this artifact a failed agent call that is worth retrying later, rather than
# a review?
#
# Two shapes, and the patterns are deliberately split between them:
#
# The transient-failure rules live in lib/transient.sh: the supervisor decides the same question and the two
# answers have to agree.
. "$SCRIPT_DIR/lib/transient.sh"

# Did this chunk actually review the code it was scoped to?
#
# adversarial_review.sh keeps artifacts/ and logs/ in one shared directory, so a
# second review running at the same time silently replaces files mid-phase. The
# codex transcript echoes the prompt, which contains the "=== FILE: <path> ==="
# markers of the dump, so it is a direct record of what the agent was really
# shown. Any path in there that the chunk's own exclude regex would have dropped
# means the artifact came from a different run.
chunk_scope_is_intact() {
    local chunk_out="$1" module_abs="$2" exclude="$3"
    local log
    log="$(find "$chunk_out/logs" -name 'iter*_1_codex_review.codex.log' -type f 2>/dev/null | sort | tail -1)"
    [[ -n "$log" && -f "$log" ]] || return 0   # nothing to check against

    local n_total n_foreign
    # grep -c prints its own 0 and exits 1 when nothing matches, so `|| echo 0`
    # would yield two lines ("0\n0") and break the numeric test below.
    n_total=$(grep -cE '^=== FILE: ' "$log" 2>/dev/null || true)
    [[ "${n_total:-0}" -gt 0 ]] || return 0

    # The prefix goes in through the environment: as a sed replacement it broke
    # on a module path holding '#' or '&', and awk -v would unescape backslashes.
    n_foreign=$(grep -oE '^=== FILE: .* ===' "$log" 2>/dev/null \
                | sed -E 's/^=== FILE: (.*) ===$/\1/' \
                | PREFIX="$module_abs/" awk '{ print ENVIRON["PREFIX"] $0 }' \
                | grep -Ec "$exclude" || true)

    if [[ "${n_foreign:-0}" -gt 0 ]]; then
        err "scope check: $n_foreign of $n_total files in the prompt were outside this chunk"
        return 1
    fi
    return 0
}

# Are the six phase 1-3 artifacts all real reviews?
#
# A chunk costs seven agent calls and synthesis is the last of them, so it is the
# one most likely to meet an exhausted quota. When only that call failed, the six
# that succeeded are still valid and the chunk can be finished with --from-phase 4
# instead of being reviewed from scratch.
chunk_debate_is_intact() {
    local chunk_out="$1"
    local f
    for f in iter1_1_claude_review.md iter1_1_codex_review.md \
             iter1_2_claude_on_codex.md iter1_2_codex_on_claude.md \
             iter1_3_claude_meta.md iter1_3_codex_meta.md; do
        local path="$chunk_out/artifacts/$f"
        [[ -s "$path" ]] || return 1
        [[ $(wc -c < "$path") -ge 200 ]] || return 1
        artifact_is_transient_failure "$path" && return 1
    done
    return 0
}

# Block until the claude CLI answers a trivial prompt again, so a reset quota is
# detected rather than guessed at from the message text.
wait_for_claude() {
    local max_waits="${1:-24}" interval="${2:-300}" i=1
    while (( i <= max_waits )); do
        if echo "Reply with exactly: OK" | timeout 120s claude --print 2>&1 | grep -qi '^OK'; then
            ok "agent CLI is responding again"
            return 0
        fi
        warn "agent CLI still refusing (check $i/$max_waits), retrying in ${interval}s"
        sleep "$interval"
        i=$((i + 1))
    done
    return 1
}

# --- parse manifest ----------------------------------------------------------
#
# A chunk id becomes a directory name under the output root, and that directory
# (and .salvage-<id> beside it) is removed with rm -rf on a retry. So every id is
# checked here, before anything is created or deleted: an id of "../x" would
# otherwise delete outside the output directory, and two chunks sharing an id
# would overwrite or skip each other.
declare -a IDS=() MODULES=() INCLUDES=()
lineno=0
while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    line="${line%$'\r'}"
    line="${line%%#*}"
    [[ -z "${line//[[:space:]]/}" ]] && continue
    IFS='|' read -r cid mod inc <<< "$line"
    # Trimmed in the shell, not through xargs: xargs also strips quotes and
    # backslashes, so an id of 'a' reached the check below as a harmless 'ab'.
    cid="$(trim "$cid")"
    mod="$(trim "$mod")"
    inc="$(trim "${inc:-}")"
    if [[ -z "$cid" ]]; then
        err "$MANIFEST line $lineno: chunk id is empty: $line"
        exit 1
    fi
    if [[ ! "$cid" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ || "$cid" == *..* ]]; then
        err "$MANIFEST line $lineno: invalid chunk id '$cid'"
        err "an id may hold letters, digits, '.', '_' and '-' only, must not start with '.' or '-', and must not contain '..'"
        exit 1
    fi
    for seen in ${IDS[@]+"${IDS[@]}"}; do
        if [[ "$seen" == "$cid" ]]; then
            err "$MANIFEST line $lineno: duplicate chunk id '$cid'"
            exit 1
        fi
    done
    if [[ -z "$mod" ]]; then
        err "$MANIFEST line $lineno: chunk '$cid' has no module root (use '.' for the target itself)"
        exit 1
    fi
    IDS+=("$cid"); MODULES+=("$mod"); INCLUDES+=("$inc")
done < "$MANIFEST"

[[ ${#IDS[@]} -gt 0 ]] || { err "manifest contained no chunks"; exit 1; }

# --- list mode ---------------------------------------------------------------
if [[ "$LIST_ONLY" == "1" ]]; then
    printf "%-26s %6s %8s  %s\n" "CHUNK" "FILES" "SIZE" "SCOPE"
    total_f=0; total_kb=0
    for i in "${!IDS[@]}"; do
        module_abs="$TARGET_ROOT/${MODULES[$i]}"
        if [[ ! -d "$module_abs" ]]; then
            warn "${IDS[$i]}: module root missing: ${MODULES[$i]}"
            continue
        fi
        module_abs="$(cd "$module_abs" && pwd)"
        if ! resolve_includes "$module_abs" "${INCLUDES[$i]}"; then
            warn "${IDS[$i]}: not listed - fix its include path"
            continue
        fi
        exclude="$(build_exclude "$module_abs" "${incs[@]}")"
        read -r nf kb < <(chunk_stats "$module_abs" "$exclude")
        total_f=$((total_f + nf)); total_kb=$((total_kb + kb))
        printf "%-26s %6s %7sK  %s\n" "${IDS[$i]}" "$nf" "$kb" "${MODULES[$i]}/${INCLUDES[$i]}"
    done
    echo ""
    printf "%-26s %6s %7sK  %s chunks, ~%s agent calls\n" "TOTAL" "$total_f" "$total_kb" \
        "${#IDS[@]}" "$((${#IDS[@]} * 7 * MAX_ITERS))"
    exit 0
fi

# --- run ---------------------------------------------------------------------
info "target   : $TARGET_ROOT"
info "manifest : $MANIFEST"
info "output   : $OUT_DIR"
if [[ "$FIX" == "1" ]]; then
    info "mode     : FIX - phase 4 will modify the target in place"
else
    info "mode     : review only - nothing in the target is modified"
fi
echo ""

RUN_LOG="$OUT_DIR/run.log"
INDEX="$OUT_DIR/index.tsv"
[[ -f "$INDEX" ]] || printf "chunk_id\tfiles\tsize_kb\tstatus\titerations\tduration_s\n" > "$INDEX"

failed=0
selected=0
for i in "${!IDS[@]}"; do
    cid="${IDS[$i]}"
    if [[ -n "$ONLY_GLOB" ]]; then
        # shellcheck disable=SC2053
        [[ "$cid" == $ONLY_GLOB ]] || continue
    fi
    selected=$((selected + 1))

    chunk_out="$OUT_DIR/$cid"
    if [[ "$RESUME" == "1" ]] && chunk_is_complete "$chunk_out"; then
        info "$cid: already done, skipping"
        continue
    fi
    if [[ "$RESUME" == "1" && -d "$chunk_out" ]]; then
        warn "$cid: previous attempt incomplete, re-running"
        rm -rf "$chunk_out"
    fi

    module_abs="$TARGET_ROOT/${MODULES[$i]}"
    if [[ ! -d "$module_abs" ]]; then
        err "$cid: module root missing: ${MODULES[$i]}"
        failed=$((failed + 1))
        continue
    fi
    # Same canonical form the collector gives its target, so the exclude regex,
    # the size estimate and the scope check all see the paths find will print.
    module_abs="$(cd "$module_abs" && pwd)"
    if ! resolve_includes "$module_abs" "${INCLUDES[$i]}"; then
        err "$cid: bad include path, chunk not run"
        failed=$((failed + 1))
        continue
    fi
    exclude="$(build_exclude "$module_abs" "${incs[@]}")"
    read -r nf kb < <(chunk_stats "$module_abs" "$exclude")

    echo "${BOLD}=== [$((i + 1))/${#IDS[@]}] $cid  ($nf files, ${kb}K) ===${NC}"
    if [[ "$nf" -eq 0 ]]; then
        warn "$cid: chunk is empty after exclusion, skipping"
        printf "%s\t0\t0\tempty\t0\t0\n" "$cid" >> "$INDEX"
        continue
    fi

  attempt=1
  max_attempts=3
  resume_phase=1
  salvage_dir=""
  # A debate saved by an earlier run survives a restart of this driver (it lives
  # beside the chunk directory, not inside it). Pick it up so --resume finishes
  # the chunk with one synthesis call instead of repeating all seven.
  saved="$OUT_DIR/.salvage-$cid"
  if [[ "$RESUME" == "1" && -d "$saved" ]]      && [[ $(find "$saved" -maxdepth 1 -name 'iter1_[123]_*.md' -size +199c | wc -l) -eq 6 ]]; then
      salvage_dir="$saved"
      resume_phase=4
      info "$cid: found a saved debate from an earlier run - finishing with synthesis only"
  fi
  while true; do
    mkdir -p "$chunk_out"
    printf '%s\n' "$exclude" > "$chunk_out/exclude.regex"

    # artifacts/, logs/ and the circuit breaker are global to this repo, so clear
    # them per chunk. Without this a chunk can inherit the previous chunk's OPEN
    # breaker, or archive a log file that a previous chunk wrote.
    #
    # This is deliberately NOT `--reset`: reset_all() deletes .review.lock, which
    # is the only thing preventing a second review from interleaving with a live
    # one in the shared artifacts/ directory. Clear the state directly and leave
    # the lock alone - and refuse to start the chunk at all while someone holds
    # it, rather than trampling their run.
    if [[ -f "$SCRIPT_DIR/.review.lock" ]]; then
        holder="$(cat "$SCRIPT_DIR/.review.lock" 2>/dev/null || echo "")"
        if [[ -n "$holder" ]] && kill -0 "$holder" 2>/dev/null; then
            err "another review is running (pid $holder) - stopping before it corrupts this run"
            err "wait for it to finish, then resume with --resume"
            exit 4
        fi
        warn "removing stale lock left by pid ${holder:-unknown}"
        rm -f "$SCRIPT_DIR/.review.lock"
    fi
    rm -rf "${SCRIPT_DIR:?}/artifacts"/* 2>/dev/null || true
    rm -f "${SCRIPT_DIR:?}/logs"/iter*.log 2>/dev/null || true
    "$REVIEW_SH" --reset-circuit > /dev/null 2>&1 || true

    # A salvaged debate goes back into artifacts/ AFTER the clear above, so the
    # resumed run finds exactly the six files --from-phase 4 expects.
    if [[ "$resume_phase" -gt 1 && -n "$salvage_dir" && -d "$salvage_dir" ]]; then
        cp "$salvage_dir"/*.md "$SCRIPT_DIR/artifacts/" 2>/dev/null || true
        cp "$salvage_dir"/*.codex.log "$SCRIPT_DIR/logs/" 2>/dev/null || true
        info "$cid: restored saved debate, resuming at phase $resume_phase"
    fi

    review_args=()
    [[ "$FIX" == "1" ]] || review_args+=(--no-fix)
    [[ "$DRY_RUN" == "1" ]] && review_args+=(--dry-run)
    [[ "$resume_phase" -gt 1 ]] && review_args+=(--from-phase "$resume_phase")
    review_args+=(-m "$MAX_ITERS" -t "$TIMEOUT_MIN" -v "$module_abs")

    start=$(date +%s)
    set +e
    env MAX_SOURCE_FILES="$SRC_FILES" \
        MAX_SOURCE_LINES="$SRC_LINES" \
        MAX_SOURCE_SHELL_FILES="$SRC_FILES" \
        MAX_SOURCE_SHELL_LINES="$SRC_LINES" \
        MAX_SOURCE_EXCLUDE="$exclude" \
        "$REVIEW_SH" "${review_args[@]}" 2>&1 | tee "$chunk_out/console.log"
    rc=${PIPESTATUS[0]}
    set -e
    dur=$(($(date +%s) - start))

    # Archive everything this chunk produced before the next chunk wipes it.
    [[ -d "$SCRIPT_DIR/artifacts" ]] && cp -r "$SCRIPT_DIR/artifacts" "$chunk_out/" 2>/dev/null || true
    [[ -d "$SCRIPT_DIR/logs" ]] && cp -r "$SCRIPT_DIR/logs" "$chunk_out/" 2>/dev/null || true
    [[ -f "$SCRIPT_DIR/tracking.json" ]] && cp "$SCRIPT_DIR/tracking.json" "$chunk_out/" || true

    # A quota refusal is not a review. Throw the chunk away, wait for the CLI to
    # answer again, and redo it - otherwise the loop races through every
    # remaining chunk producing empty artifacts that look like clean reviews.
    if chunk_hit_transient_failure "$chunk_out" || ! chunk_scope_is_intact "$chunk_out" "$module_abs" "$exclude"; then
        # Keep the debate if it survived and only synthesis was refused; that is
        # six of the chunk's seven agent calls.
        resume_phase=1
        salvage_dir=""
        if chunk_scope_is_intact "$chunk_out" "$module_abs" "$exclude" \
           && chunk_debate_is_intact "$chunk_out"; then
            salvage_dir="$OUT_DIR/.salvage-$cid"
            rm -rf "$salvage_dir"; mkdir -p "$salvage_dir"
            cp "$chunk_out"/artifacts/iter1_[123]_*.md "$salvage_dir/" 2>/dev/null || true
            cp "$chunk_out"/logs/iter1_[123]_*.codex.log "$salvage_dir/" 2>/dev/null || true
            resume_phase=4
            warn "$cid: debate intact, only synthesis failed - keeping 6 of 7 calls"
        fi
        warn "$cid: attempt $attempt/$max_attempts hit a quota or network failure, or was scope-contaminated - discarding"
        rm -rf "$chunk_out"
        if (( attempt >= max_attempts )); then
            err "$cid: still failing after $max_attempts attempts, giving up on this chunk"
            printf "%s\t%s\t%s\ttransient_failure\t0\t0\n" "$cid" "$nf" "$kb" >> "$INDEX"
            failed=$((failed + 1))
            break
        fi
        if ! wait_for_claude; then
            err "agent CLI did not recover - stopping the run; resume with --resume"
            exit 3
        fi
        attempt=$((attempt + 1))
        continue
    fi

    status="unknown"; iters=0
    if [[ -f "$chunk_out/tracking.json" ]]; then
        status=$(jq -r '.status // "unknown"' "$chunk_out/tracking.json" 2>/dev/null || echo unknown)
        iters=$(jq -r '.iteration // 0' "$chunk_out/tracking.json" 2>/dev/null || echo 0)
    fi
    if [[ $rc -ne 0 ]]; then
        status="${status}(rc=$rc)"
        failed=$((failed + 1))
    elif [[ "$DRY_RUN" != "1" ]] && ! chunk_is_complete "$chunk_out"; then
        # The review exited 0 but left nothing --resume would accept (an agent
        # that produced no final message, say). That is a failed chunk, and the
        # exit code has to say so. A dry run only writes stubs, so it is exempt.
        warn "$cid: review exited 0 but the chunk does not count as reviewed"
        failed=$((failed + 1))
    fi

    printf "%s\t%s\t%s\t%s\t%s\t%s\n" "$cid" "$nf" "$kb" "$status" "$iters" "$dur" >> "$INDEX"
    # Drop any saved debate for this chunk, including one left by an earlier
    # driver run that this run did not use.
    rm -rf "$OUT_DIR/.salvage-$cid"
    echo "[$cid] $status in ${dur}s" >> "$RUN_LOG"
    ok "$cid -> $status (${dur}s)"
    echo ""
    break
  done
done

echo ""
ok "run complete: $OUT_DIR"
column -t -s "$(printf '\t')" "$INDEX" 2>/dev/null || cat "$INDEX"
if [[ -n "$ONLY_GLOB" && $selected -eq 0 ]]; then
    warn "no chunk id matches --only '$ONLY_GLOB' - nothing was run"
fi
# Exit codes: 0 every selected chunk is reviewed (or was recorded as empty),
# 1 bad arguments or manifest, 2 one or more chunks failed, 3 the agent CLI did
# not recover, 4 another review holds the lock. supervise_review.sh still reads
# the "run complete" line above, so that line is printed in both cases.
if [[ $failed -gt 0 ]]; then
    warn "$failed chunk(s) failed - rerun with --resume to redo them"
    exit 2
fi
exit 0
