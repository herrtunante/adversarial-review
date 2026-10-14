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
        -o|--out)
            # A flag given last has no $2, which `set -u` reported as an unbound variable.
            [[ $# -ge 2 && -n "$2" ]] || { echo "$1 needs a value" >&2; exit 1; }
            OUT="$2"; shift 2 ;;
        -h|--help)
            sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        # A mistyped option used to be taken as the run directory.
        -*) echo "unknown option: $1" >&2; echo "usage: $0 <run_dir> [-o out.md]" >&2; exit 1 ;;
        *) RUN_DIR="$1"; shift ;;
    esac
done

[[ -n "$RUN_DIR" && -d "$RUN_DIR" ]] || { echo "usage: $0 <run_dir> [-o out.md]" >&2; exit 1; }
RUN_DIR="$(cd "$RUN_DIR" && pwd)"
[[ -n "$OUT" ]] || OUT="$RUN_DIR/REPORT.md"
SUMMARY_JSON="$RUN_DIR/summary.json"

command -v jq > /dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

# chunk_is_reviewed, latest_iter_artifact, artifact_has_block, extract_status_block
# and strip_status_block. The driver, the
# supervisor and the file-list runner decide "is this chunk done?" with
# chunk_is_reviewed; the report used its own weaker test and could tabulate a
# chunk they had counted as failed.
AGG_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$AGG_SCRIPT_DIR/lib/transient.sh"

