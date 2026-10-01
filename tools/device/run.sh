#!/bin/bash
# development runs: run.sh <seconds> [environment assignments...]
# The clocks pinned and the framebuffers set for the run, then put back as
# they were, also when the run is stopped (the signal is passed on to the
# game). The clocks found are kept where Halo.sh keeps them
# (/var/run/halo-clocks), so that a run or a start of the game after one that
# was killed outright puts them back first; one of either at a time
# (/var/run/halo-lock, which the game holds too).
cd /userdata/roms/ports/halo || exit 1
# (a benchmark holds the lock already, on the fd 9 it passes on)
[ "$(readlink /proc/$$/fd/9 2> /dev/null)" = /var/run/halo-lock ] || exec 9> /var/run/halo-lock
if ! { flock -n 9 || python3 -c 'import fcntl; fcntl.flock(9, fcntl.LOCK_EX | fcntl.LOCK_NB)'; } 2> /dev/null; then
	echo "Halo is running already" >> /userdata/system/halo-dev/run.log
	exit 1
fi
SDL_GAMECONTROLLERCONFIG="$(python3 sdl_mapping.py)"
export SDL_GAMECONTROLLERCONFIG
cpu=/sys/devices/system/cpu/cpufreq/policy0/scaling_governor
gpu=/sys/class/devfreq/gpu
saved=/var/run/halo-clocks
restore() {
	if [ -f "$saved" ]; then
		read -r cpu_governor gpu_minimum < "$saved"
		[ -n "$cpu_governor" ] && echo "$cpu_governor" > "$cpu"
		[ -n "$gpu_minimum" ] && echo "$gpu_minimum" > "$gpu/min_freq"
		rm -f "$saved"
	fi
}
restore
echo "$(cat "$cpu") $(cat "$gpu/min_freq")" > "$saved"
screen_lines=$(fbset 2>/dev/null | awk '/geometry/ {print $5}')
trap 'restore; [ -n "$screen_lines" ] && fbset -vyres "$screen_lines"' EXIT
echo performance > "$cpu"
tr " " "\n" < "$gpu/available_frequencies" | sort -n | tail -1 > "$gpu/min_freq"
fbset -vyres $(( ${HALO_FB_BUFFERS:-2} * 480 ))
seconds=$1
shift
env HALO_FPS_LOG=5 HALO_EXIT_AFTER="$seconds" "$@" ./halo > /userdata/system/halo-dev/run.log 2>&1 &
game=$!
# (a game asked to stop that has not ten seconds later is killed: a hung one
# must not keep the clocks and the lock)
trap 'kill -TERM "$game" 2>/dev/null; [ -n "${watchdog:-}" ] || { (exec 9>&-; sleep 10; kill -KILL "$game" 2>/dev/null) & watchdog=$!; }' TERM INT HUP
# (until the game itself has ended: a signal ends a wait early)
while :; do
	wait "$game"
	status=$?
	kill -0 "$game" 2>/dev/null || break
done
[ -z "${watchdog:-}" ] || kill "$watchdog" 2>/dev/null
echo "exit $status" >> /userdata/system/halo-dev/run.log
