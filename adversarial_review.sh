#!/usr/bin/env bash
#
# Adversarial Review: Multi-Agent Code Review with Claude + Codex
#
# Implements an adversarial review loop where Claude and GPT Codex
# independently review code, cross-review findings, meta-review feedback,
# and then Claude synthesizes and implements fixes.
#
# Based on patterns from asimov-ralph (https://github.com/frankbria/ralph-claude-code)
#
# Usage:
#   ./adversarial_review.sh [OPTIONS] <target_dir>
#
# Options:
#   -h, --help              Show help message
#   -m, --max-iters N       Maximum iterations (default: 3)
#   -p, --prompt FILE       Custom review prompt file
#   -v, --verbose           Verbose output
#   -t, --timeout MIN       Timeout per agent call in minutes (default: 10)
#   --status                Show current status
#   --reset                 Reset artifacts and tracking
#   --reset-circuit         Reset circuit breaker
#   --circuit-status        Show circuit breaker status
#   --dry-run               Show what would be done without executing

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
PROMPTS_DIR="$SCRIPT_DIR/prompts"

# Export AR_DIR for lib scripts
export AR_DIR="$SCRIPT_DIR"
ARTIFACTS_DIR="$AR_DIR/artifacts"
LOGS_DIR="$AR_DIR/logs"
TRACKING_FILE="$AR_DIR/tracking.json"

# Source library components
source "$LIB_DIR/date_utils.sh"
source "$LIB_DIR/circuit_breaker.sh"
source "$LIB_DIR/response_analyzer.sh"

# Defaults
MAX_ITERATIONS="${MAX_ITERATIONS:-3}"
VERBOSE="${VERBOSE:-0}"
DRY_RUN="${DRY_RUN:-0}"
TIMEOUT_MINUTES="${TIMEOUT_MINUTES:-10}"
NO_FIX="${NO_FIX:-0}"
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

# Resolve a codex binary that actually runs.
# On Windows/Git Bash the npm `codex` shell shim can resolve node to a placeholder
# stub under node_modules/node ("This file intentionally left blank") while the .cmd
# wrapper works fine. Probing with --version catches that; `command -v` does not.
CODEX_BIN="${CODEX_BIN:-}"
resolve_codex_bin() {
    local candidate
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

        if ! command -v codex &> /dev/null && ! command -v codex.cmd &> /dev/null; then
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

# Add to history
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
            "result": $r,
            "timestamp": $ts
        }]
    ' "$TRACKING_FILE" > "$tmp" && mv "$tmp" "$TRACKING_FILE"
}

