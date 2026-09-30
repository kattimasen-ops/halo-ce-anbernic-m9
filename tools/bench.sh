#!/bin/bash
# Runs one benchmark of the Knulli port on the handheld over ADB.
#   tools/bench.sh <level> <seconds> <label> [HALO_SETTING=value ...]
#
# Loads levels\<level>\<level> at start-up (init.txt), plays for <seconds>,
# takes screenshots at 60% and 90% of the run with the threads' CPU use at
# the second, and saves the log and the screenshots in bench/<label>/.
#
# Before the first run: install the port in /userdata/roms/ports/halo and
# stop EmulationStation (adb shell /etc/init.d/S31emulationstation stop).
# This script copies tools/device/run.sh, the device-side runner, to
# /userdata/system/halo-dev/ on every run.
#
# Environment:
#   ADB              the adb executable (default: adb from PATH)
#   BENCH_DIR        where the results go (default: bench/ in the current folder)
#   COOL_TO          start only once the CPU is below this temperature (default 50 C)
#   INIT_EXTRA       console commands for init.txt, separated by ';'
#   HALO_FB_BUFFERS  framebuffers for the run (default 2)
set -u
# Git Bash on Windows: pass device paths to adb unchanged
export MSYS_NO_PATHCONV=1
HERE="$(cd "$(dirname "$0")" && pwd)"
ADB=${ADB:-adb}
# a local path as adb understands it (cygpath: Git Bash with the Windows adb.exe)
local_path() {
	if command -v cygpath > /dev/null 2>&1; then cygpath -w "$1"; else printf '%s\n' "$1"; fi
}
if [ $# -lt 3 ]; then
	echo "usage: $0 <level> <seconds> <label> [HALO_SETTING=value ...]" >&2
	exit 2
fi
level=$1
seconds=$2
label=$3
shift 3
out="${BENCH_DIR:-bench}/$label"
mkdir -p "$out"

"$ADB" shell 'mkdir -p /userdata/system/halo-dev' > /dev/null
"$ADB" push "$(local_path "$HERE/device/run.sh")" /userdata/system/halo-dev/run.sh > /dev/null
"$ADB" shell 'chmod 755 /userdata/system/halo-dev/run.sh' > /dev/null

{
	printf 'display_framerate true\r\n'
	if [ -n "${INIT_EXTRA:-}" ]; then
		printf '%s' "$INIT_EXTRA" | tr ';' '\n' | sed 's/$/\r/'
		printf '\r\n'
	fi
	printf 'map_name levels\\%s\\%s\r\n' "$level" "$level"
} > "$out/init.txt"
"$ADB" push "$(local_path "$out/init.txt")" /userdata/roms/ports/halo/init.txt > /dev/null

first=$((seconds * 6 / 10))
second=$((seconds * 9 / 10 - first))
rest=$((seconds - first - second + 8))
cat > "$out/device.sh" <<EOF
rm -f /tmp/profile.txt
# the battery saver must not suspend the handheld (and ADB) during the run
mkdir -p /var/run/battery-saver && touch /var/run/battery-saver/halo.pause
# the same start for every run: the CPU cooled below COOL_TO (default 50) C
while [ \$(cat /sys/class/thermal/thermal_zone0/temp) -gt ${COOL_TO:-50}000 ]; do sleep 5; done
HALO_FB_BUFFERS=${HALO_FB_BUFFERS:-2} setsid /userdata/system/halo-dev/run.sh $seconds HALO_PROFILE_FILE=/tmp/profile.txt $* < /dev/null > /dev/null 2>&1 &
sleep $first
knulli-screenshot /tmp/shot1.png
sleep $second
knulli-screenshot /tmp/shot2.png
top -b -H -n 2 -d 3 | grep -E '^%Cpu|halo' | tail -24 > /tmp/top.txt
sleep $rest
while pidof halo > /dev/null; do sleep 1; done
rm -f /var/run/battery-saver/halo.pause
rm -f /userdata/roms/ports/halo/init.txt
cat /userdata/system/halo-dev/run.log
echo ---top---
cat /tmp/top.txt
EOF
"$ADB" push "$(local_path "$out/device.sh")" /tmp/bench.sh > /dev/null
"$ADB" shell "sh /tmp/bench.sh" > "$out/run.log"
"$ADB" pull /tmp/shot1.png "$(local_path "$out/shot1.png")" > /dev/null
"$ADB" pull /tmp/shot2.png "$(local_path "$out/shot2.png")" > /dev/null
"$ADB" pull /tmp/profile.txt "$(local_path "$out/profile.txt")" > /dev/null 2>&1
grep -E "fps |exit|signal|fatal|guest abort" "$out/run.log"
