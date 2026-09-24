# Recognising an agent that was refused, rather than one that found nothing.
#
# Sourced by run_chunked_review.sh and supervise_review.sh. It lives here because both of them decide whether a
# chunk is finished, and when they decided it with different rules the supervisor kept reporting "all chunks
# complete" for chunks the driver would have redone.
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

artifact_is_transient_failure() {
    local f="$1"
    [[ -f "$f" ]] || return 1
    if [[ $(wc -c < "$f") -le $TRANSIENT_SHORT_MAX_BYTES ]] \
       && grep -qEi -- "$TRANSIENT_SHORT_RE" "$f" 2>/dev/null; then
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

# The one answer to "has this chunk been reviewed?", used by the driver to skip on --resume and by the supervisor
# to count what is left. A synthesis block alone is not enough: the synthesis is written on top of whatever the
# earlier phases produced, so it is perfectly valid even when one of the two agents was refused throughout.
chunk_is_reviewed() {
    local chunk_out="$1"
    [[ -f "$chunk_out/tracking.json" ]] || return 1
    local synth
    synth="$(find "$chunk_out/artifacts" -name 'iter*_4_synthesis.md' -type f 2>/dev/null | sort | tail -1)"
    [[ -n "$synth" && -f "$synth" ]] || return 1
    grep -q -- '---SYNTHESIS_STATUS---' "$synth" 2>/dev/null || return 1
    ! chunk_hit_transient_failure "$chunk_out"
}
