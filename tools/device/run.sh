#!/bin/bash
# development runs: run.sh <seconds> [environment assignments...]
cd /userdata/roms/ports/halo || exit 1
SDL_GAMECONTROLLERCONFIG="$(python3 sdl_mapping.py)"
export SDL_GAMECONTROLLERCONFIG
echo performance > /sys/devices/system/cpu/cpufreq/policy0/scaling_governor
tr " " "\n" < /sys/class/devfreq/gpu/available_frequencies | sort -n | tail -1 > /sys/class/devfreq/gpu/min_freq
fbset -vyres $(( ${HALO_FB_BUFFERS:-2} * 480 ))
seconds=$1
shift
env HALO_FPS_LOG=5 HALO_EXIT_AFTER="$seconds" "$@" ./halo > /userdata/system/halo-dev/run.log 2>&1
echo "exit $?" >> /userdata/system/halo-dev/run.log
echo schedutil > /sys/devices/system/cpu/cpufreq/policy0/scaling_governor
echo 0 > /sys/class/devfreq/gpu/min_freq
