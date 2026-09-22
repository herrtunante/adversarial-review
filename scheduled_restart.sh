#!/usr/bin/env bash
# Wait until the requested wall-clock hour, then start a chunked review.
#
#   ./scheduled_restart.sh [--at HH] [--driver SCRIPT] -- <driver arguments...>
#
# Everything after -- is handed to the driver unchanged, so this is the driver's
# own command line with a delay in front of it:
#
#   ./scheduled_restart.sh --at 18 -- --target ../collect -t 15 --resume \
#        -o reviews/collect-full chunks/collect.manifest
#
# --driver defaults to run_chunked_review.sh; name supervise_review.sh instead
# for a run that has to survive a quota reset. The review runs from this
# script's own directory, because every state file lives next to the script.
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

TARGET_HOUR="${SCHEDULED_HOUR:-18}"
DRIVER="run_chunked_review.sh"

usage() {
	sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
	exit "${1:-1}"
}

while [ $# -gt 0 ]; do
	case "$1" in
		--at) TARGET_HOUR="${2:-}"; shift 2 ;;
		--driver) DRIVER="${2:-}"; shift 2 ;;
		-h|--help) usage 0 ;;
		--) shift; break ;;
		*) echo "[sched] unknown option: $1" >&2; usage ;;
	esac
done

if [ $# -eq 0 ]; then
	echo "[sched] no driver arguments given" >&2
	usage
fi

case "$TARGET_HOUR" in
	''|*[!0-9]*) echo "[sched] --at wants an hour between 0 and 23, got '$TARGET_HOUR'" >&2; exit 1 ;;
esac
if [ "$TARGET_HOUR" -gt 23 ]; then
	echo "[sched] --at wants an hour between 0 and 23, got '$TARGET_HOUR'" >&2
	exit 1
fi

if [ ! -x "$SCRIPT_DIR/$DRIVER" ] && [ ! -f "$SCRIPT_DIR/$DRIVER" ]; then
	echo "[sched] no driver at $SCRIPT_DIR/$DRIVER" >&2
	exit 1
fi

now=$(date +%s)
start=$(date -d "today ${TARGET_HOUR}:00" +%s 2>/dev/null)
[ -z "$start" ] && start=$now
[ "$start" -le "$now" ] && start=$(date -d "tomorrow ${TARGET_HOUR}:00" +%s)
wait_s=$(( start - now ))
echo "[sched] now $(date '+%H:%M'), starting at ${TARGET_HOUR}:00 (in ${wait_s}s)"
sleep "$wait_s"
echo "[sched] starting review at $(date '+%H:%M')"
cd "$SCRIPT_DIR" || exit 1
exec "./$DRIVER" "$@"