# jq with Git Bash's argument rewriting switched off: a run directory or a
# summary that starts with a slash would otherwise reach the native jq.exe
# converted to a Windows path. Both variables are ignored everywhere else.
# That jq.exe also ends its lines with CRLF, which is dropped so the output is
# the same on every platform (jq escapes any CR inside a string, so none of
# the ones removed here is data).
jq_raw() { MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' jq "$@" | tr -d '\r'; }

# Pull one KEY from a status block in an artifact. The block delimiters vary per
# phase, so the caller passes the block name.
#
# The block is the one extract_status_block returns - the LAST complete block in
# the file, the same one parse_status_block in adversarial_review.sh reads. This
# used to take the first: a report that quotes an example block ahead of its own
# was tabulated with the example's counters. A line is read the way the parser
# reads it: the key is what precedes the first colon, blanks removed and case
# ignored; the value is the rest, trimmed; the last line for a key wins. Prints
# an empty line, and still returns 0, when there is no block or no such key:
# both are normal here, and under `set -e` a failing command substitution in a
# bare assignment kills the script.
status_value() {
    local file="$1" block="$2" key="$3" body
    body="$(extract_status_block "$file" "$block")" || { echo ""; return 0; }
    awk -v key="$key" '
        { i = index($0, ":"); if (!i) next
          k = substr($0, 1, i - 1); gsub(/[ \t\r]/, "", k)
          if (toupper(k) == toupper(key)) v = substr($0, i + 1) }
        END { gsub(/^[ \t\r]+|[ \t\r]+$/, "", v); print v }' <<< "$body" || true
}

num() { local v="${1:-}"; [[ "$v" =~ ^[0-9]+$ ]] && echo "$v" || echo 0; }

# Locate a chunk's phase-4 report, tolerating a chunk that has not run yet.
#
# A chunk directory is created before the review starts, so while a run is still
# in progress the newest chunk has no artifacts/ yet. `find` on a missing
# directory exits non-zero, and under `set -e` that kills the whole script from
# inside the command substitution - which made aggregating a partial run fail.
find_synthesis() {
    local d="$1" f
    [[ -d "$d/artifacts" ]] || return 0
    f="$(latest_iter_artifact "$d/artifacts" 4_synthesis.md)"
    # Only a report with a complete status block counts. A refused or
    # unreachable synthesis call leaves a one-line file, which would otherwise
    # tabulate as a finished chunk with zero findings.
    if [[ -n "$f" ]] && artifact_has_block "$f" SYNTHESIS_STATUS; then
        echo "$f"
    fi
    return 0
}

# Strip the status block out of a report body so the merged document reads as
# prose; the counters are already tabulated above it.
strip_status() {
    # Only the block the counters were read from is removed. The sed range used
    # here before started at the first mention of the delimiter, so it also took
    # an example block quoted earlier in the report and, when the text after the
    # real block named the opening delimiter again, everything from there to the
    # end of the file. A file with no valid block comes back unchanged.
    strip_status_block "$1" SYNTHESIS_STATUS || cat "$1"
}

chunk_dirs=()
while IFS= read -r d; do
    # The driver writes exclude.regex into every chunk directory, and
    # run_filelist_review.sh writes files.list, so either one marks a chunk.
    # This skips the report's own web/ folder.
    [[ -f "$d/exclude.regex" || -f "$d/files.list" ]] || continue
    chunk_dirs+=("$d")
done < <(find "$RUN_DIR" -mindepth 1 -maxdepth 1 -type d | sort)

# Chunks the driver gave up on have no directory: it deletes a chunk whose
# agents were refused and records only an index.tsv row. Without them "N chunks,
# M completed" overstates how much of the project was covered. The last row for
# a chunk is its current state; "empty" means there was nothing in it to review.
abandoned=()
if [[ -f "$RUN_DIR/index.tsv" ]]; then
    while IFS=$'\t' read -r a_id a_status; do
        [[ -n "$a_id" && ! -d "$RUN_DIR/$a_id" ]] || continue
        [[ "$a_status" == "empty" ]] && continue
        abandoned+=("$a_id"$'\t'"$a_status")
    done < <(tr -d '\r' < "$RUN_DIR/index.tsv" \
             | awk -F'\t' 'NR > 1 && $1 != "" && $1 != "chunk_id" { if (!($1 in st)) order[++n] = $1; st[$1] = $4 }
                           END { for (i = 1; i <= n; i++) printf "%s\t%s\n", order[i], st[order[i]] }')
fi
total_chunks=$(( ${#chunk_dirs[@]} + ${#abandoned[@]} ))

# Checked only now: when every chunk was abandoned and its directory deleted,
# the index rows are all that is left, and that run is the one whose report is
# most needed. From here on chunk_dirs may be empty, and bash before 4.4 treats
# "${empty[@]}" as an unbound variable under `set -u`, hence the guarded loops.
[[ $total_chunks -gt 0 ]] || { echo "no chunk directories or indexed chunks under $RUN_DIR" >&2; exit 1; }

tot_high=0; tot_med=0; tot_skip=0; tot_claude=0; tot_codex=0
tot_rej_claude=0; tot_rej_codex=0; tot_files=0
done_count=0
pending=()
rows=""
json_chunks=""
# Per chunk, in chunk_dirs order: pending | clean | done, and the report path.
# Decided once here and reused for the findings section; chunk_is_reviewed
# reads every artifact, which is slow where starting a process is (Windows).
chunk_state=()
chunk_synth=()

for d in ${chunk_dirs[@]+"${chunk_dirs[@]}"}; do
    cid="$(basename "$d")"

    # chunk_is_reviewed is the runners' own test: a chunk they would redo is
    # not tabulated, whatever its synthesis file looks like.
    if ! chunk_is_reviewed "$d"; then
        chunk_state+=("pending"); chunk_synth+=("")
        rows+="| $cid | - | - | - | - | not reviewed yet |"$'\n'
        json_chunks+="$(jq_raw -nc --arg chunk "$cid" '{chunk: $chunk, status: "pending"}')"$'\n'
        pending+=("$cid")
        continue
    fi
    done_count=$((done_count + 1))

    synth="$(find_synthesis "$d")"
    chunk_synth+=("$synth")
    if [[ -z "$synth" ]]; then
        # Reviewed, and no synthesis: both agents called the chunk clean in
        # phase 1 and the run ended there.
        chunk_state+=("clean")
        summary="Clean: both agents reported no issues in phase 1, so there was no debate or synthesis"
        rows+="| $cid | 0 | 0 | 0 | 0/0 | $summary |"$'\n'
        json_chunks+="$(jq_raw -nc --arg chunk "$cid" --arg summary "$summary" \
            '{chunk: $chunk, status: "clean", high: 0, medium: 0, skipped: 0, from_claude: 0, from_codex: 0,
              rejected_claude: 0, rejected_codex: 0, summary: $summary}')"$'\n'
        continue
    fi
    chunk_state+=("done")

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
    # Built by jq, not by hand: a tab or any other control character in a
    # summary made the file invalid JSON.
    json_chunks+="$(jq_raw -nc --arg chunk "$cid" --arg summary "$summary" \
        --argjson high "$high" --argjson medium "$med" --argjson skipped "$skip" \
        --argjson from_claude "$fclaude" --argjson from_codex "$fcodex" \
        --argjson rejected_claude "$rclaude" --argjson rejected_codex "$rcodex" \
        '{chunk: $chunk, high: $high, medium: $medium, skipped: $skipped, from_claude: $from_claude,
          from_codex: $from_codex, rejected_claude: $rejected_claude, rejected_codex: $rejected_codex,
          summary: $summary}')"$'\n'
done

for a in ${abandoned[@]+"${abandoned[@]}"}; do
    a_id="${a%%$'\t'*}"; a_status="${a#*$'\t'}"
    rows+="| $a_id | - | - | - | - | not reviewed (${a_status:-no status}, no chunk directory) |"$'\n'
    json_chunks+="$(jq_raw -nc --arg chunk "$a_id" --arg run_status "$a_status" \
        '{chunk: $chunk, status: "pending", run_status: $run_status}')"$'\n'
    pending+=("$a_id")
done

{
    echo "# Adversarial Review - Consolidated Report"
    echo ""
    echo "Run directory: \`$RUN_DIR\`"
    echo "Generated: $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
    echo "The project is split into $total_chunks chunks; $done_count of them have a completed review."
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
    for (( i = 0; i < ${#chunk_dirs[@]}; i++ )); do
        d="${chunk_dirs[$i]}"
        cid="$(basename "$d")"
        [[ "${chunk_state[$i]}" != "pending" ]] || continue
        synth="${chunk_synth[$i]}"
        echo "### Chunk: $cid"
        echo ""
        if [[ -n "$synth" && -f "$synth" ]]; then
            if [[ -f "$d/exclude.regex" || -f "$d/files.list" ]]; then
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
            echo "_Clean: both agents reported no issues in phase 1, so the run ended there and no synthesis was written._"
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
    # Only the manifest driver filters tests, and it marks its chunks with
    # exclude.regex. A file-list chunk (files.list) holds exactly the files it
    # names, tests included if they were listed.
    if compgen -G "$RUN_DIR/*/exclude.regex" > /dev/null; then
        echo "- **Tests excluded.** \`src/test\` was filtered out of every chunk built from a manifest."
    fi
    echo "- **Self-arbitration.** Phase 4 is run by Claude, one of the two debaters."
    echo "  The rejection counts above are the check on that bias, not a guarantee."
} > "$OUT"

printf '%s' "$json_chunks" | jq_raw -s \
    --arg run_dir "$RUN_DIR" --arg generated "$(date -Iseconds 2>/dev/null || date)" \
    --argjson chunks "$total_chunks" --argjson chunks_done "$done_count" \
    --argjson high "$tot_high" --argjson medium "$tot_med" --argjson skipped "$tot_skip" \
    --argjson from_claude "$tot_claude" --argjson from_codex "$tot_codex" \
    --argjson rej_claude "$tot_rej_claude" --argjson rej_codex "$tot_rej_codex" \
    --argjson files_modified "$tot_files" \
    '{
       run_dir: $run_dir,
       generated: $generated,
       chunks: $chunks,
       chunks_done: $chunks_done,
       totals: {
         high_confidence: $high,
         medium_confidence: $medium,
         skipped: $skipped,
         from_claude: $from_claude,
         from_codex: $from_codex,
         rejected_from_claude: $rej_claude,
         rejected_from_codex: $rej_codex,
         files_modified: $files_modified
       },
       by_chunk: .
     }' > "$SUMMARY_JSON.tmp"
mv "$SUMMARY_JSON.tmp" "$SUMMARY_JSON"

echo "report:  $OUT"
echo "summary: $SUMMARY_JSON"
echo "totals:  high=$tot_high medium=$tot_med skipped=$tot_skip (claude=$tot_claude codex=$tot_codex)"
