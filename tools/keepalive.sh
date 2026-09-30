#!/bin/bash
# Keeps the handheld awake and on ADB during development sessions.
#   tools/keepalive.sh [interval in seconds, default 60]
#
# Knulli's battery saver (/usr/bin/battery-saver.sh) dims the screen after
# system.batterysaver.timer (300 s) without input and suspends the handheld
# system.batterysaver.extendedtimer (900 s) later, which drops USB. It counts
# any file created or deleted in /dev/input as activity, so every interval
# this creates and deletes a hidden file there. Nothing else changes on the
# handheld: once the pings stop, the battery saver's timers run as usual.
#
# ADB: the adb executable (default: adb from PATH).
set -u
# Git Bash on Windows: pass device paths to adb unchanged
export MSYS_NO_PATHCONV=1
ADB=${ADB:-adb}
interval=${1:-60}
state=""
while true; do
	if "$ADB" shell 'touch /dev/input/.keepalive && rm -f /dev/input/.keepalive' > /dev/null 2>&1; then
		now="online"
	else
		now="offline"
	fi
	if [ "$now" != "$state" ]; then
		echo "$(date '+%H:%M:%S') handheld $now"
		state=$now
	fi
	sleep "$interval"
done
