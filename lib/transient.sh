# Recognising an agent that was refused, rather than one that found nothing.
#
# Sourced by run_chunked_review.sh, supervise_review.sh, run_filelist_review.sh and aggregate_review.sh. It lives
# here because all of them decide whether a chunk is finished, and when they decided it with different rules the
# supervisor kept reporting "all chunks complete" for chunks the driver would have redone.
#
# - A refused or unreachable Claude call writes one short line in place of the review ("You've hit your session
#   limit ...", "API Error: Can't reach the API server ... (ENOTFOUND)"). The broad phrases below are only trusted
#   in files that small. Matched against a whole review they misfire: a finding about a login controller with no
#   rate limiting reads as a quota refusal, and the chunk would be thrown away three times over.
# - A Codex call that dies before answering leaves its transcript as the artifact (run_codex's fallback, in older
#   versions the whole thing). The banner never appears in a real review, so the broad phrases are safe there at
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

# Does the file carry a complete status block, opening and closing delimiter both? A block cut off mid-way (a
# timeout while the agent was still writing) has only the first.
artifact_has_block() {
    grep -q -- "---$2---" "$1" 2>/dev/null && grep -q -- "---END_$2---" "$1" 2>/dev/null
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

artifact_is_codex_no_message() {
    local line
    [[ -f "$1" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        [[ "$line" =~ $CODEX_NO_MESSAGE_RE ]]
        return
    done < "$1"
    return 1
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

artifact_is_transient_failure() {
    local f="$1"
    [[ -f "$f" ]] || return 1
    # A short file is only a refusal if it is not a real answer: a genuine 1 KB review that says "no rate limiting
    # on the login endpoint" used to be discarded as a quota refusal. The exemption does not apply to the Codex
    # no-final-message note, whose quoted transcript lines can contain the prompt's example status block.
    if [[ $(wc -c < "$f") -le $TRANSIENT_SHORT_MAX_BYTES ]] \
       && grep -qEi -- "$TRANSIENT_SHORT_RE" "$f" 2>/dev/null \
       && { artifact_is_codex_no_message "$f" || ! artifact_has_real_answer "$f"; }; then
        return 0
    fi
    if grep -qa -- "$TRANSIENT_CODEX_BANNER" "$f" 2>/dev/null \
       && grep -qEi -- "$TRANSIENT_SHORT_RE" "$f" 2>/dev/null; then
        return 0
    fi
    grep -qEi -- "$TRANSIENT_LOG_RE" "$f" 2>/dev/null
}

# Did any agent in this chunk fail for a reason that goes away on its own - an exhausted quota or a dropped
# network? Those artifacts parse to zero issues and are indistinguishable from a clean review downstream, so the
# chunk must be retried after the outage rather than recorded.
chunk_hit_transient_failure() {
    local chunk_out="$1" f
    [[ -d "$chunk_out/artifacts" ]] || return 1
    for f in "$chunk_out"/artifacts/*.md; do
        artifact_is_transient_failure "$f" && return 0
    done
    return 1
}

# A failed agent call of any kind, transient or not: the two shapes above, the Codex no-final-message note (a
# timeout is exit code 124 and matches no quota pattern), or an artifact with nothing in it. Wider than
# artifact_is_transient_failure on purpose - that one decides whether waiting for the quota is worth it, this one
# decides whether the debate had both agents in it.
artifact_is_failed_call() {
    local f="$1"
    [[ -f "$f" ]] || return 1
    [[ -s "$f" ]] || return 0
    artifact_is_codex_no_message "$f" && return 0
    artifact_is_transient_failure "$f"
}

chunk_has_failed_call() {
    local chunk_out="$1" f
    [[ -d "$chunk_out/artifacts" ]] || return 1
    for f in "$chunk_out"/artifacts/*.md; do
        artifact_is_failed_call "$f" && return 0
    done
    return 1
}

# The one answer to "has this chunk been reviewed?", used by the driver to skip on --resume, by the supervisor to
# count what is left, by run_filelist_review.sh and by the aggregator. Two shapes are accepted:
#
# - tracking.json says "clean": both agents found nothing in phase 1, the run ended there and there is
#   legitimately no synthesis. Demanding one redid such a chunk forever.
# - otherwise the newest synthesis report must carry a complete status block.
#
# Either way no artifact may be a failed agent call. A synthesis block alone is not enough: the synthesis is
# written on top of whatever the earlier phases produced, so it is perfectly valid even when one of the two
# agents was refused or timed out throughout.
chunk_is_reviewed() {
    local chunk_out="$1" status synth
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
    artifact_has_block "$synth" SYNTHESIS_STATUS
}
