# Recognising an agent that was refused, rather than one that found nothing.
#
# Sourced by adversarial_review.sh, run_chunked_review.sh, supervise_review.sh, run_filelist_review.sh and
# aggregate_review.sh. It lives here because all of them decide whether a chunk is finished, and when they decided
# it with different rules the supervisor kept reporting "all chunks complete" for chunks the driver would have
# redone.
#
# - A refused or unreachable Claude call writes one short line in place of the review ("You've hit your session
#   limit ...", "API Error: Can't reach the API server ... (ENOTFOUND)"). The broad phrases below are only trusted
#   in files that small. Matched against a whole review they misfire: a finding about a login controller with no
#   rate limiting reads as a quota refusal, and the chunk would be thrown away three times over.
# - A Codex call that dies before answering leaves its transcript as the artifact (run_codex's fallback, in older
#   versions the whole thing). The banner never opens a real review, so the broad phrases are safe there at
#   any size - which is what a refusal buried in 150 KB of prompt echo needs.
# - Transport errors from Codex are timestamped log lines, which never occur in source code or review prose, so
#   those are safe to match in a file of any size.

TRANSIENT_SHORT_RE='hit your (session|usage) limit|usage limit reached|quota exceeded|rate.?limit|resets [0-9]|API Error|reach the API server|ENOTFOUND|EAI_AGAIN|ECONNRESET|ECONNREFUSED|ETIMEDOUT|overloaded|stream disconnected|error sending request'
TRANSIENT_SHORT_MAX_BYTES=2048
TRANSIENT_LOG_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z +ERROR .*(stream disconnected|error sending request|connection (reset|refused|closed)|dns error|timed out)'
TRANSIENT_CODEX_BANNER='OpenAI Codex v'

# Written by run_codex in adversarial_review.sh as the first line of the artifact when Codex gave no final
# message, whatever the cause (timeout, quota, crash). Only the first non-blank line is tested: a review OF this
# repository quotes the phrase in its prose.
CODEX_NO_MESSAGE_RE='^CODEX PRODUCED NO FINAL MESSAGE \(exit code [0-9]+\)'

# The one definition of a status block, shared by the parser in adversarial_review.sh, the aggregator and every
# "is this chunk finished?" test below. When each had its own, the report table read the first block in a file
# while the parser read the last, and a file that merely named both delimiters in a sentence counted as answered.
#
#   extract_status_block FILE BLOCK_NAME
#
# prints the lines of the LAST complete block named BLOCK_NAME (for SYNTHESIS_STATUS the delimiters are
# ---SYNTHESIS_STATUS--- and ---END_SYNTHESIS_STATUS---), without the two delimiter lines and without trailing
# CRs, and returns 0. It prints nothing and returns non-zero when:
#
# - the file is missing or unreadable, or no block name was given;
# - there is no complete block;
# - a block is opened after the last complete one and never closed. That is an answer cut off while the agent
#   was still writing its status, and the complete block before it is then an example quoted in the prose.
#
# A delimiter counts only when it is a line of its own. Spaces and tabs around it and a trailing CR are allowed;
# a delimiter named inside a sentence, a bullet or a line of code is not one. Reports about this repository quote
# the delimiters in exactly those places. An opening delimiter inside an open block restarts the block, and a
# closing delimiter with no block open is ignored. It is one awk and no pipeline, so it is safe under `set -e`
# and `pipefail`, and it uses nothing defined outside this file.
extract_status_block() {
    status_block_scan "${1:-}" "${2:-}" body
}

# Does the file carry a complete status block? The boolean form of extract_status_block, with the same rules.
artifact_has_block() {
    status_block_scan "${1:-}" "${2:-}" body > /dev/null
}

#   strip_status_block FILE BLOCK_NAME
#
# prints the file without the block extract_status_block returns, delimiter lines included, and nothing else
# removed: an example block earlier in the text stays. A file with no valid block is printed unchanged, so an
# unterminated opening delimiter never takes the rest of the file with it. Returns non-zero only when the file
# is missing or unreadable.
strip_status_block() {
    status_block_scan "${1:-}" "${2:-}" strip
}

# The scan behind both, so that what is extracted and what is stripped are the same lines by construction.
# a and b are the line numbers of the last complete block's delimiters.
status_block_scan() {
    local file="$1" block_name="$2" mode="$3"
    [[ -n "$block_name" && -f "$file" ]] || return 1
    awk -v s="---${block_name}---" -v e="---END_${block_name}---" -v mode="$mode" '
        { all[NR] = $0; t = $0; sub(/\r$/, "", t); gsub(/^[ \t]+|[ \t]+$/, "", t) }
        t == e { if (inb) { a = open; b = NR; found = 1 }; inb = 0; next }
        t == s { open = NR; inb = 1; next }
        END {
            ok = found && !inb
            if (mode == "strip") {
                for (i = 1; i <= NR; i++) if (!ok || i < a || i > b) print all[i]
                exit 0
            }
            if (!ok) exit 1
            for (i = a + 1; i < b; i++) { line = all[i]; sub(/\r$/, "", line); print line }
        }' "$file" 2>/dev/null
}

