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

# Where the reviews keep their state (artifacts/, logs/, tracking.json, the
# locks) and where the default output goes: next to the scripts unless
# AR_STATE_DIR says otherwise. See adversarial_review.sh, which reads the same
# variable; it is exported so every review started below uses this directory.
# Made absolute here but only created under "--- run ---": --list creates nothing.
#
# Absolute means a leading / or \ (POSIX, UNC), or a Windows drive letter
# (C:/... or C:\...). Testing only for a leading /, as this did, read the
# C:/Users/... path the plugin's skill hands over on Windows as relative: the
# state went to "$PWD/C:/Users/...", inside the plugin's own directory, and
# every chunk failed. The same rule as the -o check in supervise_review.sh.
STATE_DIR="${AR_STATE_DIR:-$SCRIPT_DIR}"
if [[ "$STATE_DIR" != /* && "$STATE_DIR" != \\* ]] \
   && ! [[ "$STATE_DIR" == [A-Za-z]:* && ( "${STATE_DIR:2:1}" == / || "${STATE_DIR:2:1}" == '\' ) ]]; then
    STATE_DIR="$PWD/$STATE_DIR"
fi
[[ -d "$STATE_DIR" ]] && STATE_DIR="$(cd "$STATE_DIR" && pwd)"
export AR_STATE_DIR="$STATE_DIR"

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
# The directory names are matched below the module root only (see base_exclude):
# matched anywhere in the absolute path, a module that itself lives under a
# directory called "build" or "target" lost every one of its files.
BASE_EXCLUDE_DIRS='target|node_modules|dist|build|[.]git|src/test|generated'
BASE_EXCLUDE_FILES='[.]min[.](js|css)$'

# State next to the scripts is global, so only one driver or wrapper may work in
# this checkout at a time. See acquire_driver_lock.
DRIVER_LOCK="$STATE_DIR/.driver.lock"
DRIVER_LOCK_HELD=0

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
    echo "  --resume           skip chunks already reviewed in --out with the same scope"
    echo "  --list             print the resolved chunk plan with sizes, run nothing"
    echo "  --dry-run          stub every agent call"
    echo "  --max-files N      per-language file cap handed to the collector (default: 200)"
    echo "  --max-lines N      per-file line cap handed to the collector (default: 500)"
}

# A flag that takes a value must be followed by one. Without the check a flag
# given last died with "unbound variable", and one followed by another flag
# swallowed that flag as its value.
need_arg() {
    if [[ $# -lt 2 || -z "$2" || "$2" == -* ]]; then
        err "$1 needs a value"
        exit 1
    fi
}
# No leading zero: bash arithmetic would read 08 as a bad octal number.
need_int() {
    if [[ ! "$2" =~ ^[1-9][0-9]*$ ]]; then
        err "$1 must be a positive integer, got '$2'"
        exit 1
    fi
}

MANIFEST=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)       need_arg "$@"; TARGET_ROOT="$2"; shift 2 ;;
        -o|--out)       need_arg "$@"; OUT_DIR="$2"; shift 2 ;;
        -t|--timeout)   need_arg "$@"; need_int "$1" "$2"; TIMEOUT_MIN="$2"; shift 2 ;;
        -m|--max-iters) need_arg "$@"; need_int "$1" "$2"; MAX_ITERS="$2"; shift 2 ;;
        --fix)          FIX=1; shift ;;
        --only)         need_arg "$@"; ONLY_GLOB="$2"; shift 2 ;;
        --resume)       RESUME=1; shift ;;
        --list)         LIST_ONLY=1; shift ;;
        --dry-run)      DRY_RUN=1; shift ;;
        --max-files)    need_arg "$@"; need_int "$1" "$2"; SRC_FILES="$2"; shift 2 ;;
        --max-lines)    need_arg "$@"; need_int "$1" "$2"; SRC_LINES="$2"; shift 2 ;;
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

# A chunk's scope comes from the manifest and the options above, and from
# nothing else. The review reads all of these from the environment, so a value
# exported in the caller's shell would be inherited by every chunk: CHANGED_ONLY
# is tested before anything else in the collector and would replace the chunk
# with the target's uncommitted files, still archived as a complete review.
# FROM_PHASE and the fix mode are passed as flags (--from-phase, --fix/--no-fix);
# the MAX_SOURCE_* values are set on every review started below.
unset CHANGED_ONLY SOURCE_FILE_LIST FROM_PHASE NO_FIX
unset MAX_SOURCE_FILES MAX_SOURCE_LINES MAX_SOURCE_SHELL_FILES MAX_SOURCE_SHELL_LINES MAX_SOURCE_EXCLUDE

# The output directory is only named here. It is created after the --list block:
# planning must not leave an empty reviews/<name>-<timestamp>/ behind every time.
if [[ -z "$OUT_DIR" ]]; then
    OUT_DIR="$STATE_DIR/reviews/$(basename "$TARGET_ROOT")-$(date +%Y%m%d-%H%M%S)"
fi

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

# The always-on part of a chunk's exclusion regex, for one canonical module root.
# Anchored at the module root, so only directories BELOW it are tested: the
# regex is matched against absolute paths, and an unanchored "/build/" would
# also match the directories the module itself sits in.
base_exclude() {
    printf '^%s/(.*/)?(%s)/|%s' "$(re_escape "$1")" "$BASE_EXCLUDE_DIRS" "$BASE_EXCLUDE_FILES"
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
    local inc cur seg sub d is_kept parent base

    module_abs="$(cd "$module_abs" 2>/dev/null && pwd)" || return 1
    base="$(base_exclude "$module_abs")"

    for inc in "$@"; do
        inc="$(normalise_include "$inc")"
        if [[ -z "$inc" ]]; then
            printf '%s' "$base"
            return 0
        fi
        includes+=("$inc")
    done
    if [[ ${#includes[@]} -eq 0 ]]; then
        printf '%s' "$base"
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
        printf '%s|%s' "$base" "$joined"
    else
        printf '%s' "$base"
    fi
}

# Count/size what a chunk will actually feed the agents.
#
# One awk pass over the whole file list rather than head+wc per file: spawning
# two processes per source file costs minutes on Git Bash for a 1200-file tree.
#
# The selection has to be the collector's own (collect_source_code in
# adversarial_review.sh), or --list plans a different review from the one that
# runs: four separate walks (Java, Python, TS/JS, shell), each with its own find
# filters, each sorted by path and only then cut to its cap. The run below hands
# the collector SRC_FILES as the cap for all four and SRC_LINES as the line cap
# for all four, so the same two numbers are used here. Counting one unsorted
# combined list against a single cap, as this used to, could report a quarter of
# the real dump and a different set of files.
#
# The find filters are tested against the path relative to the module, not the
# absolute one: with the absolute path a module under a dot directory (a
# worktree in ~/.claude/..., say) or under a directory called "target" or
# "build" listed nothing at all. The exclude regex still sees absolute paths.
#
# One language's files, selected as the collector selects them. Arguments after
# the first four are the find tests for that language.
chunk_lang_files() {
    local module_abs="$1" exclude="$2" label="$3" cap="$4"
    shift 4
    local list n
    list="$( (cd "$module_abs" && find . "$@" -type f ! -path '*/.?*' 2>/dev/null) \
             | sed 's|^\./||' \
             | PREFIX="$module_abs/" awk '{ print ENVIRON["PREFIX"] $0 }' \
             | { grep -Ev -- "$exclude" || true; } \
             | sort || true)"
    [[ -n "$list" ]] || return 0
    n=$(printf '%s\n' "$list" | wc -l)
    if (( n > cap )); then
        warn "$label: $n files in scope but the cap is $cap - only the first $cap by path are reviewed (raise --max-files or split the chunk)" >&2
    fi
    printf '%s\n' "$list" | head -n "$cap" || true
}

chunk_stats() {
    local module_abs="$1"
    local exclude="$2"
    {
        chunk_lang_files "$module_abs" "$exclude" "Java" "$SRC_FILES" \
            -name '*.java' ! -path '*/target/*' ! -path '*/build/*'
        chunk_lang_files "$module_abs" "$exclude" "Python" "$SRC_FILES" \
            -name '*.py' ! -path '*/__pycache__/*' ! -path '*/venv/*'
        chunk_lang_files "$module_abs" "$exclude" "TS/JS" "$SRC_FILES" \
            \( -name '*.ts' -o -name '*.tsx' -o -name '*.js' -o -name '*.jsx' \) ! -path '*/node_modules/*'
        chunk_lang_files "$module_abs" "$exclude" "shell" "$SRC_FILES" \
            -name '*.sh'
    } | awk -v maxlines="$SRC_LINES" '
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
#
# The test is on a directory holding the six files, so the same rules decide
# both what is saved (a chunk's archived artifacts/) and what is picked up again
# later (a .salvage-<id> directory). Three things are required:
#
# - all six files, each at least 200 bytes (verify_resume_artifacts' own floor);
# - none of them a failed agent call of ANY kind. The transient test alone let a
#   debate through in which Codex had timed out (its "no final message" note
#   matches no quota pattern), and the chunk was then finished on one agent;
# - scope.stamp, which adversarial_review.sh writes at the end of phase 1 and
#   checks before it resumes. Without it nothing ties the six files to a target
#   or to the source they were written about, and the review refuses anyway.
debate_dir_is_intact() {
    local dir="$1"
    local f path
    [[ -s "$dir/scope.stamp" ]] || return 1
    for f in iter1_1_claude_review.md iter1_1_codex_review.md \
             iter1_2_claude_on_codex.md iter1_2_codex_on_claude.md \
             iter1_3_claude_meta.md iter1_3_codex_meta.md; do
        path="$dir/$f"
        [[ -s "$path" ]] || return 1
        [[ $(wc -c < "$path") -ge 200 ]] || return 1
        artifact_is_failed_call "$path" && return 1
    done
    return 0
}

chunk_debate_is_intact() { debate_dir_is_intact "$1/artifacts"; }

# Salvage is for a single-iteration debate only. scope.stamp is rewritten every
# iteration, so after two iterations it describes the source as the LAST one saw
# it, while the files that would be saved are the first one's: a fix run would
# then synthesise findings about code iteration 1 had already changed. Such a
# chunk is reviewed again in full. The pattern is a glob, so iter10_ is not
# taken for iter1_.
chunk_is_single_iteration() {
    local f
    for f in "$1"/artifacts/iter*_*.md; do
        [[ -f "$f" ]] || continue
        case "${f##*/}" in
            iter1_*) ;;
            *)       return 1 ;;
        esac
    done
    return 0
}

# Line 1 of a scope stamp is the canonical target the debate was written about.
# Checked here so a saved debate left under a chunk id that now names another
# module is dropped without spending the synthesis call on it. The source hash
# on line 2 is the review's to check; it has the dump.
stamp_names_target() {
    local stamp="$1" target="$2" first=""
    [[ -f "$stamp" ]] || return 1
    IFS= read -r first < "$stamp" || true
    first="${first%$'\r'}"
    [[ "$first" == "$target" ]]
}

# What a chunk's scope is, in a form that changes only when the scope does: the
# canonical module root, the always-on exclusions and the normalised include
# paths ("." for the whole module), sorted because their order in the manifest
# does not matter. Archived as scope.def next to exclude.regex.
#
# exclude.regex itself is not a good test of "same scope": build_exclude lists
# the sibling directories that exist at the moment it runs, so a build that
# creates target/ in a module changes the regex while the chunk covers exactly
# the same files, and every reviewed chunk of that module would be redone.
chunk_scope_def() {
    local module_abs="$1"
    shift
    printf 'module %s\n' "$module_abs"
    printf 'base %s\n' "$(base_exclude "$module_abs")"
    if [[ $# -eq 0 ]]; then
        printf 'include .\n'
        return 0
    fi
    printf '%s\n' "$@" | sed -e 's/^$/./' -e 's/^/include /' | LC_ALL=C sort -u
}

# Was the archived review in $1 of a different scope from the one this chunk has
# now? Prints what changed and returns 0 if so; returns 1 when it is the same.
# A --resume used to skip any chunk chunk_is_reviewed accepted, so after an edit
# to the manifest or a different --target with the same -o, the old report was
# kept and published as the review of the new scope.
#
# Three tests, in order:
# - artifacts/scope.stamp, line 1, is the target the review was run against.
#   The source hash on line 2 is deliberately not compared: a change to the code
#   must not redo finished chunks, or every commit during a long run would.
# - scope.def, when the chunk has one, against this chunk's definition now.
# - otherwise (a chunk archived before scope.def existed) exclude.regex, byte
#   for byte after dropping CRs. That regex starts with the module root, so it
#   also checks the target of a chunk that has no scope stamp either.
archived_scope_change() {
    local chunk_out="$1" module_abs="$2" exclude="$3" def="$4"
    local stamp="$1/artifacts/scope.stamp" first="" old_mod old_inc new_inc
    if [[ -f "$stamp" ]] && ! stamp_names_target "$stamp" "$module_abs"; then
        IFS= read -r first < "$stamp" || true
        echo "it was a review of ${first%$'\r'}, the chunk is now $module_abs"
        return 0
    fi
    if [[ -f "$chunk_out/scope.def" ]]; then
        [[ "$(tr -d '\r' < "$chunk_out/scope.def")" == "$def" ]] && return 1
        old_mod="$(tr -d '\r' < "$chunk_out/scope.def" | sed -n 's/^module //p')"
        old_inc="$(tr -d '\r' < "$chunk_out/scope.def" | sed -n 's/^include //p' | paste -sd, -)"
        new_inc="$(printf '%s\n' "$def" | sed -n 's/^include //p' | paste -sd, -)"
        if [[ "$old_mod" != "$module_abs" ]]; then
            echo "its module root was $old_mod, now $module_abs"
        elif [[ "$old_inc" != "$new_inc" ]]; then
            echo "its include paths were $old_inc, now $new_inc"
        else
            echo "the driver's always-on exclusions have changed since"
        fi
        return 0
    fi
    if [[ -f "$chunk_out/exclude.regex" ]] \
       && [[ "$(tr -d '\r' < "$chunk_out/exclude.regex")" == "$exclude" ]]; then
        return 1
    fi
    echo "its exclude.regex differs from the one the manifest gives now"
    return 0
}

# Same choice as get_timeout_cmd in adversarial_review.sh: gtimeout where
# coreutils is installed under that name (macOS), else timeout, else nothing.
get_timeout_cmd() {
    if command -v gtimeout > /dev/null 2>&1; then
        echo "gtimeout"
    elif command -v timeout > /dev/null 2>&1; then
        echo "timeout"
    else
        echo ""
    fi
}

# The codex binary the review itself would use (resolve_codex_bin in
# adversarial_review.sh): a CODEX_BIN the user set and nothing else, otherwise
# `codex` then `codex.cmd`, the first that answers --version. `command -v` is
# not enough: on Windows the npm bash shim exists and does not run.
PROBE_CODEX_BIN=""
resolve_probe_codex_bin() {
    local candidate
    PROBE_CODEX_BIN=""
    if [[ -n "${CODEX_BIN:-}" ]]; then
        "$CODEX_BIN" --version > /dev/null 2>&1 || return 1
        PROBE_CODEX_BIN="$CODEX_BIN"
        return 0
    fi
    for candidate in codex codex.cmd; do
        command -v "$candidate" > /dev/null 2>&1 || continue
        if "$candidate" --version > /dev/null 2>&1; then
            PROBE_CODEX_BIN="$candidate"
            return 0
        fi
    done
    return 1
}

# sleep that a trapped INT/TERM can interrupt: bash runs a trap only after the
# foreground command returns, so a plain 5-minute sleep delays the stop by that.
nap() {
    sleep "$1" &
    wait $! || true
}

# The time limit for one probe, as words to put in front of the command: empty
# when there is no timeout program. -k sends KILL 30 seconds after the TERM, for
# a CLI that ignores TERM and would otherwise hold the probe (and so the whole
# wait) for good. It is used only where the installed timeout accepts it; an old
# BusyBox one does not.
PROBE_TIMEOUT_PREFIX=""
PROBE_TIMEOUT_RESOLVED=0
resolve_probe_timeout() {
    local tcmd
    [[ "$PROBE_TIMEOUT_RESOLVED" == "1" ]] && return 0
    PROBE_TIMEOUT_RESOLVED=1
    PROBE_TIMEOUT_PREFIX=""
    tcmd="$(get_timeout_cmd)"
    [[ -n "$tcmd" ]] || return 0
    if "$tcmd" -k 1s 5s true > /dev/null 2>&1; then
        PROBE_TIMEOUT_PREFIX="$tcmd -k 30s 120s"
    else
        PROBE_TIMEOUT_PREFIX="$tcmd 120s"
    fi
    return 0
}

# Claude counts as answering when the call exits 0 and its reply holds OK as a
# word of its own, in any case and with anything around it: "**OK**", " OK" and
# "ok." are all answers. Requiring the reply to START with OK failed every probe
# of a CLI that wraps its answer in markdown, until the two-hour limit. A
# non-zero exit is still a failure, and so is refusal text that happens to
# contain the word.
probe_claude() {
    local out
    resolve_probe_timeout
    # The prefix is deliberately unquoted: it is several words, or none at all
    # ("run without a time limit"). The prompt is a here-string, not a pipe, so
    # pipefail cannot fail the probe on the writing side.
    # shellcheck disable=SC2086
    out="$($PROBE_TIMEOUT_PREFIX claude --print 2>&1 <<< "Reply with exactly: OK")" || return 1
    grep -qEi -- "$TRANSIENT_SHORT_RE" <<< "$out" && return 1
    grep -qiE '(^|[^[:alnum:]])OK([^[:alnum:]]|$)' <<< "$out"
}

# One tiny `codex exec`, invoked the way run_codex invokes it. It counts as an
# answer only if codex exits 0, leaves a final message, and neither the message
# nor the transcript carries usage-limit or transport-error text: a refused
# codex can still exit 0.
probe_codex() {
    local tmp_msg tmp_log tmp_dir rc=0
    resolve_probe_codex_bin || return 1
    resolve_probe_timeout
    # Space-free paths, and a cwd that is not this repo: see run_codex.
    tmp_dir="$(mktemp -d -t ar_probe_XXXXXX 2>/dev/null)" || tmp_dir=""
    [[ -n "$tmp_dir" && -d "$tmp_dir" ]] || return 1
    tmp_msg="$tmp_dir/msg"
    tmp_log="$tmp_dir/log"
    # shellcheck disable=SC2086
    ( cd "$tmp_dir" && printf '%s' "Reply with exactly: OK" \
        | $PROBE_TIMEOUT_PREFIX "$PROBE_CODEX_BIN" exec --sandbox read-only --skip-git-repo-check -o "$tmp_msg" - ) \
        > "$tmp_log" 2>&1 || rc=$?
    if [[ $rc -eq 0 ]]; then
        [[ -s "$tmp_msg" ]] || rc=1
    fi
    if [[ $rc -eq 0 ]] && grep -qEi -- "$TRANSIENT_SHORT_RE|$TRANSIENT_LOG_RE" "$tmp_msg" "$tmp_log" 2>/dev/null; then
        rc=1
    fi
    rm -rf "$tmp_dir"
    return $rc
}

# Block until BOTH agent CLIs answer a trivial prompt again, so a reset quota is
# detected rather than guessed at from the message text. Probing Claude alone
# returned at once whenever Codex was the refused one: the chunk was redone
# straight away, failed the same way, and after three attempts every remaining
# chunk went the same way.
wait_for_agents() {
    local max_waits="${1:-24}" interval="${2:-300}" i=1 down
    while (( i <= max_waits )); do
        down=""
        probe_claude || down="claude"
        probe_codex || down="${down:+$down and }codex"
        if [[ -z "$down" ]]; then
            ok "both agent CLIs are responding again"
            return 0
        fi
        warn "agent CLI still refusing: $down (check $i/$max_waits), retrying in ${interval}s"
        nap "$interval"
        i=$((i + 1))
    done
    return 1
}

# --- driver lock -------------------------------------------------------------
#
# .review.lock is held by adversarial_review.sh, so it is absent in the gap
# between two chunks - exactly when this driver clears artifacts/ and when it
# archives them. A second driver (or run_filelist_review.sh) starting in that gap
# saw no lock and both then worked in the same artifacts/. This lock covers the
# whole run instead: a DIRECTORY, because mkdir either creates it or fails, with
# no window between the test and the write. The pid inside says who holds it.
# adversarial_review.sh refuses to start under a live lock unless it was started
# by the holder, which it learns from AR_DRIVER_LOCK_PID.
acquire_driver_lock() {
    local holder="" tries=0 took_over=0
    while ! mkdir "$DRIVER_LOCK" 2>/dev/null; do
        holder="$(cat "$DRIVER_LOCK/pid" 2>/dev/null | tr -d '\r\n ' || true)"
        if [[ "$holder" =~ ^[0-9]+$ ]] && kill -0 "$holder" 2>/dev/null; then
            err "another driver or wrapper is running in this checkout (pid $holder holds $DRIVER_LOCK)"
            err "wait for it to finish, or use a separate git worktree; nothing was touched"
            err "if no such run exists (see /proc, not ps), remove that directory and start again"
            exit 4
        fi
        # No pid yet: the holder may be between its mkdir and its write. Give it
        # a few seconds before calling the lock abandoned.
        tries=$((tries + 1))
        if [[ -z "$holder" && $tries -le 5 ]]; then
            sleep 1
            continue
        fi
        if (( tries > 10 )); then
            err "cannot take $DRIVER_LOCK - remove it by hand if no run is alive"
            exit 4
        fi
        warn "removing stale driver lock left by pid ${holder:-unknown}"
        rm -rf "$DRIVER_LOCK"
        took_over=1
    done
    # The directory can vanish between the mkdir and this write, when another
    # process was already removing what it took for a stale lock.
    if ! { echo $$ > "$DRIVER_LOCK/pid"; } 2>/dev/null; then
        err "another driver removed $DRIVER_LOCK while it was being taken - nothing was touched"
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
            err "another driver took $DRIVER_LOCK at the same moment (pid ${holder:-unknown}) - nothing was touched"
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

# Stop the review this driver started, if one is running. Its pid is in the lock
# directory because the review runs on the left of a pipe into tee, in a
# subshell, where $! is not visible from here. adversarial_review.sh traps TERM
# itself, stops its agents and removes .review.lock.
stop_child_review() {
    local pid="" n=0
    pid="$(cat "$DRIVER_LOCK/review.pid" 2>/dev/null | tr -d '\r\n ' || true)"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 0
    kill -0 "$pid" 2>/dev/null || return 0
    kill -TERM "$pid" 2>/dev/null || true
    while kill -0 "$pid" 2>/dev/null && (( n < 20 )); do
        sleep 1
        n=$((n + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
        warn "review pid $pid ignored TERM, killing it"
        kill -KILL "$pid" 2>/dev/null || true
    fi
    return 0
}

on_driver_signal() {
    local sig="$1" code="$2"
    trap '' INT TERM
    warn "received $sig - stopping the running review and releasing the driver lock"
    if [[ "$DRIVER_LOCK_HELD" == "1" ]]; then
        stop_child_review
    fi
    exit "$code"
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
if ! mkdir -p "$STATE_DIR" 2>/dev/null; then
    err "AR_STATE_DIR is not a usable directory: $STATE_DIR"
    exit 1
fi
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

info "target   : $TARGET_ROOT"
info "manifest : $MANIFEST"
info "output   : $OUT_DIR"
if [[ "$FIX" == "1" ]]; then
    info "mode     : FIX - phase 4 will modify the target in place"
else
    info "mode     : review only - nothing in the target is modified"
fi
echo ""

# Taken before the first clear of artifacts/ and held until the last chunk is
# archived. --list never gets here, so planning works while a run is live.
trap release_driver_lock EXIT
trap 'on_driver_signal INT 130' INT
trap 'on_driver_signal TERM 143' TERM
acquire_driver_lock

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
    scope_redo=0

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
    scope_def="$(chunk_scope_def "$module_abs" "${incs[@]}")"

    # Decided here, once the chunk's scope is known, and not from the chunk
    # directory alone: a reviewed chunk is reused only if it was a review of
    # this same scope (see archived_scope_change).
    if [[ "$RESUME" == "1" || "$DRY_RUN" == "1" ]] && chunk_is_complete "$chunk_out"; then
        if [[ "$RESUME" == "1" ]]; then
            if why="$(archived_scope_change "$chunk_out" "$module_abs" "$exclude" "$scope_def")"; then
                warn "$cid: the archived review is of another scope ($why) - reviewing the chunk again"
                scope_redo=1
            else
                info "$cid: already done, skipping"
                continue
            fi
        fi
        # A dry run only writes stubs. It must not replace a real review: the
        # old output of this chunk is removed below, before the first attempt.
        if [[ "$DRY_RUN" == "1" ]]; then
            err "$cid: refusing to dry-run over a completed review in $chunk_out"
            failed=$((failed + 1))
            continue
        fi
    fi
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
  #
  # Only a debate that passes the same test it was saved under, and whose scope
  # stamp names this chunk's module. One saved by an older driver has no stamp,
  # and adversarial_review.sh would refuse to resume from it: discard it here and
  # review the chunk in full.
  saved="$OUT_DIR/.salvage-$cid"
  if [[ "$RESUME" == "1" && -d "$saved" ]]; then
      if debate_dir_is_intact "$saved" && stamp_names_target "$saved/scope.stamp" "$module_abs"; then
          salvage_dir="$saved"
          resume_phase=4
          info "$cid: found a saved debate from an earlier run - finishing with synthesis only"
      else
          warn "$cid: saved debate is unusable (no scope stamp, another target, or a failed agent call) - reviewing the chunk in full"
          rm -rf "$saved"
      fi
  fi
  while true; do
    # artifacts/, logs/, tracking.json and the circuit breaker are global to this
    # repo, so clear them per chunk. Without this a chunk can inherit the previous
    # chunk's OPEN breaker, or archive a log file that a previous chunk wrote, or
    # - when its review exits before it writes tracking.json - be recorded with
    # the previous chunk's status.
    #
    # This is deliberately NOT `--reset`: reset_all() deletes .review.lock, which
    # is the only thing preventing a second review from interleaving with a live
    # one in the shared artifacts/ directory. Clear the state directly and leave
    # the lock alone - and refuse to start the chunk at all while someone holds
    # it, rather than trampling their run. (.driver.lock, taken above, keeps out
    # other drivers; this check is for a review someone started by hand.)
    if [[ -f "$STATE_DIR/.review.lock" ]]; then
        holder="$(cat "$STATE_DIR/.review.lock" 2>/dev/null || echo "")"
        if [[ -n "$holder" ]] && kill -0 "$holder" 2>/dev/null; then
            err "another review is running (pid $holder) - stopping before it corrupts this run"
            err "wait for it to finish, then resume with --resume"
            exit 4
        fi
        warn "removing stale lock left by pid ${holder:-unknown}"
        rm -f "$STATE_DIR/.review.lock"
    fi

    # The archive step below copies INTO the chunk directory, so whatever an
    # earlier run left there would be merged with this attempt's files: a rerun
    # that ends clean in phase 1 kept the old synthesis report, and the
    # aggregator then published findings for a chunk recorded as clean. Every
    # attempt therefore starts from an empty chunk directory, with or without
    # --resume. A saved debate is not affected: it lives beside the directory.
    # Done after the lock check above, so a refused start deletes nothing.
    if [[ -d "$chunk_out" ]]; then
        if [[ "$attempt" -eq 1 && "$scope_redo" -eq 0 ]]; then
            if [[ "$RESUME" == "1" ]]; then
                warn "$cid: previous attempt incomplete, re-running"
            else
                warn "$cid: replacing the output of an earlier run"
            fi
        fi
        rm -rf "$chunk_out"
    fi
    mkdir -p "$chunk_out"
    printf '%s\n' "$exclude" > "$chunk_out/exclude.regex"
    printf '%s\n' "$scope_def" > "$chunk_out/scope.def"

    rm -rf "${STATE_DIR:?}/artifacts"/* 2>/dev/null || true
    rm -f "${STATE_DIR:?}/logs"/iter* 2>/dev/null || true
    rm -f "${STATE_DIR:?}/tracking.json" 2>/dev/null || true
    "$REVIEW_SH" --reset-circuit > /dev/null 2>&1 || true

    # A salvaged debate goes back into artifacts/ AFTER the clear above, so the
    # resumed run finds exactly the six files --from-phase 4 expects.
    # The scope stamp goes with them: --from-phase refuses to resume without it.
    if [[ "$resume_phase" -gt 1 && -n "$salvage_dir" && -d "$salvage_dir" ]]; then
        mkdir -p "$STATE_DIR/artifacts" "$STATE_DIR/logs"
        cp "$salvage_dir"/*.md "$STATE_DIR/artifacts/" 2>/dev/null || true
        cp "$salvage_dir"/scope.stamp "$STATE_DIR/artifacts/" 2>/dev/null || true
        cp "$salvage_dir"/*.codex.log "$STATE_DIR/logs/" 2>/dev/null || true
        info "$cid: restored saved debate, resuming at phase $resume_phase"
    fi

    # Report-only is the review's default, and it is still said out loud: which
    # of the two modes a chunk runs in must not depend on a default elsewhere.
    review_args=()
    if [[ "$FIX" == "1" ]]; then
        review_args+=(--fix)
    else
        review_args+=(--no-fix)
    fi
    [[ "$DRY_RUN" == "1" ]] && review_args+=(--dry-run)
    [[ "$resume_phase" -gt 1 ]] && review_args+=(--from-phase "$resume_phase")
    review_args+=(-m "$MAX_ITERS" -t "$TIMEOUT_MIN" -v "$module_abs")
    ran_from_phase="$resume_phase"

    # The review runs in the background and is waited for: bash delivers a
    # trapped TERM only once a foreground command has returned, so a foreground
    # review would hold the stop back until the chunk was over. Its pid and exit
    # code travel through the lock directory, which is ours for the whole run.
    rm -f "$DRIVER_LOCK/review.pid" "$DRIVER_LOCK/review.rc"
    start=$(date +%s)
    {
        MAX_SOURCE_FILES="$SRC_FILES" \
        MAX_SOURCE_LINES="$SRC_LINES" \
        MAX_SOURCE_SHELL_FILES="$SRC_FILES" \
        MAX_SOURCE_SHELL_LINES="$SRC_LINES" \
        MAX_SOURCE_EXCLUDE="$exclude" \
            "$REVIEW_SH" "${review_args[@]}" 2>&1 &
        echo $! > "$DRIVER_LOCK/review.pid"
        review_rc=0
        wait $! || review_rc=$?
        echo "$review_rc" > "$DRIVER_LOCK/review.rc"
    } | tee "$chunk_out/console.log" &
    wait $! || true
    rc="$(cat "$DRIVER_LOCK/review.rc" 2>/dev/null | tr -d '\r\n ' || true)"
    [[ "$rc" =~ ^[0-9]+$ ]] || rc=1
    rm -f "$DRIVER_LOCK/review.pid" "$DRIVER_LOCK/review.rc"
    dur=$(($(date +%s) - start))

    # Archive everything this chunk produced before the next chunk wipes it.
    [[ -d "$STATE_DIR/artifacts" ]] && cp -r "$STATE_DIR/artifacts" "$chunk_out/" 2>/dev/null || true
    [[ -d "$STATE_DIR/logs" ]] && cp -r "$STATE_DIR/logs" "$chunk_out/" 2>/dev/null || true
    [[ -f "$STATE_DIR/tracking.json" ]] && cp "$STATE_DIR/tracking.json" "$chunk_out/" || true

    # A quota refusal is not a review. Throw the chunk away, wait for the CLI to
    # answer again, and redo it - otherwise the loop races through every
    # remaining chunk producing empty artifacts that look like clean reviews.
    #
    # Five reasons to redo a chunk, and only the first is worth waiting for:
    #   transient    a quota or network failure - wait until both agents answer
    #   scope        the artifacts came from another run - redo at once
    #   failed call  an agent gave no answer for another reason (a Codex timeout
    #                note, an empty artifact) - redo at once. chunk_is_reviewed
    #                rejects such a chunk, so archiving it only handed the redo
    #                to the next --resume.
    # A fourth: a saved debate that adversarial_review.sh refused to resume from
    # (its scope stamp no longer matches the target) is dropped and the chunk is
    # reviewed in full.
    # A fifth: the synthesis call answered, but its report has no complete status
    # block, so the chunk does not count as reviewed. That is not a failed call
    # (there is text, and the call may have exited 0), so none of the reasons
    # above fires, and the chunk used to be recorded as failed and reviewed again
    # in full, seven calls, on the next --resume. It is a redo reason only when
    # the debate can be kept: the retry is then the synthesis call alone.
    redo=""
    scope_ok=1
    chunk_scope_is_intact "$chunk_out" "$module_abs" "$exclude" || scope_ok=0
    synth_file="$(latest_iter_artifact "$chunk_out/artifacts" 4_synthesis.md)"
    if chunk_hit_transient_failure "$chunk_out"; then
        redo="transient"
    elif [[ $scope_ok -eq 0 ]]; then
        redo="scope"
    elif chunk_has_failed_call "$chunk_out"; then
        redo="failed_call"
    elif [[ "$ran_from_phase" -gt 1 && $rc -ne 0 && -z "$synth_file" ]]; then
        redo="stale_debate"
    elif [[ "$DRY_RUN" != "1" && -n "$synth_file" ]] \
         && ! chunk_is_complete "$chunk_out" \
         && ! artifact_has_block "$synth_file" SYNTHESIS_STATUS \
         && chunk_debate_is_intact "$chunk_out" \
         && chunk_is_single_iteration "$chunk_out"; then
        redo="no_synthesis"
    fi
    if [[ -n "$redo" ]]; then
        # Keep the debate if it survived and only synthesis failed; that is six
        # of the chunk's seven agent calls. Only a single-iteration debate: see
        # chunk_is_single_iteration.
        resume_phase=1
        salvage_dir=""
        rm -rf "$OUT_DIR/.salvage-$cid"
        if [[ "$redo" != "stale_debate" && $scope_ok -eq 1 ]] \
           && chunk_debate_is_intact "$chunk_out" \
           && chunk_is_single_iteration "$chunk_out"; then
            salvage_dir="$OUT_DIR/.salvage-$cid"
            mkdir -p "$salvage_dir"
            cp "$chunk_out"/artifacts/iter1_[123]_*.md "$salvage_dir/" 2>/dev/null || true
            cp "$chunk_out"/artifacts/scope.stamp "$salvage_dir/" 2>/dev/null || true
            cp "$chunk_out"/logs/iter1_[123]_*.codex.log "$salvage_dir/" 2>/dev/null || true
            resume_phase=4
            warn "$cid: debate intact, only synthesis failed - keeping 6 of 7 calls"
        fi
        case "$redo" in
            transient)    warn "$cid: attempt $attempt/$max_attempts hit a quota or network failure - discarding" ;;
            scope)        warn "$cid: attempt $attempt/$max_attempts was scope-contaminated - discarding" ;;
            failed_call)  warn "$cid: attempt $attempt/$max_attempts has an agent call that produced no answer - discarding" ;;
            stale_debate) warn "$cid: attempt $attempt/$max_attempts: the saved debate was not accepted (rc=$rc) - discarding it, reviewing in full" ;;
            no_synthesis) warn "$cid: attempt $attempt/$max_attempts: the synthesis report has no complete status block (rc=$rc) - discarding it" ;;
        esac
        rm -rf "$chunk_out"
        if (( attempt >= max_attempts )); then
            err "$cid: still failing after $max_attempts attempts, giving up on this chunk"
            # The status says which kind, so a quota outage and a broken agent
            # do not look alike in the index.
            case "$redo" in
                transient|scope) give_up="transient_failure" ;;
                *)               give_up="agent_failure" ;;
            esac
            printf "%s\t%s\t%s\t%s\t0\t0\n" "$cid" "$nf" "$kb" "$give_up" >> "$INDEX"
            failed=$((failed + 1))
            break
        fi
        if [[ "$redo" == "transient" ]] && ! wait_for_agents; then
            # The chunk directory was removed above, so without a row this chunk
            # would vanish from the report: aggregate_review.sh finds chunks by
            # their directory or their index row. Rows are append-only and the
            # last one counts, so a later --resume replaces this one.
            printf "%s\t%s\t%s\t%s\t0\t0\n" "$cid" "$nf" "$kb" "transient_failure" >> "$INDEX"
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
    # The verdict is chunk_is_reviewed, the same test --resume and the supervisor
    # apply, and not the review's exit code. The two used to disagree: a --fix
    # chunk that ended max_iterations exits 1 and was counted as failed here,
    # while the next --resume skipped it as done. Now a chunk the test accepts is
    # done whatever the review exited with (the code is noted in the index), and
    # one it rejects is failed even when the review exited 0 (an agent that left
    # nothing --resume would accept, say). A dry run only writes stubs, which the
    # test can never accept, so there the exit code is all there is to go by.
    reviewed=0
    if [[ "$DRY_RUN" == "1" ]]; then
        [[ $rc -eq 0 ]] && reviewed=1
    elif chunk_is_complete "$chunk_out"; then
        reviewed=1
    fi
    [[ $rc -ne 0 ]] && status="${status}(rc=$rc)"
    if [[ $reviewed -eq 0 ]]; then
        if [[ $rc -eq 0 ]]; then
            warn "$cid: review exited 0 but the chunk does not count as reviewed"
            status="${status}(incomplete)"
        else
            warn "$cid: review exited $rc and the chunk does not count as reviewed"
        fi
        failed=$((failed + 1))
    elif [[ $rc -ne 0 ]]; then
        warn "$cid: reviewed, although the review exited $rc ($status) - recorded as done"
    fi

    printf "%s\t%s\t%s\t%s\t%s\t%s\n" "$cid" "$nf" "$kb" "$status" "$iters" "$dur" >> "$INDEX"
    # Drop any saved debate for this chunk, including one left by an earlier
    # driver run that this run did not use.
    rm -rf "$OUT_DIR/.salvage-$cid"
    echo "[$cid] $status in ${dur}s" >> "$RUN_LOG"
    if [[ $reviewed -eq 1 ]]; then
        ok "$cid -> $status (${dur}s)"
    else
        warn "$cid -> $status (${dur}s) - not reviewed"
    fi
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
# not recover, 4 another review holds .review.lock or another driver or wrapper
# holds .driver.lock, 130/143 stopped by INT/TERM. supervise_review.sh decides
# what to do next from this code, so it has to stay accurate.
if [[ $failed -gt 0 ]]; then
    warn "$failed chunk(s) failed - rerun with --resume to redo them"
    exit 2
fi
exit 0
