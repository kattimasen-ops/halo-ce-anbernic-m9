#!/bin/bash
# Halo: Combat Evolved – angepasst für M9 Pro (RK3326, ArkOS 4)
#
# Liegt in /roms/ports, Spiel in halo-ce daneben.
# Log: halo-ce/log.txt, Einstellungen: halo-ce/config.toml.
#
# SDL-Controller-Mapping für "GO-Super Gamepad" ist fest eingebaut
# (aus der Input-Diagnose vom 02.10.2026).
# Diagnose wiederholen: save/.diag-done löschen.

log() {
    if [ -n "$LOG_OPEN" ]; then
        printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
    else
        printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
    fi
}
log_raw() { if [ -n "$LOG_OPEN" ]; then cat; else cat >&2; fi; }
log_section() {
    log ""
    log "========================================================="
    log "== $*"
    log "========================================================="
}

LOG_OPEN=""
echo "Halo.sh gestartet: $(date), USER=$(id -un), PID=$$" > /tmp/halo-start.log 2>&1 || true

SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
[ -n "$SCRIPT_DIR" ] || { echo "FEHLER: Skript-Verzeichnis nicht ermittelbar" >> /tmp/halo-start.log; exit 1; }
GAMEDIR="$SCRIPT_DIR/halo-ce"
[ -d "$GAMEDIR" ] || { echo "FEHLER: $GAMEDIR fehlt" >> /tmp/halo-start.log; exit 1; }

LOG="$GAMEDIR/log.txt"
if ! touch "$LOG" 2>/dev/null; then
    LOG="/tmp/halo-log.txt"
    touch "$LOG" 2>/dev/null || LOG="/dev/null"
fi

exec >> "$LOG" 2>&1
LOG_OPEN=1

log_section "START"
log "SCRIPT_DIR=$SCRIPT_DIR"
log "GAMEDIR=$GAMEDIR"
log "USER=$(id -un), UID=$(id -u)"
log "Kernel: $(uname -r), Arch: $(uname -m)"
log "Datum: $(date)"

cd "$GAMEDIR" || { log "FEHLER: cd fehlgeschlagen"; exit 1; }

exec 9> /tmp/halo-lock 2>/dev/null || log "WARNUNG: /tmp/halo-lock nicht beschreibbar."
if [ -e /proc/self/fd/9 ]; then
    if ! { flock -n 9 || python3 -c 'import fcntl; fcntl.flock(9, fcntl.LOCK_EX | fcntl.LOCK_NB)' 2>/dev/null; } 2>/dev/null; then
        log "Halo läuft bereits; Start abgelehnt"
        exit 1
    fi
fi

trap 'log "Signal empfangen: exit 143"; exit 143' TERM INT HUP

stop() {
    log "stop() aufgerufen"
    stopping=1
    [ -n "$child" ] || return 0
    kill -TERM "$child" 2>/dev/null
    [ -n "$watchdog" ] || { (exec 9>&-; sleep 10; kill -KILL "$child" 2>/dev/null) & watchdog=$!; }
}
supervised() {
    local status child="" watchdog="" stopping=""
    trap stop TERM INT HUP
    log "supervised: starte $*"
    "$@" &
    child=$!
    [ -z "$stopping" ] || stop
    while :; do
        wait "$child"
        status=$?
        kill -0 "$child" 2>/dev/null || break
    done
    trap 'exit 143' TERM INT HUP
    [ -z "$watchdog" ] || kill "$watchdog" 2>/dev/null
    if [ -n "$stopping" ]; then log "gestoppt (exit $status)"; exit 143; fi
    log "supervised: $* beendet mit status $status"
    return "$status"
}

log_section "SYSTEMOPTIMIERUNGEN"

cpu_governor_path=""
for candidate in \
    /sys/devices/system/cpu/cpufreq/policy0/scaling_governor \
    /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor; do
    [ -w "$candidate" ] && { cpu_governor_path="$candidate"; break; }