# Highest-numbered iter<N>_<suffix> in a directory. A plain sort puts iter9 after iter10. Prints nothing when
# there is none (or no such directory) and always returns 0, so it is safe under `set -e`.
latest_iter_artifact() {
    local dir="$1" suffix="$2" f n best="" best_n=-1
    for f in "$dir"/iter*_"$suffix"; do
        [[ -f "$f" ]] || continue
        n="${f##*/iter}"; n="${n%%_*}"
        [[ "$n" =~ ^[0-9]+$ ]] || continue
        if (( 10#$n > best_n )); then best_n=$((10#$n)); best="$f"; fi
    done
    [[ -n "$best" ]] && printf '%s\n' "$best"
    return 0
}

# Highest iteration number among a directory's iter<N>_*.md artifacts, compared as numbers (iter10 beats iter9).
# Prints nothing when there is none (or no such directory) and always returns 0.
latest_iteration() {
    local dir="$1" f n best=-1
    for f in "$dir"/iter*_*.md; do
        [[ -f "$f" ]] || continue
        n="${f##*/iter}"; n="${n%%_*}"
        [[ "$n" =~ ^[0-9]+$ ]] || continue
        if (( 10#$n > best )); then best=$((10#$n)); fi
    done
    if (( best >= 0 )); then printf '%s\n' "$best"; fi
    return 0
}

# Does artifact $1 belong to iteration $2? A file that is not named iter<N>_... belongs to every iteration, so
# anything unexpected in artifacts/ is still looked at.
artifact_in_iteration() {
    local n="${1##*/}"
    [[ "$n" == iter*_* ]] || return 0
    n="${n#iter}"; n="${n%%_*}"
    [[ "$n" =~ ^[0-9]+$ ]] || return 0
    (( 10#$n == $2 ))
}

# The same for Claude: written by run_claude as the first line of the artifact when the call exited non-zero or
# printed nothing. run_claude keeps stderr out of the artifact, so without this note a refusal printed on stderr
# would leave an empty file and one printed on stdout a bare line, with nothing to say the call had failed. Up to
# five lines of what the CLI did print follow the note; those are what tell a quota or network failure from a
# timeout or a crash.
CLAUDE_NO_OUTPUT_RE='^CLAUDE PRODUCED NO OUTPUT \(exit code [0-9]+\)'

# Is the first non-blank line of file $1 a match for the regex $2?
artifact_first_line_matches() {
    local line
    [[ -f "$1" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        [[ "$line" =~ $2 ]]
        return
    done < "$1"
    return 1
}

artifact_is_codex_no_message() {
    artifact_first_line_matches "$1" "$CODEX_NO_MESSAGE_RE"
}

artifact_is_claude_no_output() {
    artifact_first_line_matches "$1" "$CLAUDE_NO_OUTPUT_RE"
}

# Either agent's failure note.
artifact_is_failure_note() {
    artifact_is_codex_no_message "$1" || artifact_is_claude_no_output "$1"
}

# An agent that answered: a complete status block for one of the four phases, or the bare NO_ISSUES line that
# parse_status_block accepts instead of one. A one-line refusal never carries either.
artifact_has_real_answer() {
    local f="$1" b
    for b in REVIEW_STATUS CROSS_REVIEW_STATUS META_REVIEW_STATUS SYNTHESIS_STATUS; do
        artifact_has_block "$f" "$b" && return 0
    done
    grep -qE '^[[:space:]]*NO_ISSUES[[:space:]]*$' "$f" 2>/dev/null
}

# Does the file open with the Codex banner, as a transcript does? Only the first five lines are read. Looking for
# the banner anywhere misfired on a genuine review that QUOTED it next to a quota phrase - which is what reviewing
# this tool's own source produces: a full report was thrown away and the chunk redone. One awk rather than
# `head | grep -q`: grep leaves at the first match, and under `pipefail` a head killed by the closed pipe turns
# the match into a failure.
artifact_opens_with_codex_banner() {
    [[ -f "$1" ]] || return 1
    awk -v b="$TRANSIENT_CODEX_BANNER" 'NR > 5 { exit } index($0, b) { f = 1; exit } END { exit !f }' "$1" 2>/dev/null
}

artifact_is_transient_failure() {
    local f="$1"
    [[ -f "$f" ]] || return 1
    # A short file is only a refusal if it is not a real answer: a genuine 1 KB review that says "no rate limiting
    # on the login endpoint" used to be discarded as a quota refusal. The exemption does not apply to an agent's
    # failure note, whose quoted lines can contain the prompt's example status block.
    if [[ $(wc -c < "$f") -le $TRANSIENT_SHORT_MAX_BYTES ]] \
       && grep -qEi -- "$TRANSIENT_SHORT_RE" "$f" 2>/dev/null \
       && { artifact_is_failure_note "$f" || ! artifact_has_real_answer "$f"; }; then
        return 0
    fi
    # A Codex transcript opens with the banner, and there the broad phrases are trusted at any size.
    if artifact_opens_with_codex_banner "$f" && grep -qEi -- "$TRANSIENT_SHORT_RE" "$f" 2>/dev/null; then
        return 0
    fi
    # Transport errors are timestamped log lines. For the same reason they only count in a transcript, a
    # failure note, or a file that is not a real answer: a review can quote one in a code block.
    grep -qEi -- "$TRANSIENT_LOG_RE" "$f" 2>/dev/null \
        && { artifact_opens_with_codex_banner "$f" || artifact_is_failure_note "$f" \
             || ! artifact_has_real_answer "$f"; }
}

# Did any agent in iteration $2 of this chunk fail for a reason that goes away on its own? See
# chunk_hit_transient_failure.
chunk_iteration_hit_transient_failure() {
    local chunk_out="$1" n="$2" f
    for f in "$chunk_out"/artifacts/*.md; do
        [[ -f "$f" ]] || continue
        artifact_in_iteration "$f" "$n" || continue
        artifact_is_transient_failure "$f" && return 0
    done
    return 1
}

# Did any agent in this chunk fail for a reason that goes away on its own - an exhausted quota or a dropped
# network? Those artifacts parse to zero issues and are indistinguishable from a clean review downstream, so the
# chunk must be retried after the outage rather than recorded.
#
# Only the newest iteration present is judged. A run that fixes code goes round again, and a call refused in
# iteration 1 says nothing about a later iteration that both agents completed; judging every iteration marked
# such a chunk unreviewed for good. A directory with no iter<N>_ artifact at all has every .md file judged.
chunk_hit_transient_failure() {
    local chunk_out="$1" n
    [[ -d "$chunk_out/artifacts" ]] || return 1
    n="$(latest_iteration "$chunk_out/artifacts")"
    chunk_iteration_hit_transient_failure "$chunk_out" "${n:-0}"
}

# A failed agent call of any kind, transient or not: the two shapes above, either agent's failure note (a
# timeout is exit code 124 and matches no quota pattern), or an artifact with nothing in it. Wider than
# artifact_is_transient_failure on purpose - that one decides whether waiting for the quota is worth it, this one
# decides whether the debate had both agents in it.
artifact_is_failed_call() {
    local f="$1"
    [[ -f "$f" ]] || return 1
    [[ -s "$f" ]] || return 0
    artifact_is_failure_note "$f" && return 0
    artifact_is_transient_failure "$f"
}

# Is any artifact of iteration $2 of this chunk a failed call?
chunk_iteration_has_failed_call() {
    local chunk_out="$1" n="$2" f
    for f in "$chunk_out"/artifacts/*.md; do
        [[ -f "$f" ]] || continue
        artifact_in_iteration "$f" "$n" || continue
        artifact_is_failed_call "$f" && return 0
    done
    return 1
}

# Is any artifact of the chunk's newest iteration a failed call? Newest only, for the reason given at
# chunk_hit_transient_failure.
chunk_has_failed_call() {
    local chunk_out="$1" n
    [[ -d "$chunk_out/artifacts" ]] || return 1
    n="$(latest_iteration "$chunk_out/artifacts")"
    chunk_iteration_has_failed_call "$chunk_out" "${n:-0}"
}

# The one answer to "has this chunk been reviewed?", used by the driver to skip on --resume, by the supervisor to
# count what is left, by run_filelist_review.sh and by the aggregator. Two shapes are accepted:
#
# - tracking.json says "clean": both agents found nothing in phase 1, the run ended there and there is
#   legitimately no synthesis. Demanding one redid such a chunk forever.
# - otherwise the newest synthesis report must carry a complete status block.
#
# Either way no artifact of the newest iteration may be a failed agent call. A synthesis block alone is not
# enough: the synthesis is written on top of whatever the earlier phases produced, so it is perfectly valid even
# when one of the two agents was refused or timed out throughout. For the same reason, when the newest synthesis
# belongs to an earlier iteration than the newest artifact (a later iteration stopped before its own synthesis),
# that iteration's artifacts are checked as well: the verdict rests on them.
chunk_is_reviewed() {
    local chunk_out="$1" status synth n
    [[ -f "$chunk_out/tracking.json" ]] || return 1
    chunk_has_failed_call "$chunk_out" && return 1
    status="$(jq -r '.status // ""' "$chunk_out/tracking.json" 2>/dev/null | tr -d '\r' || true)"
    if [[ "$status" == "clean" ]]; then
        # At least the two phase-1 answers must be there; a bare tracking.json proves nothing.
        [[ -n "$(latest_iter_artifact "$chunk_out/artifacts" 1_claude_review.md)" \
           && -n "$(latest_iter_artifact "$chunk_out/artifacts" 1_codex_review.md)" ]]
        return
    fi
    synth="$(latest_iter_artifact "$chunk_out/artifacts" 4_synthesis.md)"
    [[ -n "$synth" ]] || return 1
    artifact_has_block "$synth" SYNTHESIS_STATUS || return 1
    n="${synth##*/iter}"; n="$((10#${n%%_*}))"
    if [[ "$n" != "$(latest_iteration "$chunk_out/artifacts")" ]]; then
        chunk_iteration_has_failed_call "$chunk_out" "$n" && return 1
    fi
    return 0
}
