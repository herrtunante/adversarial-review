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
# for a run that has to survive a quota reset. Relative paths in the driver
# arguments are relative to the directory this is started from.
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

TARGET_HOUR="${SCHEDULED_HOUR:-18}"
DRIVER="run_chunked_review.sh"

usage() {
	sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
	exit "${1:-1}"
}

while [ $# -gt 0 ]; do
	case "$1" in
		--at|--driver)
			# Without this check a trailing --at made `shift 2` fail, nothing was
			# consumed, and the loop never ended.
			if [ $# -lt 2 ]; then
				echo "[sched] $1 needs a value" >&2
				usage
			fi
			if [ "$1" = "--at" ]; then TARGET_HOUR="$2"; else DRIVER="$2"; fi
			shift 2 ;;
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
	[0-9]|[0-9][0-9]) ;;
	*) echo "[sched] --at wants an hour between 0 and 23, got '$TARGET_HOUR'" >&2; exit 1 ;;
esac
# 10# so that 08 and 09 are read as decimal, not as invalid octal.
TARGET_HOUR=$((10#$TARGET_HOUR))
if [ "$TARGET_HOUR" -gt 23 ]; then
	echo "[sched] --at wants an hour between 0 and 23, got '$TARGET_HOUR'" >&2
	exit 1
fi

if [ -z "$DRIVER" ] || [ ! -f "$SCRIPT_DIR/$DRIVER" ]; then
	echo "[sched] no driver at $SCRIPT_DIR/$DRIVER" >&2
	exit 1
fi

# Seconds from now until the next HH:00.
#
# GNU date works the instant out itself, which stays right across a
# daylight-saving change. `date -d` does not exist on BSD/macOS, and there the
# old code ended up with an empty delay, a failing sleep and an immediate start.
# So fall back to arithmetic on the wall clock, which every date can supply
# (and which is an hour off only on the night the clocks change).
seconds_until_hour() {
	local hour="$1" now start h m s delay
	now=$(date +%s)
	start=$(date -d "today ${hour}:00" +%s 2>/dev/null) || start=""
	if [ -n "$start" ] && [ "$start" -le "$now" ]; then
		start=$(date -d "tomorrow ${hour}:00" +%s 2>/dev/null) || start=""
	fi
	case "$start" in
		''|*[!0-9]*) ;;
		*)
			if [ "$start" -gt "$now" ]; then
				echo $(( start - now ))
				return 0
			fi ;;
	esac
	read -r h m s <<< "$(date '+%H %M %S')"
	case "$h$m$s" in
		''|*[!0-9]*) return 1 ;;
	esac
	delay=$(( (hour * 3600 - (10#$h * 3600 + 10#$m * 60 + 10#$s) + 86400) % 86400 ))
	[ "$delay" -eq 0 ] && delay=86400
	echo "$delay"
}

wait_s=$(seconds_until_hour "$TARGET_HOUR")
case "$wait_s" in
	''|*[!0-9]*) echo "[sched] could not work out the delay until ${TARGET_HOUR}:00 - not starting" >&2; exit 1 ;;
esac
echo "[sched] now $(date '+%H:%M'), starting at $(printf '%02d' "$TARGET_HOUR"):00 (in ${wait_s}s)"
# A sleep that fails must not turn "start at 18:00" into "start now".
sleep "$wait_s" || { echo "[sched] sleep failed - not starting" >&2; exit 1; }
echo "[sched] starting review at $(date '+%H:%M')"
# No cd: the driver's arguments were written relative to the caller's directory
# and must keep that meaning. Both drivers find their state from their own path.
exec "$SCRIPT_DIR/$DRIVER" "$@"