# Parse status block from agent output
# Format: ---REVIEW_STATUS--- ... ---END_REVIEW_STATUS---
parse_status_block() {
    local file="$1"
    local block_name="${2:-REVIEW_STATUS}"

    if [[ ! -f "$file" ]]; then
        echo '{"error": "file not found"}'
        return 1
    fi

    # Extract the status block
    local content=$(cat "$file")
    local block=$(echo "$content" | sed -n "/---${block_name}---/,/---END_${block_name}---/p" | grep -v "^---")

    if [[ -z "$block" ]]; then
        # No status block found, try to detect NO_ISSUES
        if echo "$content" | grep -qE '^\s*NO_ISSUES\s*$'; then
            echo '{"exit_signal": true, "issues_found": 0}'
            return 0
        fi
        echo '{"error": "no status block"}'
        return 1
    fi

    # Parse key: value pairs into JSON
    local json="{"
    local first=true
    while IFS=: read -r key value; do
        [[ -z "$key" ]] && continue
        key=$(echo "$key" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
        value=$(echo "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

        [[ "$first" == "true" ]] && first=false || json+=","

        # Determine type
        if [[ "$value" =~ ^[0-9]+$ ]]; then
            json+="\"$key\": $value"
        elif [[ "$value" == "true" || "$value" == "false" ]]; then
            json+="\"$key\": $value"
        elif [[ "$value" == "YES" || "$value" == "FULL" ]]; then
            json+="\"$key\": true"
        elif [[ "$value" == "NO" || "$value" == "LOW" ]]; then
            json+="\"$key\": false"
        else
            json+="\"$key\": \"$value\""
        fi
    done <<< "$block"
    json+="}"

    echo "$json"
}

# Collect only the files with uncommitted changes (--changed-only).
#
# `git status --porcelain` emits paths relative to the REPOSITORY ROOT, which is
# not necessarily the target directory - a target can sit several levels below
# its repo root. Resolve every path against the root, then keep only the files
# that actually live under the target. Files are included whole rather than
# head-truncated: a changed set is small, and truncating a diff under review
# defeats the point.
collect_changed_files() {
    local target_dir="$1"
    local max_lines="${2:-3000}"
    local output=""
    local repo_root
    local abs_target

    if ! repo_root=$(git -C "$target_dir" rev-parse --show-toplevel 2>/dev/null); then
        log_error "--changed-only requires the target to be inside a git repository"
        return 1
    fi

    abs_target="$(cd "$target_dir" && pwd)"
    log_verbose "Collecting changed files (repo root: $repo_root)"

    local rel path canon
    while IFS= read -r rel; do
        [[ -z "$rel" ]] && continue
        rel="${rel##* -> }"          # renames arrive as "old -> new"
        rel="${rel#\"}"; rel="${rel%\"}"
        path="$repo_root/$rel"
        [[ -f "$path" ]] || continue

        case "${rel##*.}" in
            png|jpg|jpeg|gif|ico|icns|ttf|woff|woff2|xlsx|xls|zip|jar|class|exe|dll|pdf|so|dylib)
                log_verbose "Skipping binary: $rel"
                continue
                ;;
        esac

        # Normalise to the shell's path form before comparing; git may report a
        # Windows-style root while $PWD is POSIX-style.
        canon="$(cd "$(dirname "$path")" 2>/dev/null && pwd)" || continue
        case "$canon/" in
            "$abs_target"/*) ;;
            *) log_verbose "Skipping (outside target): $rel"; continue ;;
        esac

        log_verbose "Including changed file: $rel"
        output+="
=== FILE: $rel ===
$(head -$max_lines "$path" 2>/dev/null)
"
    done < <(git -C "$target_dir" status --porcelain | sed 's/^...//')

    if [[ -z "$output" ]]; then
        log_warning "No changed files found under $target_dir"
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

# Collect source code from target directory
collect_source_code() {
    local target_dir="$1"
    local max_files="${2:-$MAX_SOURCE_FILES}"
    local max_lines="${3:-$MAX_SOURCE_LINES}"
    local output=""
    local count=0

    if [[ "$CHANGED_ONLY" == "1" ]]; then
        collect_changed_files "$target_dir"
        return 0
    fi

    log_verbose "Collecting source code from $target_dir"

    # Java
    count=0
    while IFS= read -r file && [[ $count -lt $max_files ]]; do
        [[ -z "$file" ]] && continue
        local rel="${file#$target_dir/}"
        output+="
=== FILE: $rel ===
$(head -$max_lines "$file" 2>/dev/null)
"
        ((count++))
    done < <(find "$target_dir" -name "*.java" -type f ! -path "*/\.*" ! -path "*/target/*" ! -path "*/build/*" 2>/dev/null | filter_excluded | sort)

    # Python files
    count=0
    while IFS= read -r file && [[ $count -lt $max_files ]]; do
        [[ -z "$file" ]] && continue
        local rel="${file#$target_dir/}"
        output+="
=== FILE: $rel ===
$(head -$max_lines "$file" 2>/dev/null)
"
        ((count++))
    done < <(find "$target_dir" -name "*.py" -type f ! -path "*/\.*" ! -path "*/__pycache__/*" ! -path "*/venv/*" ! -path "*/.venv/*" 2>/dev/null | filter_excluded | sort)

    # TypeScript/JavaScript
    count=0
    while IFS= read -r file && [[ $count -lt $max_files ]]; do
        [[ -z "$file" ]] && continue
        local rel="${file#$target_dir/}"
        output+="
=== FILE: $rel ===
$(head -$max_lines "$file" 2>/dev/null)
"
        ((count++))
    done < <(find "$target_dir" \( -name "*.ts" -o -name "*.tsx" -o -name "*.js" -o -name "*.jsx" \) -type f ! -path "*/node_modules/*" ! -path "*/\.*" 2>/dev/null | filter_excluded | sort)

    # Shell scripts
    count=0
    while IFS= read -r file && [[ $count -lt $MAX_SOURCE_SHELL_FILES ]]; do
        [[ -z "$file" ]] && continue
        local rel="${file#$target_dir/}"
        output+="
=== FILE: $rel ===
$(head -$MAX_SOURCE_SHELL_LINES "$file" 2>/dev/null)
"
        ((count++))
    done < <(find "$target_dir" -name "*.sh" -type f ! -path "*/\.*" 2>/dev/null | filter_excluded | sort)

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

    local timeout_cmd=$(get_timeout_cmd)
    local timeout_secs=$((TIMEOUT_MINUTES * 60))

    local cmd_args=(--print)
    [[ "$with_permissions" == "true" ]] && cmd_args+=(--dangerously-skip-permissions)

    local exit_code=0
    if [[ -n "$timeout_cmd" ]]; then
        (cd "$working_dir" && echo "$prompt" | $timeout_cmd ${timeout_secs}s claude "${cmd_args[@]}") > "$output_file" 2>&1 || exit_code=$?
    else
        (cd "$working_dir" && echo "$prompt" | claude "${cmd_args[@]}") > "$output_file" 2>&1 || exit_code=$?
    fi

    if [[ $exit_code -eq 0 ]]; then
        log_claude "Complete ($(wc -l < "$output_file" | tr -d ' ') lines)"
    elif [[ $exit_code -eq 124 ]]; then
        log_warning "Claude timed out after ${TIMEOUT_MINUTES}m"
    else
        log_warning "Claude exited with code $exit_code"
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

    local timeout_cmd=$(get_timeout_cmd)
    local timeout_secs=$((TIMEOUT_MINUTES * 60))

    # codex >= 0.30 uses the `exec` subcommand; the old `-q --full-auto --prompt` form is gone.
    # The prompt is piped on stdin rather than passed as an argument: the phase-1 source dump
    # easily exceeds the ~32KB Windows CreateProcess command-line limit.
    # read-only sandbox is correct here - only phase 4 (Claude) is allowed to modify files.
    #
    # -o/--output-last-message is load-bearing, not a nicety: `codex exec` echoes the whole
    # prompt plus a banner to stdout, and our prompts contain EXAMPLE status blocks. Capturing
    # stdout would feed those examples to parse_status_block's sed range match and corrupt the
    # parsed result. -o writes only the agent's final message.
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
    if [[ -n "$timeout_cmd" ]]; then
        (cd "$working_dir" && printf '%s' "$prompt" | $timeout_cmd ${timeout_secs}s "$codex_bin" "${codex_args[@]}") > "$codex_log" 2>&1 || exit_code=$?
    else
        (cd "$working_dir" && printf '%s' "$prompt" | "$codex_bin" "${codex_args[@]}") > "$codex_log" 2>&1 || exit_code=$?
    fi

    if [[ -s "$codex_tmp" ]]; then
        mv "$codex_tmp" "$output_file"
    fi
    rm -f "$codex_tmp"

    # Fall back to the transcript if codex died before writing the final message
    if [[ ! -s "$output_file" ]]; then
        log_warning "Codex produced no final message; falling back to transcript"
        cp "$codex_log" "$output_file" 2>/dev/null || echo "Codex produced no output" > "$output_file"
        [[ $exit_code -eq 0 ]] && exit_code=1
    fi

    if [[ $exit_code -eq 0 ]]; then
        log_codex "Complete ($(wc -l < "$output_file" | tr -d ' ') lines)"
    elif [[ $exit_code -eq 124 ]]; then
        log_warning "Codex timed out after ${TIMEOUT_MINUTES}m"
    else
        log_warning "Codex exited with code $exit_code"
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

describe_exit() {
    if [[ "$1" -eq 124 ]]; then
        echo "timed out after ${TIMEOUT_MINUTES}m"
    else
        echo "exit code $1"
    fi
}

# Wait on a parallel Claude/Codex pair and surface failures.
# Exit codes used to be discarded with `wait || true`, which made a crashed or
# timed-out agent indistinguishable from a clean review: the artifact has no
# status block, so it parses to 0 issues and the loop burns iterations on
# garbage. Returns non-zero only when BOTH agents failed, which is unrecoverable
# for the iteration; a single failure degrades to a warning.
wait_for_agents() {
    local claude_pid="$1"
    local codex_pid="$2"
    local phase="$3"
    local claude_rc=0
    local codex_rc=0

    wait "$claude_pid" || claude_rc=$?
    wait "$codex_pid" || codex_rc=$?

    [[ $claude_rc -ne 0 ]] && log_error "Claude failed in $phase ($(describe_exit $claude_rc))"
    [[ $codex_rc -ne 0 ]] && log_error "Codex failed in $phase ($(describe_exit $codex_rc))"

    if [[ $claude_rc -ne 0 && $codex_rc -ne 0 ]]; then
        log_error "Both agents failed in $phase - aborting iteration"
        return 1
    fi
    return 0
}

# Fingerprint the ISSUES in a set of reviews, not their prose.
# The old implementation hashed the raw review text, which never repeats
# byte-for-byte across iterations because LLM wording varies. That silently
# disabled the circuit breaker's same-issues trigger. Fingerprinting the set of
# referenced source locations is stable across rewordings; line numbers are
# stripped because they shift as fixes are applied.
issues_fingerprint() {
    cat "$@" 2>/dev/null \
        | grep -oiE '[A-Za-z0-9_./-]+\.(py|ts|tsx|js|jsx|sh|go|rs|java|rb|c|h|cpp|hpp|cs|php|swift|kt)(:[0-9]+)?' \
        | sed 's/:[0-9]*$//' \
        | tr '[:upper:]' '[:lower:]' \
        | sort -u \
        | sha256_hash
}

# Hash of the target's working-tree state, used to detect whether phase 4
# actually changed anything rather than trusting the agent's self-report.
# Echoes "no-git" when the target is not a git repository.
target_state_hash() {
    local dir="$1"
    if git -C "$dir" rev-parse --git-dir &> /dev/null; then
        { git -C "$dir" status --porcelain; git -C "$dir" diff; git -C "$dir" diff --cached; } 2>/dev/null | sha256_hash
    else
        echo "no-git"
    fi
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

    local source_code=$(collect_source_code "$target_dir")
    local prompt_template=$(cat "$PROMPTS_DIR/initial_review.md")

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

    # Parse results
    local claude_status=$(parse_status_block "$claude_out" "REVIEW_STATUS")
    local codex_status=$(parse_status_block "$codex_out" "REVIEW_STATUS")

    local claude_exit=$(echo "$claude_status" | jq -r '.exit_signal // false')
    local codex_exit=$(echo "$codex_status" | jq -r '.exit_signal // false')

    add_to_history "$iteration" "phase_1" "claude" "$claude_status"
    add_to_history "$iteration" "phase_1" "codex" "$codex_status"

    # Check for dual NO_ISSUES
    if [[ "$claude_exit" == "true" ]] && [[ "$codex_exit" == "true" ]]; then
        log_success "Both agents report NO_ISSUES"
        return 0  # Signal clean exit
    fi

    local claude_issues=$(echo "$claude_status" | jq -r '.issues_found // 0')
    local codex_issues=$(echo "$codex_status" | jq -r '.issues_found // 0')

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
    local source_code=$(collect_source_code "$target_dir")

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

    log_info "=== Phase 4: Synthesis & Implementation ==="

    local synthesis_prompt=$(cat "$PROMPTS_DIR/synthesis.md")

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

    # Report-only mode also withholds --dangerously-skip-permissions, so the
    # prompt override is backed by an actual permission boundary.
    local allow_writes="true"
    [[ "$NO_FIX" == "1" ]] && allow_writes="false"

    local synth_rc=0
    run_claude "$context" "$output_file" "$target_dir" "$allow_writes" || synth_rc=$?
    if [[ $synth_rc -ne 0 ]]; then
        log_error "Synthesis agent failed ($(describe_exit $synth_rc)) - no fixes applied this iteration"
    fi

    local state_after=$(target_state_hash "$target_dir")

    local status=$(parse_status_block "$output_file" "SYNTHESIS_STATUS")
    local exit_signal=$(echo "$status" | jq -r '.exit_signal // false')
    local reported_modified=$(echo "$status" | jq -r '.files_modified // 0')

    # Progress = did the target's working tree actually change. FILES_MODIFIED is
    # self-reported by the agent, and a missing status block parses to 0, which
    # reads as "no progress" and advances the breaker on a parsing failure rather
    # than a real stall. Fall back to the self-report only for non-git targets.
    local fixes_made=0
    if [[ "$state_before" == "no-git" ]]; then
        log_warning "Target is not a git repository - falling back to self-reported FILES_MODIFIED"
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

    # Report-only mode stops here. Nothing was changed, so a further iteration
    # would re-review byte-identical code, and feeding a guaranteed zero-progress
    # result to the circuit breaker would leave it dirty for the next real run.
    if [[ "$NO_FIX" == "1" ]]; then
        if [[ "$state_before" != "$state_after" ]]; then
            log_error "Report-only mode but the target changed - inspect 'git status' in the target"
        else
            log_success "Report-only: target untouched"
        fi
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
    local from_claude=$(echo "$status" | jq -r '.fixes_from_claude // 0')
    local from_codex=$(echo "$status" | jq -r '.fixes_from_codex // 0')
    local rej_claude=$(echo "$status" | jq -r '.rejected_from_claude // 0')
    local rej_codex=$(echo "$status" | jq -r '.rejected_from_codex // 0')
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

    log_info "Fixes applied, will verify in next iteration"
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

acquire_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local holder
        holder=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
        if [[ -n "$holder" ]] && kill -0 "$holder" 2>/dev/null; then
            log_error "A review is already running (pid $holder)"
            log_error "Concurrent runs corrupt each other's artifacts. Wait for it to"
            log_error "finish, or kill it and remove $LOCK_FILE"
            exit 1
        fi
        log_warning "Removing stale lock left by pid ${holder:-unknown}"
        rm -f "$LOCK_FILE"
    fi

    echo $$ > "$LOCK_FILE"
    trap 'rm -f "$LOCK_FILE"' EXIT INT TERM
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
verify_resume_artifacts() {
    local from="$1"
    local missing=()
    local required=()

    [[ $from -ge 2 ]] && required+=("iter1_1_claude_review.md" "iter1_1_codex_review.md")
    [[ $from -ge 3 ]] && required+=("iter1_2_claude_on_codex.md" "iter1_2_codex_on_claude.md")
    [[ $from -ge 4 ]] && required+=("iter1_3_claude_meta.md" "iter1_3_codex_meta.md")

    local f
    for f in "${required[@]}"; do
        # 200 bytes is well under any real review and well over a one-line
        # refusal such as "You have hit your session limit".
        if [[ ! -s "$ARTIFACTS_DIR/$f" ]] || [[ $(wc -c < "$ARTIFACTS_DIR/$f") -lt 200 ]]; then
            missing+=("$f")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "--from-phase $from needs earlier artifacts that are missing or empty:"
        for f in "${missing[@]}"; do log_error "  $ARTIFACTS_DIR/$f"; done
        return 1
    fi
    log_info "Resuming at phase $from using ${#required[@]} existing artifact(s)"
    return 0
}

run_review_loop() {
    local target_dir="$1"
    target_dir="$(cd "$target_dir" && pwd)"

    guard_existing_artifacts
    acquire_lock

    if [[ "$FROM_PHASE" -gt 1 ]]; then
        verify_resume_artifacts "$FROM_PHASE" || return 1
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

        # Phase 1. Return codes: 0 = both clean, 1 = issues found, 2 = both agents dead.
        local phase_rc=0
        if [[ $start_phase -le 1 ]]; then
            run_phase_1 "$target_dir" "$iteration" || phase_rc=$?
            if [[ $phase_rc -eq 0 ]]; then
                log_success "Review complete - both agents report clean code"
                update_tracking "status" "clean"
                return 0
            elif [[ $phase_rc -eq 2 ]]; then
                log_error "Halting: no usable agent output in phase 1"
                update_tracking "status" "agent_failure"
                return 1
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
            fi
            echo ""
        else
            log_info "Skipping phase 3 (resuming at phase $start_phase)"
        fi

        # Phase 4
        if run_phase_4 "$target_dir" "$iteration"; then
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

    jq -r '.history | if length == 0 then "  (none)" else .[-10:] | .[] | "  - Iter \(.iteration) \(.phase) [\(.agent)]: \(.result | if type == "object" then .summary // "ok" else . end)"  end' "$TRACKING_FILE" 2>/dev/null || echo "  (none)"

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

    log_info "Resetting all state..."
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
    -m, --max-iters N       Max iterations (default: 3)
    -p, --prompt FILE       Custom initial review prompt
    -v, --verbose           Verbose output
    -t, --timeout MIN       Timeout per agent in minutes (default: 10)
    --status                Show current status
    --reset                 Reset all state
    --reset-circuit         Reset circuit breaker only
    --circuit-status        Show circuit breaker status
    --dry-run               Show what would happen without executing
    --no-fix                Review only: phase 4 writes a report and modifies
                            nothing. Runs a single iteration.
    --from-phase N          Start the first iteration at phase N (1-4), reusing
                            the artifacts already in artifacts/. Use it to redo
                            only a failed synthesis without repeating the debate.
    --changed-only          Review only files with uncommitted git changes,
                            included in full rather than truncated.

PHASES:
    1. Independent Review   Claude and Codex review code in parallel
    2. Cross-Review         Each reviews the other's findings
    3. Meta-Review          Each reviews feedback on their review
    4. Synthesis            Claude synthesizes and implements fixes

CIRCUIT BREAKER:
    Prevents runaway loops by detecting:
    - No progress after 3 iterations
    - Persistent disagreement (5+ iterations)
    - Same issues found 3+ times (unfixable)

REQUIREMENTS:
    - claude CLI: npm install -g @anthropic-ai/claude-code
    - codex CLI: npm install -g @openai/codex
    - jq: brew install jq
    - coreutils (macOS): brew install coreutils (for timeout)

EXAMPLES:
    ./adversarial_review.sh ../my-project
    ./adversarial_review.sh -m 5 -v ../my-project
    ./adversarial_review.sh --dry-run ../my-project
    ./adversarial_review.sh --status

EOF
}

# ============================================================================
# Main Entry Point
# ============================================================================
main() {
    local target_dir=""
    local custom_prompt=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            -m|--max-iters)
                MAX_ITERATIONS="$2"
                shift 2
                ;;
            -p|--prompt)
                custom_prompt="$2"
                shift 2
                ;;
            -v|--verbose)
                VERBOSE=1
                shift
                ;;
            -t|--timeout)
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
            --no-fix)
                NO_FIX=1
                shift
                ;;
            --from-phase)
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

    check_dependencies

    if [[ -n "$custom_prompt" ]] && [[ -f "$custom_prompt" ]]; then
        cp "$custom_prompt" "$PROMPTS_DIR/initial_review.md"
        log_info "Using custom prompt: $custom_prompt"
    fi

    run_review_loop "$target_dir"
}

main "$@"
