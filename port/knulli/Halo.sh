#!/bin/bash
# Halo: Combat Evolved, the native port of the decompilation, for Knulli
# handhelds with the Allwinner H700 (Anbernic RG35XX H and its family).
# Refer to port/knulli/README.md.
#
# This script goes in /userdata/roms/ports, the game in the halo folder
# beside it. Put an Xbox disc image of the game (.iso) in that folder: the
# first start copies its maps folder out (a few minutes), then the image can
# be deleted. The log of each start is halo/log.txt; the settings are
# halo/config.toml.
#
# Hold the hotkey (MENU or SELECT) and push START to quit.

GAMEDIR="$(cd "$(dirname "$0")/halo" && pwd)"
cd "$GAMEDIR" || exit 1
# one start at a time (or development run, tools/device/run.sh), before the
# log starts again: another meanwhile would take the raised clocks for the
# ones to put back. The game inherits the lock, which is held as long as it
# runs, even past this script. (flock, or Python's where it is missing:
# without either, no start.)
exec 9> /var/run/halo-lock
if ! { flock -n 9 || python3 -c 'import fcntl; fcntl.flock(9, fcntl.LOCK_EX | fcntl.LOCK_NB)'; } 2> /dev/null; then
	echo "$(date): Halo is running already; this start was refused" >> "$GAMEDIR/log.txt"
	exit 1
fi
exec > "$GAMEDIR/log.txt" 2>&1
echo "Halo for Knulli, $(date)"

if [ ! -f maps/ui.map ]; then
	image=$(ls -1 ./*.iso ./*.ISO ./*.xiso 2>/dev/null | head -n 1)
	if [ -z "$image" ]; then
		echo "no maps folder and no disc image (.iso) in $GAMEDIR"
		exit 1
	fi
	echo "copying the maps folder out of $image"
	python3 halo_extract.py "$image" "$GAMEDIR" || exit 1
fi

# the settings for this handheld, the first time (config.toml keeps them,
# with the others' defaults, which the game writes)
if [ ! -f config.toml ]; then
	cat > config.toml <<'EOF'
[display]
screen_width = 640
render_scale = 0.75
interpolation = true
fast_shaders = true
fast_textures = true

[update]
auto = false

[network]
online = false
EOF
fi

# the handheld's own controls (SDL2 would take them for another pad)
SDL_GAMECONTROLLERCONFIG="$(python3 sdl_mapping.py)"
export SDL_GAMECONTROLLERCONFIG

# the fastest clocks while the game runs: the CPU at its top frequency, the
# GPU held at its top step (the governor otherwise keeps it at the lowest).
# What they were is kept in /var/run (gone at a reboot), so that a start
# after a launcher that was killed outright puts them back first.
cpu=/sys/devices/system/cpu/cpufreq/policy0/scaling_governor
gpu=/sys/class/devfreq/gpu
saved=/var/run/halo-clocks
restore() {
	if [ -f "$saved" ]; then
		read -r cpu_governor gpu_minimum < "$saved"
		[ -n "$cpu_governor" ] && echo "$cpu_governor" > "$cpu" 2>/dev/null
		[ -n "$gpu_minimum" ] && echo "$gpu_minimum" > "$gpu/min_freq" 2>/dev/null
		rm -f "$saved"
	fi
	rm -f /var/run/battery-saver/halo.pause
}
restore
echo "$(cat "$cpu" 2>/dev/null) $(cat "$gpu/min_freq" 2>/dev/null)" > "$saved"
trap restore EXIT
echo performance > "$cpu" 2>/dev/null
tr ' ' '\n' < "$gpu/available_frequencies" 2>/dev/null | sort -n | tail -n 1 > "$gpu/min_freq" 2>/dev/null

# the battery saver must not dim or suspend the handheld during the game
mkdir -p /var/run/battery-saver && touch /var/run/battery-saver/halo.pause

# the game, with the signals the launcher gets passed on to it
./halo &
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
echo "exit status $status"
exit "$status"