done
cpu_saved=""
if [ -n "$cpu_governor_path" ]; then
    cpu_saved=$(cat "$cpu_governor_path" 2>/dev/null)
    log "CPU-Governor: $cpu_governor_path $cpu_saved -> performance"
    echo performance > "$cpu_governor_path" 2>/dev/null
fi
for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
    [ -w "$cpu/cpufreq/scaling_governor" ] && echo performance > "$cpu/cpufreq/scaling_governor" 2>/dev/null
done

gpu_devfreq_path=""
for candidate in /sys/class/devfreq/ff400000.gpu /sys/class/devfreq/gpu; do
    [ -d "$candidate" ] && { gpu_devfreq_path="$candidate"; break; }
done
gpu_governor_saved=""
gpu_min_saved=""
if [ -n "$gpu_devfreq_path" ]; then
    [ -r "$gpu_devfreq_path/governor" ] && gpu_governor_saved=$(cat "$gpu_devfreq_path/governor" 2>/dev/null)
    log "GPU-Governor: $gpu_devfreq_path $gpu_governor_saved -> performance"
    [ -w "$gpu_devfreq_path/governor" ] && echo performance > "$gpu_devfreq_path/governor" 2>/dev/null
    if [ -r "$gpu_devfreq_path/available_frequencies" ] && [ -w "$gpu_devfreq_path/min_freq" ]; then
        gpu_min_saved=$(cat "$gpu_devfreq_path/min_freq" 2>/dev/null)
        max_freq=$(tr ' ' '\n' < "$gpu_devfreq_path/available_frequencies" | sort -n | tail -n 1)
        [ -n "$max_freq" ] && echo "$max_freq" > "$gpu_devfreq_path/min_freq" 2>/dev/null
    fi
fi

if swapon --show 2>/dev/null | grep -q zram; then
    log "ZRAM bereits aktiv."
else
    modprobe zram 2>/dev/null
    if [ -e /dev/zram0 ]; then
        echo 512M > /sys/block/zram0/disksize 2>/dev/null
        mkswap /dev/zram0 >/dev/null 2>&1
        swapon /dev/zram0 2>/dev/null
        log "ZRAM aktiviert."
    fi
fi

saved=/tmp/halo-clocks
printf '%s|%s|%s\n' "$cpu_saved" "$gpu_governor_saved" "$gpu_min_saved" > "$saved" 2>/dev/null || true

restore() {
    log_section "RESTORE"
    if [ -f "$saved" ]; then
        IFS='|' read -r cpu_gov gpu_gov gpu_min < "$saved"
        [ -n "$cpu_gov" ] && [ -n "$cpu_governor_path" ] && [ -w "$cpu_governor_path" ] && echo "$cpu_gov" > "$cpu_governor_path" 2>/dev/null
        if [ -n "$gpu_devfreq_path" ]; then
            [ -n "$gpu_gov" ] && [ -w "$gpu_devfreq_path/governor" ] && echo "$gpu_gov" > "$gpu_devfreq_path/governor" 2>/dev/null
            [ -n "$gpu_min" ] && [ -w "$gpu_devfreq_path/min_freq" ] && echo "$gpu_min" > "$gpu_devfreq_path/min_freq" 2>/dev/null
        fi
        rm -f "$saved"
    fi
    rm -f /var/run/battery-saver/halo.pause 2>/dev/null
    log "Restore abgeschlossen."
}
trap restore EXIT

mkdir -p /var/run/battery-saver 2>/dev/null && touch /var/run/battery-saver/halo.pause 2>/dev/null
log "Battery-Saver-Pause gesetzt."

log_section "SAVE DIRECTORIES"
mkdir -p save save/z save/saved save/saved/player_profiles save/saved/player_profiles/default_profile \
         save/saved/playlists save/saved/playlists/default_playlist \
         save/saved/recordings save/saved/recordings/last_recording 2>/dev/null
