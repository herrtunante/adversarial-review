#!/usr/bin/env bash
#
# aggregate_review.sh - merge the per-chunk output of run_chunked_review.sh into
# one project-level report.
#
# Each chunk produced its own 4-phase debate and its own phase-4 synthesis. This
# walks those, pulls the SYNTHESIS_STATUS counters and the report bodies, and
# writes <run_dir>/REPORT.md plus <run_dir>/summary.json.
#
# Usage:
#   ./aggregate_review.sh <run_dir> [-o OUTPUT.md]

set -euo pipefail

RUN_DIR=""
OUT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -o|--out) OUT="$2"; shift 2 ;;
        -h|--help)
            sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) RUN_DIR="$1"; shift ;;
    esac
done

[[ -n "$RUN_DIR" && -d "$RUN_DIR" ]] || { echo "usage: $0 <run_dir> [-o out.md]" >&2; exit 1; }
RUN_DIR="$(cd "$RUN_DIR" && pwd)"
[[ -n "$OUT" ]] || OUT="$RUN_DIR/REPORT.md"
SUMMARY_JSON="$RUN_DIR/summary.json"

# Pull one KEY from a status block in an artifact. The block delimiters vary per
# phase, so the caller passes the block name.
status_value() {
    local file="$1" block="$2" key="$3"
    [[ -f "$file" ]] || { echo ""; return; }
    # `|| true`: grep exits 1 when the key is absent, and under `set -e` a bare
    # assignment from a failing command substitution kills the script. A missing
    # key is normal here - an agent that crashed writes no status block at all.
    sed -n "/---${block}---/,/---END_${block}---/p" "$file" 2>/dev/null \
      | grep -m1 -E "^[[:space:]]*${key}:" \
      | sed -E "s/^[[:space:]]*${key}:[[:space:]]*//" \
      | tr -d '\r' || true
}

num() { local v="${1:-}"; [[ "$v" =~ ^[0-9]+$ ]] && echo "$v" || echo 0; }

# Locate a chunk's phase-4 report, tolerating a chunk that has not run yet.
#
# A chunk directory is created before the review starts, so while a run is still
# in progress the newest chunk has no artifacts/ yet. `find` on a missing
# directory exits non-zero, and under `set -e` that kills the whole script from
# inside the command substitution - which made aggregating a partial run fail.
find_synthesis() {
    local d="$1"
    [[ -d "$d/artifacts" ]] || return 0
    local f
    f="$(find "$d/artifacts" -name 'iter*_4_synthesis.md' -type f 2>/dev/null | sort | tail -1 || true)"
    # Only a report with a real status block counts. A refused or unreachable
    # synthesis call leaves a one-line file, which would otherwise tabulate as a
    # finished chunk with zero findings.
    if [[ -n "$f" ]] && grep -q -- '---SYNTHESIS_STATUS---' "$f" 2>/dev/null; then
        echo "$f"
    fi
    return 0
}

# Strip the status block out of a report body so the merged document reads as
# prose; the counters are already tabulated above it.
strip_status() {
    sed '/---SYNTHESIS_STATUS---/,/---END_SYNTHESIS_STATUS---/d' "$1"
}

chunk_dirs=()
while IFS= read -r d; do
    # The driver writes exclude.regex into every chunk directory, so its
    # presence is what marks one. This skips the report's own web/ folder.
    [[ -f "$d/exclude.regex" ]] || continue
    chunk_dirs+=("$d")
done < <(find "$RUN_DIR" -mindepth 1 -maxdepth 1 -type d | sort)

