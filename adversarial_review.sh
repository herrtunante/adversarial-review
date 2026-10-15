#!/usr/bin/env bash
#
# Adversarial Review: Multi-Agent Code Review with Claude + Codex
#
# Implements an adversarial review loop where Claude and GPT Codex
# independently review code, cross-review findings, meta-review feedback,
# and then Claude synthesizes a report (and, with --fix, implements the fixes).
#
# Based on patterns from asimov-ralph (https://github.com/frankbria/ralph-claude-code)
#
# Usage:
#   ./adversarial_review.sh [OPTIONS] <target_dir>
#
# Options:
#   -h, --help              Show help message
#   -m, --max-iters N       Maximum iterations (default: 3)
#   -p, --prompt FILE       Custom phase-1 review prompt, for this run only
#   -v, --verbose           Verbose output
#   -t, --timeout MIN       Timeout per agent call in minutes (default: 10)
#   --status                Show current status
#   --reset                 Reset artifacts and tracking
#   --reset-circuit         Reset circuit breaker
#   --circuit-status        Show circuit breaker status
#   --dry-run               Show what would be done without executing
#   --fix                   Let phase 4 modify the target (default: report only)

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
PROMPTS_DIR="$SCRIPT_DIR/prompts"
# Holds the version. Set here because the libs sourced below overwrite SCRIPT_DIR.
PLUGIN_MANIFEST="$SCRIPT_DIR/.claude-plugin/plugin.json"

# Where a run keeps its state: artifacts/, logs/, tracking.json, the circuit
# breaker and the locks. Next to the script unless AR_STATE_DIR says otherwise.
# Installed as a Claude Code plugin, the script lives in a cache directory that
# every plugin update replaces, so the plugin's skill points this at a directory
# that survives updates. Two runs with different state directories do not see
# each other's locks, exactly like two git worktrees. Exported (and made
# absolute) so the reviews a chunk driver starts use the same one.
AR_STATE_DIR="${AR_STATE_DIR:-$SCRIPT_DIR}"
if ! mkdir -p "$AR_STATE_DIR" 2>/dev/null || ! AR_STATE_DIR="$(cd "$AR_STATE_DIR" && pwd)"; then
    echo "[ERROR] AR_STATE_DIR is not a usable directory: $AR_STATE_DIR" >&2
    exit 1
fi
export AR_STATE_DIR

# Export AR_DIR for lib scripts
export AR_DIR="$AR_STATE_DIR"
ARTIFACTS_DIR="$AR_DIR/artifacts"
LOGS_DIR="$AR_DIR/logs"
TRACKING_FILE="$AR_DIR/tracking.json"

# Source library components
source "$LIB_DIR/date_utils.sh"
source "$LIB_DIR/circuit_breaker.sh"
source "$LIB_DIR/response_analyzer.sh"
# Shared with the chunk drivers and the aggregator so there is one definition of
# each: extract_status_block / artifact_has_block (what a complete status block
# is) and artifact_is_failure_note / artifact_is_failed_call (what a failed agent
# call looks like). It defines functions and patterns and runs nothing.
source "$LIB_DIR/transient.sh"

# Defaults
MAX_ITERATIONS="${MAX_ITERATIONS:-3}"
VERBOSE="${VERBOSE:-0}"
DRY_RUN="${DRY_RUN:-0}"
TIMEOUT_MINUTES="${TIMEOUT_MINUTES:-10}"
# Report-only is the default: phase 4 writes a report and changes nothing.
# --fix (or NO_FIX=0) lets it edit the target. The synthesis prompt carries six
# artifacts that quote the target's source, so a comment planted in reviewed
# code reaches an agent that can write - fix mode is for trusted code only.
NO_FIX="${NO_FIX:-1}"
# The tools the phase-4 agent gets in fix mode. It can read and edit files and
# nothing else: no shell, no network. This replaced
# --dangerously-skip-permissions, which handed the same prompt every tool. It is
# a tool allowlist, not filesystem containment.
FIX_MODE_TOOLS="${FIX_MODE_TOOLS:-Read,Grep,Glob,Edit,Write}"
# The tools every other Claude call gets (phases 1-3 and a report-only phase 4).
# Those calls run inside the target too; without a tool list of their own they
# ran with whatever the user's settings allowed, shell included.
READ_ONLY_TOOLS="${READ_ONLY_TOOLS:-Read,Grep,Glob}"
# Passed to every Claude call so the TARGET's configuration is not loaded: the
# reviewed project's .claude/settings*.json (hooks, permissions) and its
# .mcp.json would otherwise act on a call whose cwd is that project. Both flags
# are documented by `claude --help` (2.1.296):
#   --setting-sources <sources>  Comma-separated list of setting sources to load
#                                (user, project, local).
#   --strict-mcp-config          Only use MCP servers from --mcp-config, ignoring
#                                all other MCP configurations
CLAUDE_ISOLATION_ARGS=(--setting-sources user --strict-mcp-config)
# Start the first iteration at this phase instead of phase 1, reusing the
# artifacts already in artifacts/. Only phase 4 is expensive to lose, so this
# exists to recover a run whose debate succeeded and whose synthesis was refused.
FROM_PHASE="${FROM_PHASE:-1}"
CHANGED_ONLY="${CHANGED_ONLY:-0}"

# Source collection caps. These drive prompt size and therefore cost directly:
# the phase-1 dump is sent to both agents, and phase 2 sends it again alongside
# the other agent's review. MAX_SOURCE_EXCLUDE is an extended-regex matched
# against each absolute path; anything matching is dropped before the cap is
# applied, so vendored or generated trees don't consume the file budget.
MAX_SOURCE_FILES="${MAX_SOURCE_FILES:-30}"
MAX_SOURCE_LINES="${MAX_SOURCE_LINES:-500}"
MAX_SOURCE_SHELL_FILES="${MAX_SOURCE_SHELL_FILES:-10}"
MAX_SOURCE_SHELL_LINES="${MAX_SOURCE_SHELL_LINES:-300}"
MAX_SOURCE_EXCLUDE="${MAX_SOURCE_EXCLUDE:-}"
# A file naming exactly the files to review, one path per line relative to the
# target. When set it replaces the directory walk and the per-language caps.
SOURCE_FILE_LIST="${SOURCE_FILE_LIST:-}"
# Phase-1 prompt template. -p/--prompt points this at another file for one run;
# the repo's own template is never overwritten.
INITIAL_PROMPT_FILE="$PROMPTS_DIR/initial_review.md"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# Logging
log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_claude()  { echo -e "${MAGENTA}[CLAUDE]${NC} $1"; }
log_codex()   { echo -e "${CYAN}[CODEX]${NC} $1"; }
# Verbose output goes to stderr, not stdout. collect_source_code() and
# collect_changed_files() are consumed with $(...), so anything they echo on
# stdout is spliced into the source dump and shipped to the agents as if it were
# code. With VERBOSE=1 the dump used to open with a stray "[VERBOSE] Collecting
# source code from ..." line inside the prompt.
log_verbose() { [[ "$VERBOSE" == "1" ]] && echo -e "${BLUE}[VERBOSE]${NC} $1" >&2 || true; }

# Cross-platform timeout command
get_timeout_cmd() {
    if command -v gtimeout &> /dev/null; then
        echo "gtimeout"  # macOS with coreutils
    elif command -v timeout &> /dev/null; then
        echo "timeout"   # Linux
    else
        echo ""
    fi
}

# Set TIMEOUT_WORDS to the words to put in front of an agent command so it is
# stopped after $1 seconds; empty when there is no timeout command. -k 30s sends
# KILL half a minute after the TERM: a CLI that ignores TERM used to hold its
# phase for ever. A timeout without -k (busybox, very old coreutils) is probed
# for and gets the plain form. A global rather than output to capture: each
# caller is already its own background subshell.
TIMEOUT_WORDS=()
set_timeout_words() {
    local secs="$1"
    local cmd
    cmd=$(get_timeout_cmd)
    TIMEOUT_WORDS=()
    [[ -n "$cmd" ]] || return 0
    if "$cmd" -k 1s 5s true > /dev/null 2>&1; then
        TIMEOUT_WORDS=("$cmd" -k 30s "${secs}s")
    else
        TIMEOUT_WORDS=("$cmd" "${secs}s")
    fi
}

# Resolve a codex binary that actually runs.
# On Windows/Git Bash the npm `codex` shell shim can resolve node to a placeholder
# stub under node_modules/node ("This file intentionally left blank") while the .cmd
# wrapper works fine. Probing with --version catches that; `command -v` does not.
#
# A CODEX_BIN set by the user is never replaced: it is probed the same way and
# the run stops if it does not answer (return 2), instead of quietly reviewing
# with a different binary than the one asked for.
CODEX_BIN="${CODEX_BIN:-}"
resolve_codex_bin() {
    local candidate
    if [[ -n "$CODEX_BIN" ]]; then
        "$CODEX_BIN" --version &> /dev/null && return 0
        return 2
    fi
    for candidate in codex codex.cmd; do
        command -v "$candidate" &> /dev/null || continue
        if "$candidate" --version &> /dev/null; then
            CODEX_BIN="$candidate"
            return 0
        fi
    done
    return 1
}

# Check dependencies
check_dependencies() {
    local missing=()

    if ! command -v jq &> /dev/null; then
        missing+=("jq (choco install jq | winget install jqlang.jq | brew install jq)")
    fi

    # Agent CLIs are only needed for a real run
    if [[ "$DRY_RUN" != "1" ]]; then
        if ! command -v claude &> /dev/null; then
            missing+=("claude CLI (npm install -g @anthropic-ai/claude-code)")
        elif ! claude --version &> /dev/null; then
            missing+=("claude CLI is on PATH but fails to run - check 'claude --version'")
        fi

        if [[ -n "$CODEX_BIN" ]]; then
            if resolve_codex_bin; then
                log_verbose "Using codex binary from CODEX_BIN: $CODEX_BIN"
            else
                missing+=("CODEX_BIN is set to '$CODEX_BIN' but '$CODEX_BIN --version' fails - fix it or unset it")
            fi
        elif ! command -v codex &> /dev/null && ! command -v codex.cmd &> /dev/null; then
            missing+=("codex CLI (npm install -g @openai/codex)")
        elif ! resolve_codex_bin; then
            missing+=("codex CLI is on PATH but fails to run - check 'codex --version'")
        else
            log_verbose "Using codex binary: $CODEX_BIN"
        fi
    else
        CODEX_BIN="${CODEX_BIN:-codex}"
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing dependencies:"
        for dep in "${missing[@]}"; do
            echo "  - $dep"
        done
        exit 1
    fi

    # Check for timeout command (warn but don't fail)
    if [[ -z "$(get_timeout_cmd)" ]]; then
        log_warning "No timeout command found. Install coreutils for timeout support."
    fi
}

# Initialize tracking
init_tracking() {
    mkdir -p "$ARTIFACTS_DIR" "$LOGS_DIR"

    if [[ ! -f "$TRACKING_FILE" ]]; then
        cat > "$TRACKING_FILE" << EOF
{
    "iteration": 0,
    "status": "pending",
    "target_dir": null,
    "started_at": null,
    "updated_at": null,
    "phases": [],
    "history": []
}
EOF
    fi
}

# Update tracking JSON
update_tracking() {
    local field="$1"
    local value="$2"
    local timestamp
    timestamp=$(get_iso_timestamp)

    local tmp=$(mktemp)
    jq --arg f "$field" --arg v "$value" --arg ts "$timestamp" '
        .[$f] = (if $v | test("^-?[0-9]+$") then ($v | tonumber)
                 elif $v == "true" then true
                 elif $v == "false" then false
                 elif ($v | startswith("[") or startswith("{")) then ($v | fromjson)
                 else $v end) |
        .updated_at = $ts
    ' "$TRACKING_FILE" > "$tmp" && mv "$tmp" "$TRACKING_FILE"
}