if touch save/saved/.write_test 2>/dev/null; then
    log "save/saved/ ist beschreibbar."
    rm -f save/saved/.write_test
else
    log "WARNUNG: save/saved/ ist NICHT beschreibbar!"
fi

log_section "RUNTIME-BIBLIOTHEKEN"
LIBS_DIR="$GAMEDIR/libs.aarch64"
if [ -d "$LIBS_DIR" ]; then
    export LD_LIBRARY_PATH="$LIBS_DIR:$GAMEDIR:$LD_LIBRARY_PATH"
    log "LIBS_DIR=$LIBS_DIR"
else
    export LD_LIBRARY_PATH="$GAMEDIR:$LD_LIBRARY_PATH"
fi
log "LD_LIBRARY_PATH=$LD_LIBRARY_PATH"

if command -v ldd >/dev/null 2>&1; then
    log "ldd-Prüfung (nur 'not found'):"
    ldd ./halo 2>/dev/null | grep 'not found' | log_raw || log "   (alle Bibliotheken gefunden)"
fi

log_section "MAPS"
if [ ! -s maps/ui.map ]; then
    shopt -s nullglob
    images=({.,..}/*.{iso,ISO,xiso,XISO})
    shopt -u nullglob
    [ "${#images[@]}" -gt 0 ] || { log "FEHLER: Keine maps/ und kein ISO"; exit 1; }
    log "Kopiere maps/ aus ${images[0]}..."
    ( sleep 600; kill -KILL $$ ) &
    supervised python3 halo_extract.py --screen "${images[0]}" "$GAMEDIR"
    extract_status=$?
    kill %1 2>/dev/null
    [ "$extract_status" -eq 0 ] || { log "FEHLER: halo_extract status $extract_status"; exit 1; }
else
    log "maps/ ist vorhanden."
fi

log_section "CONFIG"
if [ ! -f config.toml ]; then
    log "Erstelle config.toml..."
    cat > config.toml <<'EOF'
[display]
screen_width = 640
render_scale = 0.75
interpolation = true
fast_shaders = true
fast_textures = true
high_res_hud = true
model_detail = 0.7
frame_pacing = true
[update]
auto = false
[network]
online = false
[debug]
sort_models = false
stable_streams = false
batch_quads = true
alpha_test_elision = true
EOF
    log "config.toml erstellt."
else
    log "config.toml existiert bereits."
fi

log_section "CONTROLLER-MAPPING"
# Fest eingebaut, basiert auf der Input-Diagnose vom 02.10.2026:
#   A=BTN_SOUTH(304), B=BTN_EAST(305), X=BTN_NORTH(307), Y=BTN_WEST(308)
#   L1=BTN_TL(310), R1=BTN_TR(311), L2=BTN_TL2(312), R2=BTN_TR2(313)
#   D-Pad=BTN_DPAD_UP/DOWN/LEFT/RIGHT(544-547)
#   Linker Stick=ABS_X(0)/ABS_Y(1), rechter Stick=ABS_RX(3)/ABS_RY(4)
export SDL_GAMECONTROLLERCONFIG="19004b48001100010000000000000000,GO-Super Gamepad,a:b0,b:b1,x:b2,y:b3,leftshoulder:b4,rightshoulder:b5,lefttrigger:b6,righttrigger:b7,dpup:b8,dpdown:b9,dpleft:b10,dpright:b11,leftx:a0,lefty:a1,rightx:a3,righty:a4,platform:Linux,"
log "SDL_GAMECONTROLLERCONFIG gesetzt: ${#SDL_GAMECONTROLLERCONFIG} Zeichen"

log_section "SPIELSTART"
log "Starte ./halo ..."
if [ ! -x ./halo ]; then
    log "FEHLER: ./halo fehlt oder nicht ausführbar."
    ls -la ./halo 2>/dev/null | log_raw
    exit 1
fi

supervised ./halo
status=$?
log "halo beendet mit status $status"

log_section "ENDE"
exit $status