[[ ${#chunk_dirs[@]} -gt 0 ]] || { echo "no chunk directories under $RUN_DIR" >&2; exit 1; }

tot_high=0; tot_med=0; tot_skip=0; tot_claude=0; tot_codex=0
tot_rej_claude=0; tot_rej_codex=0; tot_files=0
done_count=0
pending=()
rows=""
json_chunks=""

for d in "${chunk_dirs[@]}"; do
    cid="$(basename "$d")"
    synth="$(find_synthesis "$d")"

    if [[ -z "$synth" || ! -f "$synth" ]]; then
        rows+="| $cid | - | - | - | - | not reviewed yet |"$'\n'
        json_chunks+="{\"chunk\":\"$cid\",\"status\":\"pending\"},"
        pending+=("$cid")
        continue
    fi
    done_count=$((done_count + 1))

    high=$(num "$(status_value "$synth" SYNTHESIS_STATUS HIGH_CONFIDENCE_FIXES)")
    med=$(num "$(status_value "$synth" SYNTHESIS_STATUS MEDIUM_CONFIDENCE_FIXES)")
    skip=$(num "$(status_value "$synth" SYNTHESIS_STATUS ISSUES_SKIPPED)")
    fclaude=$(num "$(status_value "$synth" SYNTHESIS_STATUS FIXES_FROM_CLAUDE)")
    fcodex=$(num "$(status_value "$synth" SYNTHESIS_STATUS FIXES_FROM_CODEX)")
    rclaude=$(num "$(status_value "$synth" SYNTHESIS_STATUS REJECTED_FROM_CLAUDE)")
    rcodex=$(num "$(status_value "$synth" SYNTHESIS_STATUS REJECTED_FROM_CODEX)")
    fmod=$(num "$(status_value "$synth" SYNTHESIS_STATUS FILES_MODIFIED)")
    summary="$(status_value "$synth" SYNTHESIS_STATUS SUMMARY)"
    [[ -n "$summary" ]] || summary="(no summary reported)"

    tot_high=$((tot_high + high)); tot_med=$((tot_med + med)); tot_skip=$((tot_skip + skip))
    tot_claude=$((tot_claude + fclaude)); tot_codex=$((tot_codex + fcodex))
    tot_rej_claude=$((tot_rej_claude + rclaude)); tot_rej_codex=$((tot_rej_codex + rcodex))
    tot_files=$((tot_files + fmod))

    rows+="| $cid | $high | $med | $skip | ${fclaude}/${fcodex} | ${summary//|/\\|} |"$'\n'
    esc_summary="$(printf '%s' "$summary" | sed 's/\\/\\\\/g; s/"/\\"/g')"
    json_chunks+="{\"chunk\":\"$cid\",\"high\":$high,\"medium\":$med,\"skipped\":$skip,\"from_claude\":$fclaude,\"from_codex\":$fcodex,\"rejected_claude\":$rclaude,\"rejected_codex\":$rcodex,\"summary\":\"$esc_summary\"},"
done

json_chunks="${json_chunks%,}"

{
    echo "# Adversarial Review - Consolidated Report"
    echo ""
    echo "Run directory: \`$RUN_DIR\`"
    echo "Generated: $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
    echo "The project is split into ${#chunk_dirs[@]} chunks; $done_count of them have a completed review."
    echo "Each completed chunk ran the full"
    echo "four-phase debate independently: Claude and Codex reviewed it in parallel,"
    echo "cross-reviewed each other's findings, defended or conceded in a meta-review,"
    echo "and a final synthesis pass weighed the result. Findings below are therefore"
    echo "scoped to a chunk. Issues that span chunk boundaries are by construction"
    echo "invisible to this process - see the caveat at the end."
    echo ""
    echo "## Recommendations by chunk"
    echo ""
    echo "| Chunk | High conf. | Medium conf. | Skipped | Claude/Codex | Summary |"
    echo "|---|---:|---:|---:|---|---|"
    printf '%s' "$rows"
    echo "| **TOTAL** | **$tot_high** | **$tot_med** | **$tot_skip** | **${tot_claude}/${tot_codex}** | |"
    echo ""
    echo "Findings rejected during synthesis: $tot_rej_claude from Claude, $tot_rej_codex from Codex."
    echo "A large imbalance here is a signal that the arbiter, which is also one of the"
    echo "debaters, favoured its own findings."
    echo ""

    if [[ -f "$RUN_DIR/index.tsv" ]]; then
        echo "## Run status"
        echo ""
        echo '```'
        column -t -s "$(printf '\t')" "$RUN_DIR/index.tsv" 2>/dev/null || cat "$RUN_DIR/index.tsv"
        echo '```'
        echo ""
    fi

    echo "---"
    echo ""
    echo "## Full findings"
    echo ""
    if [[ ${#pending[@]} -gt 0 ]]; then
        echo "Not reviewed yet: ${pending[*]}."
        echo ""
    fi
    for d in "${chunk_dirs[@]}"; do
        cid="$(basename "$d")"
        synth="$(find_synthesis "$d")"
        [[ -n "$synth" ]] || continue
        echo "### Chunk: $cid"
        echo ""
        if [[ -n "$synth" && -f "$synth" ]]; then
            if [[ -f "$d/exclude.regex" ]]; then
                echo "<details><summary>scope</summary>"
                echo ""
                echo '```'
                echo "artifacts: $d/artifacts"
                echo '```'
                echo ""
                echo "</details>"
                echo ""
            fi
            strip_status "$synth"
        else
            echo "_No synthesis artifact was produced for this chunk. Check \`$d/console.log\`._"
        fi
        echo ""
        echo "---"
        echo ""
    done

    echo "## Caveats"
    echo ""
    echo "- **Chunk-local view.** Each chunk was reviewed with only its own files in the"
    echo "  prompt. A defect whose cause is in one chunk and whose effect is in another"
    echo "  cannot be found this way. The agents had the module directory as their"
    echo "  working directory and could read further, but nothing required them to."
    echo "- **Truncation.** Files were cut to the first N lines fed to the collector."
    echo "  Long classes were reviewed only down to that line."
    echo "- **Tests excluded.** \`src/test\` was filtered out of every chunk."
    echo "- **Self-arbitration.** Phase 4 is run by Claude, one of the two debaters."
    echo "  The rejection counts above are the check on that bias, not a guarantee."
} > "$OUT"

cat > "$SUMMARY_JSON" <<JSON
{
  "run_dir": "$RUN_DIR",
  "generated": "$(date -Iseconds 2>/dev/null || date)",
  "chunks": ${#chunk_dirs[@]},
  "chunks_done": $done_count,
  "totals": {
    "high_confidence": $tot_high,
    "medium_confidence": $tot_med,
    "skipped": $tot_skip,
    "from_claude": $tot_claude,
    "from_codex": $tot_codex,
    "rejected_from_claude": $tot_rej_claude,
    "rejected_from_codex": $tot_rej_codex,
    "files_modified": $tot_files
  },
  "by_chunk": [$json_chunks]
}
JSON

echo "report:  $OUT"
echo "summary: $SUMMARY_JSON"
echo "totals:  high=$tot_high medium=$tot_med skipped=$tot_skip (claude=$tot_claude codex=$tot_codex)"