# Add to history. The result is a parse_status_block object and is stored as
# one, not as a string of JSON, so --status can read its fields; anything that
# is not JSON is kept as the string it is.
add_to_history() {
    local iteration="$1"
    local phase="$2"
    local agent="$3"
    local result="$4"

    local tmp=$(mktemp)
    jq --arg i "$iteration" --arg p "$phase" --arg a "$agent" --arg r "$result" --arg ts "$(get_iso_timestamp)" '
        .history += [{
            "iteration": ($i | tonumber),
            "phase": $p,
            "agent": $a,
            "result": ($r | fromjson? // $r),
            "timestamp": $ts
        }]
    ' "$TRACKING_FILE" > "$tmp" && mv "$tmp" "$TRACKING_FILE"
}

# extract_status_block FILE BLOCK_NAME comes from lib/transient.sh: it prints the
# lines of the LAST complete block without its two delimiter lines, and fails
# (printing nothing) when there is no complete block or when a block opened
# after the last complete one was never closed. There is deliberately no second
# definition here; the aggregator reads the same blocks through the same one.

# Parse status block from agent output
# Format: ---REVIEW_STATUS--- ... ---END_REVIEW_STATUS---
#
# The JSON is built by jq, never by string concatenation: a SUMMARY holding a
# quote, a backslash or a tab used to produce invalid JSON, after which every
# `jq -r '.x // default'` on the result printed nothing and the exit signal was
# lost. Each line is split at its FIRST colon, so a value may contain colons.
parse_status_block() {
    local file="$1"
    local block_name="${2:-REVIEW_STATUS}"

    if [[ ! -f "$file" ]]; then
        echo '{"error": "file not found"}'
        return 1
    fi

    local block
    if ! block=$(extract_status_block "$file" "$block_name"); then
        # No status block found, try to detect NO_ISSUES. Never in a failure
        # note: the lines it quotes from the CLI's output can hold that word,
        # and a failed call would then parse as a clean review.
        if ! artifact_is_failure_note "$file" && grep -qE '^[[:space:]]*NO_ISSUES[[:space:]]*$' "$file"; then
            echo '{"exit_signal": true, "issues_found": 0}'
            return 0
        fi
        echo '{"error": "no status block"}'
        return 1
    fi

    # KEY: value lines -> one JSON object. Keys are lowercased with whitespace
    # removed; values are trimmed. Digits become numbers, true/YES/FULL become
    # true, false/NO/LOW become false, anything else stays a string. Lines
    # without a colon are ignored.
    local json
    if ! json=$(printf '%s\n' "$block" | jq -Rnc '
        [ inputs
          | index(":") as $i
          | select($i != null)
          | { key:   (.[:$i] | gsub("[[:space:]]"; "") | ascii_downcase),
              value: (.[$i + 1:] | sub("^[[:space:]]+"; "") | sub("[[:space:]]+$"; "")) }
          | select(.key != "")
          | .value |= ( if test("^[0-9]+$") then tonumber
                        elif . == "true" or . == "YES" or . == "FULL" then true
                        elif . == "false" or . == "NO" or . == "LOW" then false
                        else . end )
        ] | from_entries' | tr -d '\r') || [[ -z "$json" ]]; then
        echo '{"error": "status block not parseable"}'
        return 1
    fi
    if [[ "$json" == "{}" ]]; then
        # Delimiters with no KEY: value line between them carry no status.
        echo '{"error": "no status block"}'
        return 1
    fi

    echo "$json"
}

# status_count JSON KEY [DEFAULT] - a counter out of a parse_status_block
# object. Everything in a status block is agent text, and [[ -gt ]], (( )) and
# $(( )) evaluate their operands as arithmetic: a value such as a[$(cmd)] RUNS
# cmd in this script, outside the tool list the agent was given. So every
# counter is read through here and nowhere else. Prints the value when it is a
# plain decimal of at most 9 digits, DEFAULT (0 when not given) for anything
# else - missing, negative, text, a boolean. Always returns 0.
status_count() {
    local v
    v=$(printf '%s' "$1" | jq -r --arg k "$2" '.[$k] // empty | tostring' 2>/dev/null | tr -d '\r') || v=""
    if [[ "$v" =~ ^[0-9]{1,9}$ ]]; then
        echo "$((10#$v))"
    else
        echo "${3:-0}"
    fi
}

# Emit one file of the source dump, and say so when it was cut at the line cap.
# Without the notice an agent reports the cut as an unclosed block, or approves
# logic whose second half it never saw. The "=== FILE: " marker format is read
# by the chunk driver's scope check; do not change it.
dump_file() {
    local rel="$1"
    local path="$2"
    local max="$3"
    local total

    printf '\n=== FILE: %s ===\n' "$rel"
    head -n "$max" "$path" 2>/dev/null || true
    # grep -c '' also counts a last line that has no trailing newline.
    total=$(grep -c '' "$path" 2>/dev/null || true)
    if [[ "${total:-0}" -gt "$max" ]]; then
        printf '\n[... FILE TRUNCATED BY THE REVIEW TOOL: only the first %s of %s lines are shown above ...]\n' "$max" "$total"
    fi
}

# Collect only the files with uncommitted changes (--changed-only).
#
# `git status --porcelain` emits paths relative to the REPOSITORY ROOT, which is
# not necessarily the target directory - a target can sit several levels below
# its repo root. Resolve every path against the root, then keep only the files
# that actually live under the target. Files are included up to 3000 lines each
# (not MAX_SOURCE_LINES): a changed set is small, and cutting a diff under
# review at 500 lines defeats the point. dump_file marks a file that was cut.
collect_changed_files() {
    local target_dir="$1"
    local max_lines="${2:-3000}"
    local output=""
    local repo_root
    local abs_target

    if ! repo_root=$(git -C "$target_dir" rev-parse --show-toplevel 2>/dev/null); then
        # stderr: this function's stdout is the source dump itself.
        log_error "--changed-only requires the target to be inside a git repository" >&2
        return 1
    fi

    # Reached from the repo root that git reports, as every changed file is
    # below, so both sides are in the same path form. Taken from $target_dir
    # itself, a target given through a mount (Git Bash's /tmp) never matched
    # the drive form git reports, and every file was "outside the target".
    local prefix
    prefix=$(git -C "$target_dir" rev-parse --show-prefix 2>/dev/null) || prefix=""
    abs_target="$(cd "$repo_root/$prefix" 2>/dev/null && pwd -P)" || {
        log_error "--changed-only: cannot resolve $target_dir inside $repo_root" >&2
        return 1
    }
    log_verbose "Collecting changed files (repo root: $repo_root)"

    # NUL-delimited records, every untracked file listed individually. The plain
    # format reports a new directory as one "dir/" entry, which is not a file,
    # so everything inside it was dropped; it also C-quotes unusual names.
    local entry xy rel path canon in_target
    while IFS= read -r -d '' entry; do
        xy="${entry:0:2}"
        rel="${entry:3}"
        # A rename or copy is "XY new\0old\0": consume and drop the old path.
        if [[ "$xy" == *[RC]* ]]; then
            IFS= read -r -d '' _ || true
        fi
        [[ -z "$rel" ]] && continue
        path="$repo_root/$rel"
        # A symlink is never followed: one inside the target can point at any
        # file on the machine, and dump_file would send that file to both
        # agents. The directory walk (find -type f) skips links as well.
        if [[ -L "$path" ]]; then
            log_verbose "Skipping symlink: $rel"
            continue
        fi
        [[ -f "$path" ]] || continue

        case "${rel##*.}" in
            png|jpg|jpeg|gif|ico|icns|ttf|woff|woff2|xlsx|xls|zip|jar|class|exe|dll|pdf|so|dylib)
                log_verbose "Skipping binary: $rel"
                continue
                ;;
        esac

        # Normalise to the shell's path form before comparing; git may report a
        # Windows-style root while $PWD is POSIX-style. pwd -P resolves links,
        # on both sides, so a file reached through a linked directory is
        # judged by where it really is.
        canon="$(cd "$(dirname "$path")" 2>/dev/null && pwd -P)" || continue
        case "$canon/" in
            "$abs_target"/*) ;;
            *) log_verbose "Skipping (outside target): $rel"; continue ;;
        esac

        # The same exclusions as the directory walk. Changed files used to be
        # dumped whatever they were: an untracked .env.local, or a vendored
        # tree the user had excluded, went to both external agents. The path
        # filters are tested relative to the target, as walk_target does, so a
        # target that itself sits under a hidden or build directory still
        # yields its files; MAX_SOURCE_EXCLUDE sees the target path the walk
        # would print plus that relative path.
        in_target="${canon#"$abs_target"}/${path##*/}"
        in_target="${in_target#/}"
        case "/$in_target" in
            */.?*|*/node_modules/*|*/target/*|*/build/*|*/__pycache__/*|*/venv/*)
                log_verbose "Skipping (filtered path): $rel"
                continue
                ;;
        esac
        if [[ -n "$MAX_SOURCE_EXCLUDE" ]] \
           && grep -Eq -- "$MAX_SOURCE_EXCLUDE" <<< "$target_dir/$in_target"; then
            log_verbose "Skipping (MAX_SOURCE_EXCLUDE): $rel"
            continue
        fi

        log_verbose "Including changed file: $rel"
        output+="$(dump_file "$rel" "$path" "$max_lines")"$'\n'
    done < <(git -C "$target_dir" status --porcelain=v1 -z --untracked-files=all)

    if [[ -z "$output" ]]; then
        log_warning "No changed files found under $target_dir" >&2
    fi

    echo "$output"
}

# Drop paths matching MAX_SOURCE_EXCLUDE. A no-op filter when it is unset, so
# the find pipelines below can pipe through it unconditionally.
filter_excluded() {
    if [[ -z "$MAX_SOURCE_EXCLUDE" ]]; then
        cat
    else
        grep -Ev "$MAX_SOURCE_EXCLUDE" || true
    fi
}

# find, with its path tests applied to the path RELATIVE to the target, printing
# absolute paths. Run against the absolute path, `! -path "*/.*"` also matched
# the target's own ancestors: a target under ~/.claude/worktrees/x, or under a
# directory named target or build, yielded no files at all. Here find starts at
# "." so only directories inside the target can match; "*/.?*" skips hidden
# entries without matching that leading "./". The prefix is put back so
# MAX_SOURCE_EXCLUDE still sees absolute paths (ENVIRON, not -v: awk -v would
# interpret backslashes in the path).
walk_target() {
    local dir="$1"
    shift
    (cd "$dir" && find . "$@" 2>/dev/null) \
        | AR_WALK_PREFIX="$dir/" awk '{ sub(/^\.\//, ""); print ENVIRON["AR_WALK_PREFIX"] $0 }'
}

# Collect source code from target directory
collect_source_code() {
    local target_dir="$1"
    local max_files="${2:-$MAX_SOURCE_FILES}"
    local max_lines="${3:-$MAX_SOURCE_LINES}"
    local output=""
    local count=0

    if [[ "$CHANGED_ONLY" == "1" ]]; then
        collect_changed_files "$target_dir" || return 1
        return 0
    fi

    # Review exactly the listed files (blank lines and # comments ignored).
    # Unlike MAX_SOURCE_EXCLUDE this can restrict to scattered files, which a
    # feature cutting across several directories or repos needs, and it can
    # split a single directory, which a chunk manifest cannot. Any file type is
    # accepted, so it is also the way to review a language the walk below skips.
    if [[ -n "$SOURCE_FILE_LIST" ]]; then
        if [[ ! -f "$SOURCE_FILE_LIST" ]]; then
            log_error "SOURCE_FILE_LIST not found: $SOURCE_FILE_LIST" >&2
            return 1
        fi
        local rel
        while IFS= read -r rel || [[ -n "$rel" ]]; do
            rel="${rel%$'\r'}"
            [[ -z "$rel" || "$rel" == \#* ]] && continue
            if [[ ! -f "$target_dir/$rel" ]]; then
                # stderr: this function's stdout is the source dump itself.
                log_warning "SOURCE_FILE_LIST: missing $rel" >&2
                continue
            fi
            output+="$(dump_file "$rel" "$target_dir/$rel" "$max_lines")"$'\n'
        done < "$SOURCE_FILE_LIST"
        echo "$output"
        return 0
    fi

    log_verbose "Collecting source code from $target_dir"

    # Java
    count=0
    while IFS= read -r file && [[ $count -lt $max_files ]]; do
        [[ -z "$file" ]] && continue
        # The prefix is quoted so glob characters in the target path are literal,
        # and the counter avoids ((count++)), which returns 1 from 0 under set -e.
        local rel="${file#"$target_dir"/}"
        output+="$(dump_file "$rel" "$file" "$max_lines")"$'\n'
        count=$((count + 1))
    done < <(walk_target "$target_dir" -name "*.java" -type f ! -path "*/.?*" ! -path "*/target/*" ! -path "*/build/*" | filter_excluded | sort)

    # Python files
    count=0
    while IFS= read -r file && [[ $count -lt $max_files ]]; do
        [[ -z "$file" ]] && continue
        local rel="${file#"$target_dir"/}"
        output+="$(dump_file "$rel" "$file" "$max_lines")"$'\n'
        count=$((count + 1))
    done < <(walk_target "$target_dir" -name "*.py" -type f ! -path "*/.?*" ! -path "*/__pycache__/*" ! -path "*/venv/*" | filter_excluded | sort)

    # TypeScript/JavaScript
    count=0
    while IFS= read -r file && [[ $count -lt $max_files ]]; do
        [[ -z "$file" ]] && continue
        local rel="${file#"$target_dir"/}"
        output+="$(dump_file "$rel" "$file" "$max_lines")"$'\n'
        count=$((count + 1))
    done < <(walk_target "$target_dir" \( -name "*.ts" -o -name "*.tsx" -o -name "*.js" -o -name "*.jsx" \) -type f ! -path "*/node_modules/*" ! -path "*/.?*" | filter_excluded | sort)

    # Shell scripts
    count=0
    while IFS= read -r file && [[ $count -lt $MAX_SOURCE_SHELL_FILES ]]; do
        [[ -z "$file" ]] && continue
        local rel="${file#"$target_dir"/}"
        output+="$(dump_file "$rel" "$file" "$MAX_SOURCE_SHELL_LINES")"$'\n'
        count=$((count + 1))
    done < <(walk_target "$target_dir" -name "*.sh" -type f ! -path "*/.?*" | filter_excluded | sort)

    echo "$output"
}

# Run Claude
run_claude() {
    local prompt="$1"
    local output_file="$2"
    local working_dir="${3:-$PWD}"
    local with_permissions="${4:-false}"

    if [[ "$DRY_RUN" == "1" ]]; then
        log_claude "[DRY RUN] Would run Claude (${#prompt} chars) -> $output_file"
        echo "DRY RUN: Claude output" > "$output_file"
        return 0
    fi

    log_claude "Running..."

    set_timeout_words $((TIMEOUT_MINUTES * 60))

    # Every call names its tools. Fix mode may read and edit files; every other
    # call may only read. --tools removes all other built-in tools (no Bash at
    # all, whatever the user's settings allow) and --allowedTools pre-approves
    # the ones that are left, which --print needs because nobody is there to
    # answer a permission prompt. CLAUDE_ISOLATION_ARGS keeps the target's own
    # settings, hooks and MCP servers out of the call.
    local tools="$READ_ONLY_TOOLS"
    [[ "$with_permissions" == "true" ]] && tools="$FIX_MODE_TOOLS"
    local cmd_args=(--print --tools "$tools" --allowedTools "$tools" "${CLAUDE_ISOLATION_ARGS[@]}")

    # stderr goes to a log, not into the artifact: CLI warnings used to become
    # review text and were handed to the next phase as if the agent had said them.
    local claude_log="$LOGS_DIR/$(basename "${output_file%.md}").claude.log"
    mkdir -p "$LOGS_DIR"

    # ${a[@]+"${a[@]}"}: an empty array is "unbound" under set -u before bash 4.4.
    local exit_code=0
    (cd "$working_dir" && echo "$prompt" | ${TIMEOUT_WORDS[@]+"${TIMEOUT_WORDS[@]}"} claude "${cmd_args[@]}") > "$output_file" 2> "$claude_log" || exit_code=$?

    # A failed or silent call must stay recognisable now that stderr is no
    # longer in the artifact, wherever the CLI printed its refusal. Same shape
    # as run_codex's note: lib/transient.sh reads the first line to tell a
    # failed call from a review, and the quoted lines to tell a quota or network
    # failure (worth waiting out) from any other. Whatever the call did print is
    # moved to the log, so nothing is lost and a half-written review cannot be
    # parsed as a finished one.
    if [[ $exit_code -ne 0 || ! -s "$output_file" ]]; then
        log_warning "Claude produced no usable output; recording the failure (output kept in $claude_log)"
        {
            echo
            echo "--- stdout of the failed call (exit code $exit_code) ---"
            cat "$output_file" 2>/dev/null
        } >> "$claude_log"
        {
            echo "CLAUDE PRODUCED NO OUTPUT (exit code $exit_code)"
            echo
            echo "Matching lines from its output $claude_log :"
            # Wider than run_codex's list: Claude's own refusal reads "You've hit
            # your session limit", which none of those words matches, and the
            # network failures name an errno. Lines are cut so the note stays
            # under TRANSIENT_SHORT_MAX_BYTES.
            grep -aiE "error|limit|quota|refus|timed out|overloaded|resets [0-9]|reach the API|ENOTFOUND|EAI_AGAIN|ECONN|ETIMEDOUT|disconnected" "$claude_log" 2>/dev/null | tail -n 5 | cut -c 1-240 || true
        } > "$output_file"
        [[ $exit_code -eq 0 ]] && exit_code=1
    fi

    if [[ $exit_code -eq 0 ]]; then
        log_claude "Complete ($(wc -l < "$output_file" | tr -d ' ') lines)"
    else
        log_warning "Claude: $(describe_exit $exit_code)"
    fi

    return $exit_code
}

# Run Codex
run_codex() {
    local prompt="$1"
    local output_file="$2"
    local working_dir="${3:-$PWD}"

    if [[ "$DRY_RUN" == "1" ]]; then
        log_codex "[DRY RUN] Would run Codex (${#prompt} chars) -> $output_file"
        echo "DRY RUN: Codex output" > "$output_file"
        return 0
    fi

    log_codex "Running..."

    # A file left at this path by an earlier run must not stand in for this
    # call's answer: the "no final message" test below is `! -s`, which a stale
    # artifact satisfies, and it would then be parsed as this run's review.
    rm -f "$output_file"

    set_timeout_words $((TIMEOUT_MINUTES * 60))

    # codex >= 0.30 uses the `exec` subcommand; the old `-q --full-auto --prompt` form is gone.
    # The prompt is piped on stdin rather than passed as an argument: the phase-1 source dump
    # easily exceeds the ~32KB Windows CreateProcess command-line limit.
    # read-only sandbox is correct here - only phase 4 (Claude) is allowed to modify files.
    #
    # -o/--output-last-message is load-bearing, not a nicety: `codex exec` echoes the whole
    # prompt plus a banner to stdout, and our prompts contain EXAMPLE status blocks. Capturing
    # stdout would feed those examples to parse_status_block, which would take one as the
    # agent's status. -o writes only the agent's final message.
    local codex_bin="${CODEX_BIN:-codex}"
    local codex_log="$LOGS_DIR/$(basename "${output_file%.md}").codex.log"

    # NEVER pass a path containing spaces to codex. On Windows the npm codex.cmd
    # shim re-expands %* and loses the quoting, so cmd.exe tries to execute the
    # first fragment and dies with "'C:\Users\Alfonso' is not recognized...".
    # Artifact paths contain spaces on any normal Windows user account, so hand
    # codex a space-free temp path for -o and move the result into place with
    # bash, which quotes correctly. The prompt goes on stdin, so it is unaffected.
    local codex_tmp
    codex_tmp="$(mktemp -t ar_codex_XXXXXX 2>/dev/null || echo "/tmp/ar_codex_$$_$RANDOM")"
    case "$codex_tmp" in
        *" "*) log_warning "Temp path contains spaces - codex may fail: $codex_tmp" ;;
    esac

    local codex_args=(exec --sandbox read-only --skip-git-repo-check -o "$codex_tmp" -)

    mkdir -p "$LOGS_DIR"

    local exit_code=0
    (cd "$working_dir" && printf '%s' "$prompt" | ${TIMEOUT_WORDS[@]+"${TIMEOUT_WORDS[@]}"} "$codex_bin" "${codex_args[@]}") > "$codex_log" 2>&1 || exit_code=$?

    # The final-message file is the review only when codex also exited 0. A
    # call that failed part-way can leave a partial answer there; taken as the
    # review it made a dead agent a full participant in the debate. It is kept
    # in the transcript for diagnosis and the failure note below is written.
    if [[ $exit_code -eq 0 && -s "$codex_tmp" ]]; then
        mv "$codex_tmp" "$output_file"
    elif [[ -s "$codex_tmp" ]]; then
        {
            echo
            echo "--- final message of the failed call (exit code $exit_code) ---"
            cat "$codex_tmp"
        } >> "$codex_log"
    fi
    rm -f "$codex_tmp"

    # Codex died before writing the final message, or exited non-zero. Record a short, explicit note rather than copying the transcript:
    # the transcript is the prompt echoed back plus the agent's reasoning, so as an artifact it would feed the next
    # phase 100-200 KB of noise and hand parse_status_block the EXAMPLE status block out of the prompt template -
    # which reads as "0 issues found" and is indistinguishable from a clean review. A quota refusal used to be
    # archived that way, with the chunk counted as done and only one agent in the debate. The transcript stays in
    # logs/ for diagnosis, and this note is short enough for artifact_is_transient_failure to recognise.
    if [[ ! -s "$output_file" ]]; then
        log_warning "Codex produced no final message; recording the failure (transcript kept in $codex_log)"
        {
            echo "CODEX PRODUCED NO FINAL MESSAGE (exit code $exit_code)"
            echo
            echo "Matching lines from the transcript $codex_log :"
            # Each quoted line is cut, as in run_claude's note, and the note is
            # capped as a whole below: one long JSON or rg line in the
            # transcript pushed it past TRANSIENT_SHORT_MAX_BYTES, and a quota
            # refusal was then retried at once instead of waited out. `|| true`:
            # under pipefail a grep that matched nothing ended run_codex here,
            # leaving the note half written and the real exit code unreported.
            grep -aiE "error|usage limit|rate.?limit|quota|refus|timed out" "$codex_log" 2>/dev/null | tail -n 5 | cut -c 1-200 || true
            echo
            echo "Last lines of the transcript:"
            tail -n 3 "$codex_log" 2>/dev/null | cut -c 1-200 || true
        } > "$output_file"
        # 8 cut lines plus the headers can still exceed the limit when the log
        # path is long. head reads the file, not a pipe, so pipefail is not
        # involved; the first line is far shorter than the cap and survives.
        if [[ $(wc -c < "$output_file") -gt 1800 ]]; then
            head -c 1800 "$output_file" > "$output_file.cut" && mv -f "$output_file.cut" "$output_file"
            echo >> "$output_file"
        fi
        [[ $exit_code -eq 0 ]] && exit_code=1
    fi

    if [[ $exit_code -eq 0 ]]; then
        log_codex "Complete ($(wc -l < "$output_file" | tr -d ' ') lines)"
    else
        log_warning "Codex: $(describe_exit $exit_code)"
    fi

    return $exit_code
}

# ============================================================================
# Agent orchestration helpers
# ============================================================================

# Portable SHA-256 over stdin. macOS has shasum, most Linux has sha256sum,
# Git Bash has both (shasum only via core_perl).
sha256_hash() {
    if command -v sha256sum &> /dev/null; then
        sha256sum | cut -d' ' -f1
    elif command -v shasum &> /dev/null; then
        shasum -a 256 | cut -d' ' -f1
    else
        cksum | cut -d' ' -f1
    fi
}

# 124 is timeout's own code. 137 (128 + KILL) is what it returns when the agent
# ignored TERM and -k had to kill it; a kill -9 from outside looks the same.
describe_exit() {
    if [[ "$1" -eq 124 ]]; then
        echo "timed out after ${TIMEOUT_MINUTES}m"
    elif [[ "$1" -eq 137 ]]; then
        echo "killed (exit code 137): timed out after ${TIMEOUT_MINUTES}m and ignored TERM, or was killed from outside"
    else
        echo "exit code $1"
    fi
}

# Wait on a parallel Claude/Codex pair and surface failures.
# Exit codes used to be discarded with `wait || true`, which made a crashed or
# timed-out agent indistinguishable from a clean review: the artifact has no
# status block, so it parses to 0 issues and the loop burns iterations on
# garbage. Returns non-zero only when BOTH agents failed. A single failure is
# logged here and stops the run one step later: run_review_loop checks the
# artifacts with iteration_has_failed_call after each of phases 1 to 3.
wait_for_agents() {
    local claude_pid="$1"
    local codex_pid="$2"
    local phase="$3"
    local claude_rc=0
    local codex_rc=0

    # Tracked so an INT/TERM can stop exactly these jobs (see stop_agents).
    AGENT_PIDS=("$claude_pid" "$codex_pid")

    wait "$claude_pid" || claude_rc=$?
    wait "$codex_pid" || codex_rc=$?
    AGENT_PIDS=()

    [[ $claude_rc -ne 0 ]] && log_error "Claude failed in $phase ($(describe_exit $claude_rc))"
    [[ $codex_rc -ne 0 ]] && log_error "Codex failed in $phase ($(describe_exit $codex_rc))"

    if [[ $claude_rc -ne 0 && $codex_rc -ne 0 ]]; then
        log_error "Both agents failed in $phase - aborting iteration"
        return 1
    fi
    return 0
}

# A debate needs both agents. One failed call used to degrade to a warning, and
# its failure note was then handed to the other agent as "the review to
# analyse": the run ended report_only, exit 0, with one voice in it. True when
# any phase 1-3 artifact of iteration $1 is a failed call (an empty file, an
# agent's failure note, a quota/network refusal, or a reply without its
# phase's status block - lib/transient.sh). A dry-run stub has no status block
# by design, so in a dry run the stub lines run_claude/run_codex write are
# skipped here; the library's rule itself is not relaxed.
iteration_has_failed_call() {
    local f
    for f in "$ARTIFACTS_DIR"/iter"$1"_[123]_*.md; do
        [[ -f "$f" ]] || continue
        if [[ "$DRY_RUN" == "1" ]] \
           && grep -qFx -e "DRY RUN: Claude output" -e "DRY RUN: Codex output" "$f" 2>/dev/null; then
            continue
        fi
        if artifact_is_failed_call "$f"; then
            log_error "Failed agent call: $f"
            return 0
        fi
    done
    return 1
}

# Fingerprint the ISSUES in a set of reviews, not their prose.
# The old implementation hashed the raw review text, which never repeats
# byte-for-byte across iterations because LLM wording varies. That silently
# disabled the circuit breaker's same-issues trigger. Fingerprinting the set of
# referenced source locations is stable across rewordings; line numbers are
# stripped because they shift as fixes are applied.
#
# The extension is anchored with \b: without it "config.json" matched as
# "config.js". An empty path set prints nothing rather than the hash of nothing,
# which was the same value every time and so counted two reviews that named no
# file as "the same issues"; record_iteration_result skips an empty hash.
issues_fingerprint() {
    local paths
    paths=$(cat "$@" 2>/dev/null \
        | grep -oiE '[A-Za-z0-9_./-]+\.(py|ts|tsx|js|jsx|sh|go|rs|java|rb|c|h|cpp|hpp|cs|php|swift|kt)(:[0-9]+)?\b' \
        | sed 's/:[0-9]*$//' \
        | tr '[:upper:]' '[:lower:]' \
        | sort -u || true)
    if [[ -n "$paths" ]]; then
        printf '%s\n' "$paths" | sha256_hash
    fi
}

# Hash of the target's state, used to detect whether phase 4 actually changed
# anything rather than trusting the agent's self-report. Echoes "no-git" when
# the target is not a git repository.
#
# HEAD is part of it because an agent that commits its own work leaves a clean
# status and empty diffs, which read as "nothing changed". Untracked files are
# hashed by content because `status` only lists their names: an edit to a file
# that was already untracked changed nothing here. That costs one read of every
# untracked, non-ignored file under the target, twice per iteration.
target_state_hash() {
    local dir="$1"
    if git -C "$dir" rev-parse --git-dir &> /dev/null; then
        {
            # Everything is limited to the target. A target is often a
            # subdirectory of a larger repository (a chunk's module), and any
            # change elsewhere in it, during the synthesis call, read as
            # progress in fix mode and as "the target changed" in report-only
            # mode. HEAD:./ is the committed tree of the target directory
            # itself, so a commit touching only other directories leaves it
            # alone; it fails while the target is not in HEAD yet, which
            # prints nothing and stays stable. ls-files lists only files under
            # its working directory.
            git -C "$dir" rev-parse HEAD:./ || true
            git -C "$dir" status --porcelain --untracked-files=all -- .
            git -C "$dir" diff -- .
            git -C "$dir" diff --cached -- .
            (cd "$dir" && git ls-files -z --others --exclude-standard -- . | xargs -0 -r cksum) || true
        } 2>/dev/null | sha256_hash
    else
        echo "no-git"
    fi
}

# What a debate was about: the canonical target path and a hash of the source
# dump its phase 1 was given. Written at the end of phase 1 and checked by
# verify_resume_artifacts, because the artifact names (iter1_...) say nothing
# about either - a debate left by another target, another chunk or an older
# state of the code was otherwise resumed as if it were this one. Not a .md
# file on purpose: everything that loops over artifacts/*.md ignores it.
SCOPE_STAMP_FILE="$ARTIFACTS_DIR/scope.stamp"

source_dump_hash() {
    printf '%s' "$1" | sha256_hash
}

write_scope_stamp() {
    local target_dir="$1"
    local source_code="$2"
    {
        printf '%s\n' "$target_dir"
        source_dump_hash "$source_code"
    } > "$SCOPE_STAMP_FILE.tmp" && mv "$SCOPE_STAMP_FILE.tmp" "$SCOPE_STAMP_FILE"
}

# CONSENSUS_REACHED is coerced by parse_status_block: YES becomes boolean true,
# PARTIAL and NO stay strings. Accept only unambiguous agreement.
consensus_is_yes() {
    local file="$1"
    local block
    block=$(parse_status_block "$file" "META_REVIEW_STATUS" 2>/dev/null || echo '{}')
    local value
    value=$(echo "$block" | jq -r '.consensus_reached // "NO"' 2>/dev/null || echo "NO")
    [[ "$value" == "true" || "$value" == "YES" ]]
}

# ============================================================================
# PHASE 1: Independent Reviews
# ============================================================================
run_phase_1() {
    local target_dir="$1"
    local iteration="$2"

    log_info "=== Phase 1: Independent Reviews ==="

    # Declared and assigned separately: `local x=$(...)` returns the status of
    # `local`, which hid a failed collection. A dump with no file in it is also
    # refused - two agents answering NO_ISSUES about nothing would otherwise be
    # recorded as a clean review.
    local source_code
    if ! source_code=$(collect_source_code "$target_dir"); then
        log_error "Source collection failed - nothing was sent to the agents"
        return 3
    fi
    if [[ "$source_code" != *"=== FILE: "* ]]; then
        log_error "No source files in scope under $target_dir - nothing to review"
        return 3
    fi

    local prompt_template
    if ! prompt_template=$(cat "$INITIAL_PROMPT_FILE"); then
        log_error "Cannot read the phase-1 prompt: $INITIAL_PROMPT_FILE"
        return 3
    fi

    local full_prompt="$prompt_template

---
# SOURCE CODE TO REVIEW

$source_code
"

    local claude_out="$ARTIFACTS_DIR/iter${iteration}_1_claude_review.md"
    local codex_out="$ARTIFACTS_DIR/iter${iteration}_1_codex_review.md"

    # Run in parallel
    run_claude "$full_prompt" "$claude_out" "$target_dir" &
    local claude_pid=$!

    run_codex "$full_prompt" "$codex_out" "$target_dir" &
    local codex_pid=$!

    if ! wait_for_agents "$claude_pid" "$codex_pid" "phase 1"; then
        return 2  # Both agents dead - caller aborts the iteration
    fi

    # Record what this debate is about, for a later --from-phase.
    write_scope_stamp "$target_dir" "$source_code"

    # Parse results
    local claude_status=$(parse_status_block "$claude_out" "REVIEW_STATUS")
    local codex_status=$(parse_status_block "$codex_out" "REVIEW_STATUS")

    local claude_exit=$(echo "$claude_status" | jq -r '.exit_signal // false')
    local codex_exit=$(echo "$codex_status" | jq -r '.exit_signal // false')

    add_to_history "$iteration" "phase_1" "claude" "$claude_status"
    add_to_history "$iteration" "phase_1" "codex" "$codex_status"

    # "unknown" when the count is missing or not a number; only compared as a
    # string below, never as a number.
    local claude_issues codex_issues
    claude_issues=$(status_count "$claude_status" issues_found unknown)
    codex_issues=$(status_count "$codex_status" issues_found unknown)

    # Clean means both say so AND both count zero issues. EXIT_SIGNAL alone
    # used to end the run as clean with "ISSUES_FOUND: 3" in both blocks.
    if [[ "$claude_exit" == "true" && "$codex_exit" == "true" \
          && "$claude_issues" == "0" && "$codex_issues" == "0" ]]; then
        log_success "Both agents report NO_ISSUES"
        return 0  # Signal clean exit
    fi
    if [[ "$claude_exit" == "true" && "$codex_exit" == "true" ]]; then
        log_warning "Both agents set EXIT_SIGNAL but do not both report zero issues - continuing the debate"
    fi

    log_info "Claude found: $claude_issues issues"
    log_info "Codex found: $codex_issues issues"

    return 1  # Continue to next phase
}

# ============================================================================
# PHASE 2: Cross-Review
# ============================================================================
run_phase_2() {
    local target_dir="$1"
    local iteration="$2"

    log_info "=== Phase 2: Cross-Review ==="

    local claude_review="$ARTIFACTS_DIR/iter${iteration}_1_claude_review.md"
    local codex_review="$ARTIFACTS_DIR/iter${iteration}_1_codex_review.md"

    local cross_prompt=$(cat "$PROMPTS_DIR/cross_review.md")

    # The source must be in context here. cross_review.md asks the agent to verify
    # findings rather than accept them, and to add issues the other agent missed -
    # neither is possible from the other agent's prose alone.
    local source_code
    if ! source_code=$(collect_source_code "$target_dir"); then
        log_error "Source collection failed - nothing was sent to the agents"
        return 3
    fi
    if [[ "$source_code" != *"=== FILE: "* ]]; then
        log_error "No source files in scope under $target_dir - nothing to review"
        return 3
    fi

    # Claude reviews Codex
    local claude_prompt="$cross_prompt

---
# THE OTHER AGENT'S REVIEW TO ANALYZE

$(cat "$codex_review")

---
# SOURCE CODE (verify their findings against this)

$source_code
"

    # Codex reviews Claude
    local codex_prompt="$cross_prompt

---
# THE OTHER AGENT'S REVIEW TO ANALYZE

$(cat "$claude_review")

---
# SOURCE CODE (verify their findings against this)

$source_code
"

    local claude_out="$ARTIFACTS_DIR/iter${iteration}_2_claude_on_codex.md"
    local codex_out="$ARTIFACTS_DIR/iter${iteration}_2_codex_on_claude.md"

    # Pass target_dir explicitly: omitting it defaulted working_dir to $PWD, so
    # cross-review ran against the adversarial-review repo instead of the target.
    run_claude "$claude_prompt" "$claude_out" "$target_dir" &
    local claude_pid=$!

    run_codex "$codex_prompt" "$codex_out" "$target_dir" &
    local codex_pid=$!

    if ! wait_for_agents "$claude_pid" "$codex_pid" "phase 2"; then
        return 2
    fi

    local claude_status=$(parse_status_block "$claude_out" "CROSS_REVIEW_STATUS")
    local codex_status=$(parse_status_block "$codex_out" "CROSS_REVIEW_STATUS")

    add_to_history "$iteration" "phase_2" "claude" "$claude_status"
    add_to_history "$iteration" "phase_2" "codex" "$codex_status"

    log_success "Cross-review complete"
    return 0
}

# ============================================================================
# PHASE 3: Meta-Review
# ============================================================================
run_phase_3() {
    local target_dir="$1"
    local iteration="$2"

    log_info "=== Phase 3: Meta-Review ==="

    local claude_review="$ARTIFACTS_DIR/iter${iteration}_1_claude_review.md"
    local codex_review="$ARTIFACTS_DIR/iter${iteration}_1_codex_review.md"
    local codex_on_claude="$ARTIFACTS_DIR/iter${iteration}_2_codex_on_claude.md"
    local claude_on_codex="$ARTIFACTS_DIR/iter${iteration}_2_claude_on_codex.md"

    local meta_prompt=$(cat "$PROMPTS_DIR/meta_review.md")

    # Each agent MUST be shown its own phase-1 review. Every agent call is a fresh
    # stateless CLI invocation with no session continuity, so without this the
    # prompt asks an agent to defend or concede positions it has never seen and
    # can only infer from its critic's paraphrase. This is the step that produces
    # CONSENSUS_REACHED, which drives the circuit breaker.
    local claude_prompt="$meta_prompt

---
# YOUR ORIGINAL REVIEW (the positions you are defending or conceding)

$(cat "$claude_review")

---
# FEEDBACK ON YOUR ORIGINAL REVIEW

$(cat "$codex_on_claude")
"

    local codex_prompt="$meta_prompt

---
# YOUR ORIGINAL REVIEW (the positions you are defending or conceding)

$(cat "$codex_review")

---
# FEEDBACK ON YOUR ORIGINAL REVIEW

$(cat "$claude_on_codex")
"

    local claude_out="$ARTIFACTS_DIR/iter${iteration}_3_claude_meta.md"
    local codex_out="$ARTIFACTS_DIR/iter${iteration}_3_codex_meta.md"

    run_claude "$claude_prompt" "$claude_out" "$target_dir" &
    local claude_pid=$!

    run_codex "$codex_prompt" "$codex_out" "$target_dir" &
    local codex_pid=$!

    if ! wait_for_agents "$claude_pid" "$codex_pid" "phase 3"; then
        return 2
    fi

    local claude_status=$(parse_status_block "$claude_out" "META_REVIEW_STATUS")
    local codex_status=$(parse_status_block "$codex_out" "META_REVIEW_STATUS")

    add_to_history "$iteration" "phase_3" "claude" "$claude_status"
    add_to_history "$iteration" "phase_3" "codex" "$codex_status"

    log_success "Meta-review complete"
    return 0
}

# ============================================================================
# PHASE 4: Synthesis & Implementation
# ============================================================================
run_phase_4() {
    local target_dir="$1"
    local iteration="$2"

    if [[ "$NO_FIX" == "1" ]]; then
        log_info "=== Phase 4: Synthesis (report only - the target is not modified) ==="
    else
        log_info "=== Phase 4: Synthesis & Implementation (--fix: the agent may edit files in $target_dir) ==="
        log_warning "Fix mode gives the agent write access to the target (tools: $FIX_MODE_TOOLS). Use it on trusted code only."
    fi

    local synthesis_prompt=$(cat "$PROMPTS_DIR/synthesis.md")

    # Fix mode has file tools only. The template asks for tests to be run, which
    # needs a shell the agent does not have; say so rather than let it report
    # tests it could not have run.
    if [[ "$NO_FIX" != "1" ]]; then
        synthesis_prompt="# TOOLS AVAILABLE IN THIS RUN

You can read, search, edit and create files ($FIX_MODE_TOOLS). You have no
shell: you cannot run tests, builds or git. Where the instructions below say to
test a change, check it by reading the code instead, and report TESTS_RUN: NO
and TESTS_PASSING: N/A in the status block.

---

$synthesis_prompt"
    fi

    # Report-only mode. The override goes FIRST so it is read before the
    # implementation instructions it countermands, and the agent is additionally
    # denied write permissions below.
    if [[ "$NO_FIX" == "1" ]]; then
        synthesis_prompt="# REPORT-ONLY MODE - THIS OVERRIDES EVERY INSTRUCTION BELOW

Do NOT modify, create, or delete any file. Do not use Edit, Write, or any
shell command that writes. You are producing a written report only; the user
will decide what to act on.

Everything below describes how to weigh and prioritise the findings. Follow all
of it EXCEPT the instruction to implement fixes. Where it says to implement a
fix, instead describe the change you would make and show the concrete diff or
replacement code inline in your report.

In the status block, report FILES_MODIFIED: 0 and count the fixes you are
RECOMMENDING under HIGH_CONFIDENCE_FIXES / MEDIUM_CONFIDENCE_FIXES. Set
EXIT_SIGNAL: true - there is no follow-up iteration in report-only mode.

---

$synthesis_prompt"
    fi

    # Gather all artifacts
    local context="$synthesis_prompt

---
# ADVERSARIAL REVIEW CHAIN

## Phase 1: Independent Reviews

### Claude's Review
$(cat "$ARTIFACTS_DIR/iter${iteration}_1_claude_review.md")

### Codex's Review
$(cat "$ARTIFACTS_DIR/iter${iteration}_1_codex_review.md")

## Phase 2: Cross-Reviews

### Claude's Analysis of Codex
$(cat "$ARTIFACTS_DIR/iter${iteration}_2_claude_on_codex.md")

### Codex's Analysis of Claude
$(cat "$ARTIFACTS_DIR/iter${iteration}_2_codex_on_claude.md")

## Phase 3: Meta-Reviews

### Claude's Response
$(cat "$ARTIFACTS_DIR/iter${iteration}_3_claude_meta.md")

### Codex's Response
$(cat "$ARTIFACTS_DIR/iter${iteration}_3_codex_meta.md")

---
Working directory: $target_dir
"

    local output_file="$ARTIFACTS_DIR/iter${iteration}_4_synthesis.md"

    # Snapshot the target before synthesis so progress can be measured against
    # ground truth rather than the agent's self-report.
    local state_before=$(target_state_hash "$target_dir")

    # Report-only mode gets READ_ONLY_TOOLS instead of FIX_MODE_TOOLS (see
    # run_claude), so the prompt override is backed by an actual tool boundary.
    local allow_writes="true"
    [[ "$NO_FIX" == "1" ]] && allow_writes="false"

    # Run as a background job and wait on it, like phases 1-3. Bash defers a
    # trap until a foreground command returns, so with a foreground call an
    # INT/TERM would only be acted on after the synthesis had finished.
    local synth_rc=0
    run_claude "$context" "$output_file" "$target_dir" "$allow_writes" &
    local synth_pid=$!
    AGENT_PIDS=("$synth_pid")
    wait "$synth_pid" || synth_rc=$?
    AGENT_PIDS=()
    if [[ $synth_rc -ne 0 ]]; then
        if [[ "$NO_FIX" == "1" ]]; then
            log_error "Synthesis agent failed ($(describe_exit $synth_rc)) - no report was written"
        else
            log_error "Synthesis agent failed ($(describe_exit $synth_rc)) - it may have edited some files before failing; check the target"
        fi
    fi

    local state_after=$(target_state_hash "$target_dir")

    local status=$(parse_status_block "$output_file" "SYNTHESIS_STATUS")
    local exit_signal=$(echo "$status" | jq -r '.exit_signal // false')
    local reported_modified
    reported_modified=$(status_count "$status" files_modified)

    # Progress = did the target's working tree actually change. FILES_MODIFIED is
    # self-reported by the agent, and a missing status block parses to 0, which
    # reads as "no progress" and advances the breaker on a parsing failure rather
    # than a real stall. Fall back to the self-report only for non-git targets.
    local fixes_made=0
    if [[ "$state_before" == "no-git" ]]; then
        if [[ "$NO_FIX" != "1" ]]; then
            log_warning "Target is not a git repository - falling back to self-reported FILES_MODIFIED"
        fi
        fixes_made="$reported_modified"
    else
        if [[ "$state_before" != "$state_after" ]]; then
            fixes_made=1
            log_success "Target working tree changed (agent reported $reported_modified files)"
        else
            log_warning "Target working tree unchanged (agent reported $reported_modified files)"
        fi
    fi

    add_to_history "$iteration" "phase_4" "claude" "$status"

    if [[ "$NO_FIX" == "1" ]]; then
        if [[ "$state_before" == "no-git" ]]; then
            # Two identical "no-git" sentinels prove nothing about the files.
            log_warning "Report-only: cannot verify the target is untouched (not a git repository)"
        elif [[ "$state_before" != "$state_after" ]]; then
            log_error "Report-only mode but the target changed - inspect 'git status' in the target"
        else
            log_success "Report-only: target untouched"
        fi
    fi

    # A synthesis that timed out, was refused, or stopped before its status
    # block is not a result in either mode. It must not end a report-only run
    # as "Report complete", and in fix mode it must not be fed to the circuit
    # breaker as an iteration and followed by another seven-call debate on a
    # target that may be half edited (this check used to sit inside the
    # report-only branch). A dry run is exempt: its stub has no status block by
    # design.
    if [[ "$DRY_RUN" != "1" ]]; then
        if [[ $synth_rc -ne 0 ]] || artifact_is_failure_note "$output_file"; then
            log_error "Synthesis produced no usable result: $output_file"
            return 2
        fi
        if ! artifact_has_block "$output_file" "SYNTHESIS_STATUS"; then
            log_error "Synthesis has no complete SYNTHESIS_STATUS block - not a usable result: $output_file"
            return 2
        fi
    fi

    # Report-only mode stops here. Nothing was changed, so a further iteration
    # would re-review byte-identical code, and feeding a guaranteed zero-progress
    # result to the circuit breaker would leave it dirty for the next real run.
    if [[ "$NO_FIX" == "1" ]]; then
        log_success "Report written to $output_file"
        return 0
    fi

    # Consensus requires BOTH agents to say so. Reading only Claude's meta-review
    # let the breaker record agreement while Codex was still reporting NO.
    local agents_agree=0
    if consensus_is_yes "$ARTIFACTS_DIR/iter${iteration}_3_claude_meta.md" \
       && consensus_is_yes "$ARTIFACTS_DIR/iter${iteration}_3_codex_meta.md"; then
        agents_agree=1
    fi

    # Surface arbiter bias: Claude is both a debater and the judge here, so make
    # any lopsided accept/reject split visible instead of silent.
    local from_claude from_codex rej_claude rej_codex
    from_claude=$(status_count "$status" fixes_from_claude)
    from_codex=$(status_count "$status" fixes_from_codex)
    rej_claude=$(status_count "$status" rejected_from_claude)
    rej_codex=$(status_count "$status" rejected_from_codex)
    log_info "Arbiter split - accepted: Claude=$from_claude Codex=$from_codex | rejected: Claude=$rej_claude Codex=$rej_codex"
    if [[ "$rej_codex" -gt 0 && "$rej_codex" -gt $((rej_claude * 2 + 1)) ]]; then
        log_warning "Synthesis rejected disproportionately many Codex findings - possible self-preference bias"
    fi

    local issues_hash=$(issues_fingerprint \
        "$ARTIFACTS_DIR/iter${iteration}_1_claude_review.md" \
        "$ARTIFACTS_DIR/iter${iteration}_1_codex_review.md")

    record_iteration_result "$iteration" "$fixes_made" "$agents_agree" "$issues_hash"

    if [[ "$exit_signal" == "true" ]]; then
        log_success "Synthesis complete - no more issues"
        return 0
    fi

    if [[ "$fixes_made" -gt 0 ]]; then
        log_info "Fixes applied, will verify in next iteration"
    else
        log_info "No change to the target this iteration; reviewing again"
    fi
    return 1
}

# ============================================================================
# Main Review Loop
# ============================================================================
# Two concurrent runs share artifacts/, tracking.json and the circuit breaker.
# They silently overwrite each other's artifacts mid-phase, so a later phase can
# read a file that a different run has since replaced. Refuse to start a second
# run rather than produce a debate spliced from two of them.
# LOCK_FILE must be global: the EXIT trap fires after acquire_lock has returned,
# so a `local` would be out of scope and `set -u` would abort the trap with
# "lock_file: unbound variable", leaving the lock behind.
LOCK_FILE="$AR_DIR/.review.lock"
# BASHPID of the shell that wrote the lock. $$ is not enough: it keeps the
# parent's value inside the subshells that run the agents.
LOCK_OWNER_PID=""
# Background agent jobs of the phase in progress, for stop_agents.
AGENT_PIDS=()

# Remove the lock, but only from the process that took it and only while the
# file still names this run. A subshell, or a run whose stale lock was replaced
# by a newer review, must never delete a lock that is not its own.
release_lock() {
    [[ -n "$LOCK_OWNER_PID" && "$BASHPID" == "$LOCK_OWNER_PID" ]] || return 0
    local holder
    holder=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
    [[ "$holder" == "$$" ]] || return 0
    rm -f "$LOCK_FILE"
}

# The given pids and every live descendant of them, one "pid@starttime" per
# line. `ps -ef` has PID, PPID and STIME in columns 2, 3 and 5 on Linux, macOS
# and Git Bash alike. The start time is carried so a pid can be recognised as
# the same process later: Git Bash reuses pids within seconds.
agent_tree() {
    ps -ef 2>/dev/null | awk -v roots="$*" '
        BEGIN { n = split(roots, r, " "); for (i = 1; i <= n; i++) want[r[i]] = 1 }
        NR > 1 { pid[NR] = $2; ppid[NR] = $3; st[NR] = $5; dead[NR] = /<defunct>/ }
        END {
            do {
                grew = 0
                for (i in pid) if ((ppid[i] in want) && !(pid[i] in want)) {
                    want[pid[i]] = 1; grew = 1
                }
            } while (grew)
            for (i in pid) if ((pid[i] in want) && !dead[i]) print pid[i] "@" st[i]
        }' || true
}

# Stop the agents of the phase in progress. The tracked pids are the subshells
# running run_claude/run_codex; the CLI itself (and timeout) sits below them and
# would survive as an orphan still writing into artifacts/, so the descendants
# are collected first and signalled too. Tracked pids rather than `kill 0`: the
# chunk driver runs this script inside a pipeline and shares its process group.
#
# The wait is bounded and ends in KILL instead of a plain `wait`: on Git Bash a
# `timeout` whose child was signalled in the same instant can miss the child's
# exit and sit there until its own deadline, and this must never keep the
# script from exiting.
stop_agents() {
    [[ ${#AGENT_PIDS[@]} -gt 0 ]] || return 0
    local tree now e survivors tries=0
    tree=$(agent_tree "${AGENT_PIDS[@]}" | tr '\n' ' ')
    for e in $tree; do
        kill "${e%@*}" 2>/dev/null || true
    done
    while true; do
        # Only what is still the same process (same pid AND start time) counts.
        now=" $(ps -ef 2>/dev/null | awk 'NR > 1 && !/<defunct>/ { print $2 "@" $5 }' | tr '\n' ' ') "
        survivors=""
        for e in $tree; do
            [[ "$now" == *" $e "* ]] && survivors+=" ${e%@*}"
        done
        [[ -z "$survivors" ]] && break
        if [[ $tries -ge 3 ]]; then
            # shellcheck disable=SC2086  # word splitting is the point
            kill -9 $survivors 2>/dev/null || true
            break
        fi
        sleep 1
        tries=$((tries + 1))
    done
    AGENT_PIDS=()
}

# INT/TERM must end the run. The old single trap (`rm -f lock` on EXIT INT TERM)
# removed the lock on a signal and then returned, so the review carried on with
# nothing stopping a second one from starting. Exiting here runs the EXIT trap,
# which is the only place the lock is released.
on_signal() {
    local sig="$1"
    local code="$2"
    trap '' INT TERM
    log_error "Received $sig - stopping agents and exiting" >&2
    stop_agents
    exit "$code"
}

# Create the lock only if it does not exist. noclobber makes the shell open the
# file with O_EXCL, so of two reviews started in the same instant exactly one
# succeeds. The old "test -f, then echo" let both through.
write_lock() {
    ( set -o noclobber; echo $$ > "$LOCK_FILE" ) 2>/dev/null
}

read_lock_holder() {
    tr -d '[:space:]' < "$LOCK_FILE" 2>/dev/null || true
}

acquire_lock() {
    if ! write_lock; then
        # The lock exists. An empty one may be a lock another review is writing
        # at this very moment (created, pid not in it yet): give it a moment
        # before calling it stale.
        local holder="" tries=0
        while [[ $tries -lt 10 ]]; do
            holder=$(read_lock_holder)
            [[ -n "$holder" || ! -e "$LOCK_FILE" ]] && break
            sleep 0.2
            tries=$((tries + 1))
        done
        if [[ -n "$holder" ]] && kill -0 "$holder" 2>/dev/null; then
            log_error "A review is already running (pid $holder)"
            log_error "Concurrent runs corrupt each other's artifacts. Wait for it to"
            log_error "finish, or kill it and remove $LOCK_FILE"
            exit 1
        fi

        # Stale: its owner is dead. Clearing it is the one step noclobber cannot
        # make safe, since two reviews could each remove "the stale lock" and the
        # second would delete the first one's fresh lock. mkdir is atomic, so
        # only one of them gets to clear it, and it re-reads the lock first in
        # case another review replaced it in between.
        if ! mkdir "$LOCK_FILE.recover" 2>/dev/null; then
            log_error "Another review is clearing a stale lock right now - try again in a moment"
            log_error "(if no review is running, remove the directory $LOCK_FILE.recover)"
            exit 1
        fi
        if [[ "$(read_lock_holder)" != "$holder" ]]; then
            rmdir "$LOCK_FILE.recover" 2>/dev/null || true
            log_error "Another review took $LOCK_FILE first"
            exit 1
        fi
        log_warning "Removing stale lock left by pid ${holder:-unknown}"
        rm -f "$LOCK_FILE"
        if ! write_lock; then
            rmdir "$LOCK_FILE.recover" 2>/dev/null || true
            log_error "Another review took $LOCK_FILE first"
            exit 1
        fi
        rmdir "$LOCK_FILE.recover" 2>/dev/null || true
    fi

    LOCK_OWNER_PID="$BASHPID"
    trap release_lock EXIT
    trap 'on_signal INT 130' INT
    trap 'on_signal TERM 143' TERM
}

# The chunk drivers hold a second lock for their whole run: the directory
# .driver.lock, with the driver's pid in the file "pid". The review lock above
# is not enough for them, because it is free in the gap between two chunks while
# the driver is clearing or archiving artifacts/. A review the driver starts
# itself is recognised by AR_DRIVER_LOCK_PID, which the driver exports, or by
# being its direct child. A lock whose pid is dead is stale and blocks nothing;
# it is left for the next driver to clean up.
DRIVER_LOCK_DIR="$AR_DIR/.driver.lock"

# Print the pid of the live driver holding the lock; return 1 when there is none.
live_driver_pid() {
    local pid
    [[ -f "$DRIVER_LOCK_DIR/pid" ]] || return 1
    pid=$(tr -d '[:space:]' < "$DRIVER_LOCK_DIR/pid" 2>/dev/null || true)
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    echo "$pid"
}

refuse_foreign_driver() {
    local pid
    pid=$(live_driver_pid) || return 0
    [[ "$pid" == "${AR_DRIVER_LOCK_PID:-}" || "$pid" == "$PPID" ]] && return 0
    log_error "A chunk driver is running here (pid $pid holds $DRIVER_LOCK_DIR)"
    log_error "It clears and archives artifacts/ between its chunks, so a review started"
    log_error "now would be mixed into its output. Wait for it to finish, or run this"
    log_error "review from a separate git worktree."
    exit 1
}

# A --dry-run writes stub artifacts to the same paths as a real run, so starting
# one over a completed review destroys the report. Artifacts are the only copy:
# run_claude streams straight to the artifact file and keeps no transcript.
guard_existing_artifacts() {
    [[ "$DRY_RUN" == "1" ]] || return 0
    [[ -d "$ARTIFACTS_DIR" ]] || return 0

    local real_count
    real_count=$(grep -LFx "DRY RUN: Claude output" "$ARTIFACTS_DIR"/*.md 2>/dev/null \
                 | xargs -r -I{} grep -LFx "DRY RUN: Codex output" {} 2>/dev/null | grep -c . || true)

    if [[ "${real_count:-0}" -gt 0 ]]; then
        log_error "Refusing to dry-run over $real_count real artifact(s) in $ARTIFACTS_DIR"
        log_error "A dry run overwrites them with stubs and they are the only copy."
        log_error "Save them elsewhere, then run --reset first."
        exit 1
    fi
}

# Phases talk to each other only through artifact files, so starting mid-run is
# safe exactly when the earlier phases' artifacts are present and real. Check
# that here rather than letting a phase read a missing file and review nothing.
#
# Present is not enough: the files must also belong to THIS target and THIS
# source. scope.stamp (written by phase 1) is compared with the target path and
# with a hash of the dump collected now; a missing stamp is refused as well,
# since nothing then says what the debate was about.
verify_resume_artifacts() {
    local from="$1"
    local target_dir="$2"
    local missing=()
    local required=()

    # Only a single-iteration debate can be resumed. scope.stamp is rewritten
    # by every iteration's phase 1, so with iter2_* files present it describes
    # the source AFTER iteration 1's fixes while the iter1_* files resumed below
    # were written about the source before them. The pattern is a glob, so
    # iter10_ is not taken for iter1_.
    local f
    for f in "$ARTIFACTS_DIR"/iter*_*.md; do
        [[ -f "$f" ]] || continue
        case "${f##*/}" in
            iter1_*) ;;
            *)
                log_error "--from-phase $from: $ARTIFACTS_DIR holds artifacts of more than one iteration (${f##*/})"
                log_error "scope.stamp describes the last iteration's source, the saved debate is"
                log_error "iteration 1's. Run the review from phase 1."
                return 1
                ;;
        esac
    done

    [[ $from -ge 2 ]] && required+=("iter1_1_claude_review.md" "iter1_1_codex_review.md")
    [[ $from -ge 3 ]] && required+=("iter1_2_claude_on_codex.md" "iter1_2_codex_on_claude.md")
    [[ $from -ge 4 ]] && required+=("iter1_3_claude_meta.md" "iter1_3_codex_meta.md")

    for f in "${required[@]}"; do
        # 200 bytes is well under any real review and well over a one-line
        # refusal such as "You have hit your session limit".
        # The note run_claude/run_codex leave for a failed call is longer than
        # that and is no review either, nor is a reply without its phase's
        # status block: artifact_is_failed_call is the same test the run loop
        # and chunk_is_reviewed apply.
        if [[ ! -s "$ARTIFACTS_DIR/$f" ]] || [[ $(wc -c < "$ARTIFACTS_DIR/$f") -lt 200 ]] \
           || artifact_is_failed_call "$ARTIFACTS_DIR/$f"; then
            missing+=("$f")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "--from-phase $from needs earlier artifacts that are missing, empty or a failed agent call:"
        for f in "${missing[@]}"; do log_error "  $ARTIFACTS_DIR/$f"; done
        return 1
    fi

    if [[ ! -s "$SCOPE_STAMP_FILE" ]]; then
        log_error "--from-phase $from: $SCOPE_STAMP_FILE is missing, so nothing says which target"
        log_error "and source the artifacts in $ARTIFACTS_DIR belong to. Run the review from phase 1."
        return 1
    fi
    local stamp_target stamp_hash source_code now_hash
    stamp_target=$(sed -n '1p' "$SCOPE_STAMP_FILE" | tr -d '\r')
    stamp_hash=$(sed -n '2p' "$SCOPE_STAMP_FILE" | tr -d '\r[:space:]')
    if [[ "$stamp_target" != "$target_dir" ]]; then
        log_error "--from-phase $from: the artifacts are from a different target"
        log_error "  debated:   $stamp_target"
        log_error "  this run:  $target_dir"
        return 1
    fi
    if ! source_code=$(collect_source_code "$target_dir"); then
        log_error "--from-phase $from: source collection failed, cannot check the artifacts against it"
        return 1
    fi
    now_hash=$(source_dump_hash "$source_code")
    if [[ "$stamp_hash" != "$now_hash" ]]; then
        log_error "--from-phase $from: the source in scope differs from what was debated"
        log_error "(same target, but a file changed or the scope settings are not the same:"
        log_error "MAX_SOURCE_*, SOURCE_FILE_LIST, --changed-only). Run the review from phase 1."
        log_error "  debated:   $stamp_hash"
        log_error "  this run:  $now_hash"
        return 1
    fi

    log_info "Resuming at phase $from using ${#required[@]} existing artifact(s)"
    return 0
}

run_review_loop() {
    local target_dir="$1"
    target_dir="$(cd "$target_dir" && pwd)"

    # Checked on both sides of taking the review lock. Before, so a review that
    # must not start never holds the lock, not even for a moment in which the
    # driver's own next chunk would find it taken. After, because the driver
    # works the other way round (takes its lock, then looks for ours): whichever
    # of the two started second is then certain to see the other.
    refuse_foreign_driver
    guard_existing_artifacts
    acquire_lock
    refuse_foreign_driver

    # A run from phase 1 owns artifacts/ from here on. Files left by an earlier
    # run used to stay: a phase-1 "clean" exit sat beside an older run's
    # phase 2-4 files, and a run stopped after phase 1 left a fresh scope.stamp
    # vouching for an older debate, which --from-phase 3 then accepted. Only
    # after the lock is ours, never when resuming, and not in a dry run (which
    # writes no logs, and whose guard above has already refused to run over
    # real artifacts). The chunk drivers clear before calling; this is the same
    # thing for a standalone run.
    if [[ "$FROM_PHASE" -le 1 && "$DRY_RUN" != "1" ]]; then
        rm -f "${ARTIFACTS_DIR:?}"/iter*.md "$SCOPE_STAMP_FILE" "$SCOPE_STAMP_FILE.tmp" "${LOGS_DIR:?}"/iter* 2>/dev/null || true
    fi

    if [[ "$FROM_PHASE" -gt 1 ]]; then
        verify_resume_artifacts "$FROM_PHASE" "$target_dir" || return 1
    fi

    log_info "Starting Adversarial Review Loop"
    log_info "Target: $target_dir"
    log_info "Max iterations: $MAX_ITERATIONS"
    log_info "Timeout: ${TIMEOUT_MINUTES}m per agent"
    echo ""

    log_verbose "Initializing tracking..."
    init_tracking
    log_verbose "Initializing circuit breaker..."
    init_circuit_breaker

    # The breaker's counters and its last issue fingerprint describe the target
    # they were counted on. Carried over to another target they open the breaker
    # for stalls that happened somewhere else. The previous target has to be
    # read here, before it is overwritten. OPEN stays terminal either way.
    #
    # The comparison is done inside jq, with the new path passed the same way
    # update_tracking passes it. On Git Bash jq is a native program and MSYS
    # rewrites a path argument (/c/x becomes C:/x), so the stored value never
    # equals the shell's own $target_dir and a bash comparison saw a "changed"
    # target on every run.
    local previous_target
    previous_target=$(jq -r --arg t "$target_dir" \
        'if (.target_dir // "") == "" or .target_dir == $t then "" else .target_dir end' \
        "$TRACKING_FILE" 2>/dev/null | tr -d '\r' || true)
    if [[ -n "$previous_target" ]]; then
        if reset_circuit_counters; then
            log_info "Target changed since the last run ($previous_target) - circuit breaker counters reset"
        fi
    fi

    log_verbose "Updating tracking state..."
    update_tracking "target_dir" "$target_dir"
    update_tracking "status" "in_progress"
    update_tracking "started_at" "$(get_iso_timestamp)"

    local iteration=0
    log_verbose "Starting main loop (MAX_ITERATIONS=$MAX_ITERATIONS)..."

    while [[ $iteration -lt $MAX_ITERATIONS ]]; do
        ((iteration++)) || true
        log_info "=== Entering iteration $iteration ==="
        update_tracking "iteration" "$iteration"

        # Check circuit breaker
        if ! can_execute; then
            log_error "Circuit breaker is OPEN - halting"
            show_circuit_status
            update_tracking "status" "circuit_open"
            return 1
        fi

        echo ""
        log_info "=========================================="
        log_info "ITERATION $iteration / $MAX_ITERATIONS"
        log_info "=========================================="
        echo ""

        # Only the first iteration may start part-way through; a second pass is
        # reviewing changed code and has to redo the whole debate.
        local start_phase=1
        [[ $iteration -eq 1 ]] && start_phase=$FROM_PHASE

        # Phase 1. Return codes: 0 = both clean, 1 = issues found, 2 = both agents dead,
        # 3 = nothing to review (collection failed or the dump holds no file).
        local phase_rc=0
        if [[ $start_phase -le 1 ]]; then
            run_phase_1 "$target_dir" "$iteration" || phase_rc=$?
            if [[ $phase_rc -eq 2 ]]; then
                log_error "Halting: no usable agent output in phase 1"
                update_tracking "status" "agent_failure"
                return 1
            elif [[ $phase_rc -eq 3 ]]; then
                log_error "Halting: no source to review - no agent was called"
                update_tracking "status" "empty_scope"
                return 1
            elif iteration_has_failed_call "$iteration"; then
                # Before the clean return: one agent saying NO_ISSUES beside a
                # dead one is not two clean reviews.
                log_error "Halting: an agent call failed in phase 1 - a debate needs both agents"
                update_tracking "status" "agent_failure"
                return 1
            elif [[ $phase_rc -eq 0 ]]; then
                log_success "Review complete - both agents report clean code"
                update_tracking "status" "clean"
                return 0
            fi
            echo ""
        else
            log_info "Skipping phase 1 (resuming at phase $start_phase)"
        fi

        # Phase 2
        if [[ $start_phase -le 2 ]]; then
            phase_rc=0
            run_phase_2 "$target_dir" "$iteration" || phase_rc=$?
            if [[ $phase_rc -eq 2 ]]; then
                log_error "Halting: no usable agent output in phase 2"
                update_tracking "status" "agent_failure"
                return 1
            elif [[ $phase_rc -eq 3 ]]; then
                log_error "Halting: no source to review - phase 2 agents were not called"
                update_tracking "status" "empty_scope"
                return 1
            elif iteration_has_failed_call "$iteration"; then
                log_error "Halting: an agent call failed in phase 2 - a debate needs both agents"
                update_tracking "status" "agent_failure"
                return 1
            fi
            echo ""
        else
            log_info "Skipping phase 2 (resuming at phase $start_phase)"
        fi

        # Phase 3
        if [[ $start_phase -le 3 ]]; then
            phase_rc=0
            run_phase_3 "$target_dir" "$iteration" || phase_rc=$?
            if [[ $phase_rc -eq 2 ]]; then
                log_error "Halting: no usable agent output in phase 3"
                update_tracking "status" "agent_failure"
                return 1
            elif iteration_has_failed_call "$iteration"; then
                log_error "Halting: an agent call failed in phase 3 - a debate needs both agents"
                update_tracking "status" "agent_failure"
                return 1
            fi
            echo ""
        else
            log_info "Skipping phase 3 (resuming at phase $start_phase)"
        fi

        # Phase 4. Return codes: 0 = done, 1 = fixes applied, go round again,
        # 2 = the synthesis failed (either mode): no usable report or result.
        phase_rc=0
        run_phase_4 "$target_dir" "$iteration" || phase_rc=$?
        if [[ $phase_rc -eq 2 ]]; then
            if [[ "$NO_FIX" == "1" ]]; then
                log_error "Halting: synthesis failed - no report was produced"
            else
                log_error "Halting: synthesis failed - it may have edited files before failing; check 'git status' in $target_dir"
            fi
            update_tracking "status" "agent_failure"
            return 1
        elif [[ $phase_rc -eq 0 ]]; then
            if [[ "$NO_FIX" == "1" ]]; then
                log_success "Report complete - no files were modified"
                update_tracking "status" "report_only"
            else
                log_success "Synthesis complete"
                update_tracking "status" "clean"
            fi
            return 0
        fi
        echo ""

        log_info "Iteration $iteration complete, will verify fixes..."
        sleep 2
    done

    log_warning "Reached max iterations ($MAX_ITERATIONS)"
    update_tracking "status" "max_iterations"
    return 1
}

# ============================================================================
# Status & Management Commands
# ============================================================================
show_status() {
    echo ""
    log_info "=== Adversarial Review Status ==="
    echo ""

    if [[ ! -f "$TRACKING_FILE" ]]; then
        echo "No tracking file found. Run a review first."
        return
    fi

    jq -r '
        "Target:     \(.target_dir // "none")",
        "Status:     \(.status // "unknown")",
        "Iteration:  \(.iteration // 0)",
        "Started:    \(.started_at // "never")",
        "Updated:    \(.updated_at // "never")",
        "",
        "Recent History:"
    ' "$TRACKING_FILE"

    # One line per call: the counters that phase reports, then its summary.
    # Entries written before results were stored as objects are strings of
    # JSON; they are decoded here so an old tracking.json reads the same.
    jq -r '
        def show:
            (if type == "string" then (fromjson? // .) else . end)
            | if type != "object" then tostring
              elif has("error") then "no status (\(.error))"
              else ( [ to_entries[]
                       | select(.key != "summary" and .key != "status")
                       | "\(.key)=\(.value)" ] | join(" ") ) as $fields
                   | ( [ $fields, (.summary // empty | tostring) ]
                       | map(select(. != "")) | join(" - ") )
                   | if . == "" then "ok" else . end
              end;
        .history
        | if length == 0 then "  (none)"
          else .[-10:] | .[] | "  - Iter \(.iteration) \(.phase) [\(.agent)]: \(.result | show)"
          end
    ' "$TRACKING_FILE" 2>/dev/null | tr -d '\r' || echo "  (none)"

    echo ""
    echo "Artifacts:"
    if [[ -d "$ARTIFACTS_DIR" ]] && [[ -n "$(ls -A "$ARTIFACTS_DIR" 2>/dev/null)" ]]; then
        ls -1 "$ARTIFACTS_DIR" | head -20 | while read -r f; do
            echo "  $f"
        done
    else
        echo "  (none)"
    fi
}

reset_all() {
    # Never reset out from under a live review. The lock is what stops two runs
    # from interleaving in the shared artifacts/ directory, so deleting it while
    # its owner is still working re-opens exactly the corruption acquire_lock
    # exists to prevent - and the victim silently reads artifacts written by the
    # other run.
    if [[ -f "$LOCK_FILE" ]]; then
        local holder
        holder=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
        if [[ -n "$holder" ]] && kill -0 "$holder" 2>/dev/null; then
            log_error "A review is running (pid $holder) - refusing to reset its state"
            log_error "Wait for it to finish, or kill it first"
            exit 1
        fi
    fi
    # Same for a chunk driver, whoever started this: between two chunks it holds
    # no review lock, and artifacts/ is still its working directory.
    local driver_pid
    if driver_pid=$(live_driver_pid); then
        log_error "A chunk driver is running (pid $driver_pid holds $DRIVER_LOCK_DIR) - refusing to reset its state"
        log_error "Wait for it to finish, or kill it first"
        exit 1
    fi

    log_info "Resetting all state..."
    rmdir "$LOCK_FILE.recover" 2>/dev/null || true
    # artifacts/* includes scope.stamp.
    rm -rf "$ARTIFACTS_DIR"/* "$TRACKING_FILE"
    rm -f "$AR_DIR/.circuit_breaker.json" "$AR_DIR/.circuit_breaker_history.json"
    rm -f "$AR_DIR/.response_analysis.json" "$AR_DIR/.review.lock"
    mkdir -p "$ARTIFACTS_DIR" "$LOGS_DIR"
    init_tracking
    init_circuit_breaker
    log_success "Reset complete"
}

show_help() {
    cat << 'EOF'
Adversarial Review: Multi-Agent Code Review with Claude + Codex

USAGE:
    ./adversarial_review.sh [OPTIONS] <target_directory>

OPTIONS:
    -h, --help              Show this help
    --version               Show the version (from .claude-plugin/plugin.json)
    -m, --max-iters N       Max iterations (default: 3)
    -p, --prompt FILE       Custom initial review prompt, used for this run only
                            (prompts/initial_review.md is left untouched)
    -v, --verbose           Verbose output
    -t, --timeout MIN       Timeout per agent in minutes (default: 10)
    --status                Show current status
    --reset                 Reset all state
    --reset-circuit         Reset circuit breaker only
    --circuit-status        Show circuit breaker status
    --dry-run               Show what would happen without executing
    --fix                   Let phase 4 implement the agreed fixes in the target.
                            WITHOUT this flag the run is report-only: phase 4
                            writes a report, modifies nothing, and the run is a
                            single iteration.
                            Fix mode gives the agent write access to the target:
                            it can read, edit and create files there (tools:
                            Read, Grep, Glob, Edit, Write; no shell, so it
                            cannot run tests). The prompt it acts on quotes the
                            reviewed source, so text planted in that source can
                            steer it. Use --fix only on code you trust, and
                            commit the target first. The tool list is an
                            allowlist, not a sandbox.
    --no-fix                Report only. This is the default; the flag is kept
                            for existing command lines.
    --from-phase N          Start the first iteration at phase N (1-4), reusing
                            the artifacts already in artifacts/. Use it to redo
                            only a failed synthesis without repeating the debate.
                            Refused unless artifacts/scope.stamp shows they were
                            made for this target and this exact source.
    --changed-only          Review only files with uncommitted git changes,
                            each included up to 3000 lines.

PHASES:
    1. Independent Review   Claude and Codex review code in parallel
    2. Cross-Review         Each reviews the other's findings
    3. Meta-Review          Each reviews feedback on their review
    4. Synthesis            Claude weighs the debate and writes the report;
                            with --fix it also implements the fixes
    A failed agent call in any phase stops the run (status agent_failure,
    exit 1): a debate needs both agents.

ENVIRONMENT:
    MAX_ITERATIONS, TIMEOUT_MINUTES, VERBOSE=1, DRY_RUN=1 mirror the flags.
    NO_FIX=0                Same as --fix (NO_FIX=1, the default, is report-only)
    FROM_PHASE=N            Same as --from-phase N
    CODEX_BIN=path          Use this codex binary; the run stops if it does not
                            answer --version
    FIX_MODE_TOOLS=list     Tools the agent gets with --fix
                            (default: Read,Grep,Glob,Edit,Write)
    READ_ONLY_TOOLS=list    Tools every other Claude call gets
                            (default: Read,Grep,Glob)
    MAX_SOURCE_FILES, MAX_SOURCE_LINES, MAX_SOURCE_SHELL_FILES,
    MAX_SOURCE_SHELL_LINES  Source collection caps: positive integers
                            (defaults 30, 500, 10, 300)
    MAX_SOURCE_EXCLUDE=re   Extended regex; matching absolute paths are left
                            out of the source dump
    SOURCE_FILE_LIST=file   Review exactly the files listed in this file

CIRCUIT BREAKER:
    Prevents runaway loops by detecting:
    - No progress after 3 iterations
    - Persistent disagreement (5+ iterations)
    - Same issues found 3+ times (unfixable)
    It only counts in fix mode. Its counters start again when the target is
    not the one of the previous run; an OPEN breaker needs --reset-circuit.

REQUIREMENTS:
    - claude CLI: npm install -g @anthropic-ai/claude-code
    - codex CLI: npm install -g @openai/codex
    - jq: brew install jq
    - coreutils (macOS): brew install coreutils (for timeout)

EXAMPLES:
    ./adversarial_review.sh ../my-project              # report only
    ./adversarial_review.sh --fix -m 5 -v ../my-project
    ./adversarial_review.sh --dry-run ../my-project
    ./adversarial_review.sh --status

EOF
}

# ============================================================================
# Main Entry Point
# ============================================================================
# A flag that takes a value, given as the last word, used to die under `set -u`
# with "$2: unbound variable" and no hint of which flag was at fault.
need_arg() {
    if [[ $# -lt 2 ]]; then
        log_error "$1 needs a value"
        exit 1
    fi
}

# The version lives in one place, the plugin manifest, so a bug report from a
# clone and one from an installed plugin name the same thing. sed rather than jq:
# --version must answer even where jq is missing.
show_version() {
    local v
    v=$(sed -n 's/^[[:space:]]*"version":[[:space:]]*"\([^"]*\)".*/\1/p' \
        "$PLUGIN_MANIFEST" 2>/dev/null | head -n 1) || v=""
    echo "adversarial-review ${v:-unknown}"
}

main() {
    local target_dir=""
    local custom_prompt=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            --version)
                show_version
                exit 0
                ;;
            -m|--max-iters)
                need_arg "$@"
                MAX_ITERATIONS="$2"
                shift 2
                ;;
            -p|--prompt)
                need_arg "$@"
                custom_prompt="$2"
                shift 2
                ;;
            -v|--verbose)
                VERBOSE=1
                shift
                ;;
            -t|--timeout)
                need_arg "$@"
                TIMEOUT_MINUTES="$2"
                shift 2
                ;;
            --status)
                show_status
                exit 0
                ;;
            --reset)
                reset_all
                exit 0
                ;;
            --reset-circuit)
                init_circuit_breaker
                reset_circuit_breaker "Manual reset"
                exit 0
                ;;
            --circuit-status)
                init_circuit_breaker
                show_circuit_status
                exit 0
                ;;
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            --fix)
                NO_FIX=0
                shift
                ;;
            --no-fix)
                NO_FIX=1
                shift
                ;;
            --from-phase)
                need_arg "$@"
                FROM_PHASE="$2"
                if ! [[ "$FROM_PHASE" =~ ^[1-4]$ ]]; then
                    log_error "--from-phase takes 1, 2, 3 or 4"
                    exit 1
                fi
                shift 2
                ;;
            --changed-only)
                CHANGED_ONLY=1
                shift
                ;;
            -*)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
            *)
                target_dir="$1"
                shift
                ;;
        esac
    done

    if [[ -z "$target_dir" ]]; then
        log_error "No target directory specified"
        echo ""
        show_help
        exit 1
    fi

    if [[ ! -d "$target_dir" ]]; then
        log_error "Directory does not exist: $target_dir"
        exit 1
    fi

    # Checked after the loop so values from the environment are held to the same
    # rule as the flags. None of these was checked: -m 0 ended at once as "max
    # iterations", a non-numeric -t broke the timeout arithmetic in the middle
    # of phase 1, and FROM_PHASE from the environment bypassed the check that
    # --from-phase gets.
    if ! [[ "$MAX_ITERATIONS" =~ ^[1-9][0-9]*$ ]]; then
        log_error "-m/--max-iters (MAX_ITERATIONS) must be a positive integer, got '$MAX_ITERATIONS'"
        exit 1
    fi
    if ! [[ "$TIMEOUT_MINUTES" =~ ^[1-9][0-9]*$ ]]; then
        log_error "-t/--timeout (TIMEOUT_MINUTES) must be a positive integer, got '$TIMEOUT_MINUTES'"
        exit 1
    fi
    if ! [[ "$FROM_PHASE" =~ ^[1-4]$ ]]; then
        log_error "--from-phase (FROM_PHASE) must be 1, 2, 3 or 4, got '$FROM_PHASE'"
        exit 1
    fi
    if [[ "$NO_FIX" != "0" && "$NO_FIX" != "1" ]]; then
        log_error "NO_FIX must be 0 (fix mode) or 1 (report only), got '$NO_FIX'"
        exit 1
    fi

    # The collector's caps and its exclude regex come from the environment and
    # were never checked. A non-numeric cap made head fail silently or raised an
    # arithmetic error inside the dump; a regex grep cannot compile dropped
    # every file behind filter_excluded's `|| true` and the run ended as
    # empty_scope, as if the target had no source.
    local cap_name exclude_rc=0
    for cap_name in MAX_SOURCE_FILES MAX_SOURCE_LINES MAX_SOURCE_SHELL_FILES MAX_SOURCE_SHELL_LINES; do
        if ! [[ "${!cap_name}" =~ ^[1-9][0-9]*$ ]]; then
            log_error "$cap_name must be a positive integer, got '${!cap_name}'"
            exit 1
        fi
    done
    # The breaker compares its counters with these in [[ -ge ]], which reads
    # 08 as a bad octal number (fatal) and 010 as 8, and would evaluate any
    # other text as arithmetic. Same rule as the caps, so no leading zero.
    for cap_name in CB_NO_PROGRESS_THRESHOLD CB_DISAGREEMENT_THRESHOLD CB_SAME_ISSUES_THRESHOLD; do
        if ! [[ "${!cap_name}" =~ ^[1-9][0-9]{0,8}$ ]]; then
            log_error "$cap_name must be a positive integer without leading zeros, got '${!cap_name}'"
            exit 1
        fi
    done
    if [[ -n "$MAX_SOURCE_EXCLUDE" ]]; then
        # grep exits 2 for a pattern it cannot compile, 1 for "no match".
        grep -E -- "$MAX_SOURCE_EXCLUDE" < /dev/null > /dev/null 2>&1 || exclude_rc=$?
        if [[ $exclude_rc -ge 2 ]]; then
            log_error "MAX_SOURCE_EXCLUDE is not a valid extended regular expression: '$MAX_SOURCE_EXCLUDE'"
            exit 1
        fi
    fi

    # Fail here rather than in collect_source_code: its caller reads it through
    # $(...), where a failure is only an empty dump and the agents review nothing.
    if [[ -n "$SOURCE_FILE_LIST" ]]; then
        if [[ ! -f "$SOURCE_FILE_LIST" ]]; then
            log_error "SOURCE_FILE_LIST not found: $SOURCE_FILE_LIST"
            exit 1
        fi
        SOURCE_FILE_LIST="$(cd "$(dirname "$SOURCE_FILE_LIST")" && pwd)/$(basename "$SOURCE_FILE_LIST")"
    fi

    # -p replaces the phase-1 template for this run only. It used to be copied
    # over prompts/initial_review.md, permanently, and a mistyped path was
    # silently ignored.
    if [[ -n "$custom_prompt" ]]; then
        if [[ ! -f "$custom_prompt" ]]; then
            log_error "Prompt file not found: $custom_prompt"
            exit 1
        fi
        INITIAL_PROMPT_FILE="$(cd "$(dirname "$custom_prompt")" && pwd)/$(basename "$custom_prompt")"
        log_info "Using custom prompt for this run: $INITIAL_PROMPT_FILE"
    fi

    check_dependencies

    run_review_loop "$target_dir"
}

main "$@"
