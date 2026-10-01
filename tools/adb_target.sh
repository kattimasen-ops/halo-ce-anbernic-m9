#!/bin/bash
# Sourced by the tools that talk to the handheld, which run adb as "$ADB":
# device_check makes sure that the device is the handheld before anything is
# pushed to it or run on it.
#
# Environment:
#   ADB             the adb executable (default: adb from PATH)
#   ANDROID_SERIAL  adb's own: the handheld's serial (adb devices), needed
#                   when more than one device is attached
ADB=${ADB:-adb}

# the device is an H616-family handheld (the H700 is one) running Knulli. It
# is pinned first (ANDROID_SERIAL), so that the tool's later adb commands go
# to it and to no other device attached meanwhile. (adb on Windows ends its
# lines with CR LF.)
device_check() {
	local compatible
	if [ -z "${ANDROID_SERIAL:-}" ]; then
		ANDROID_SERIAL=$("$ADB" devices | tr -d '\r' |
			awk 'NR > 1 && $2 == "device" {count++; serial = $1} END {if (count == 1) print serial}')
		[ -n "$ANDROID_SERIAL" ] || { echo "no adb device, or more than one: set ANDROID_SERIAL" >&2; return 1; }
		export ANDROID_SERIAL
	fi
	compatible=$("$ADB" shell 'tr "\0" " " < /proc/device-tree/compatible; test -d /userdata/roms/ports && echo knulli' 2>/dev/null)
	case "$compatible" in
	*sun50iw9*knulli*) return 0 ;;
	esac
	echo "the adb device is not a Knulli H700 handheld (set ANDROID_SERIAL when more than one device is attached)" >&2
	return 1
}
