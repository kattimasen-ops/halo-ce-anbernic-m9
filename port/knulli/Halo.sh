#!/bin/bash
# Halo: Combat Evolved, the native port of the decompilation, for Knulli
# handhelds with the Allwinner H700 (Anbernic RG35XX H and its family).
# Refer to port/knulli/README.md.
#
# This script goes in /roms/ports, the game in the halo-ce folder beside
# it. Put an Xbox disc image of the game (.iso) in that folder, or in ports
# itself: the first start copies its maps folder out (a few minutes, with
# its progress on the screen), then the image can be deleted. The log of
# each start is halo-ce/log.txt; the settings are halo-ce/config.toml.
#
# Hold the hotkey (MENU or SELECT) and push START to quit.

# ── FRÜHESTE FEHLERERKENNUNG ────────────────────────────────────────────
echo "Halo.sh gestartet: $(date), USER=$(id -un), PID=$$" > /tmp/halo-start.log 2>&1 || true

SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
if [ -z "$SCRIPT_DIR" ]; then
    echo "FEHLER: Skript-Verzeichnis konnte nicht ermittelt werden." >> /tmp/halo-start.log
    exit 1
fi
GAMEDIR="$SCRIPT_DIR/halo-ce"
echo "SCRIPT_DIR=$SCRIPT_DIR" >> /tmp/halo-start.log
echo "GAMEDIR=$GAMEDIR" >> /tmp/halo-start.log

if [ ! -d "$GAMEDIR" ]; then
    echo "FEHLER: $GAMEDIR existiert nicht." >> /tmp/halo-start.log
    exit 1
fi

LOG="$GAMEDIR/log.txt"
if ! touch "$LOG" 2>/dev/null; then
    LOG="/tmp/halo-log.txt"
    touch "$LOG" 2>/dev/null || LOG="/dev/null"
fi

exec >> "$LOG" 2>&1

echo ""
echo "=================================================================="
echo "Halo for R36S, $(date)"
echo "SCRIPT_DIR=$SCRIPT_DIR"
echo "GAMEDIR=$GAMEDIR"
echo "LOG=$LOG"
echo "USER=$(id -un), UID=$(id -u)"
echo "Kernel: $(uname -r)"
echo "Arch: $(uname -m)"
echo "Shell: $BASH_VERSION"
echo "=================================================================="

cd "$GAMEDIR" || { echo "FEHLER: cd $GAMEDIR fehlgeschlagen"; exit 1; }

exec 9> /tmp/halo-lock 2>/dev/null || echo "WARNUNG: /tmp/halo-lock nicht beschreibbar."
if [ -e /proc/self/fd/9 ]; then
    if ! { flock -n 9 || python3 -c 'import fcntl; fcntl.flock(9, fcntl.LOCK_EX | fcntl.LOCK_NB)' 2>/dev/null; } 2>/dev/null; then
        echo "$(date): Halo läuft bereits; Start abgelehnt"
        exit 1
    fi
fi

trap 'echo "Signal empfangen: exit 143"; exit 143' TERM INT HUP

stop() {
    echo "stop() aufgerufen"
    stopping=1
    [ -n "$child" ] || return 0
    kill -TERM "$child" 2>/dev/null
    [ -n "$watchdog" ] || { (exec 9>&-; sleep 10; kill -KILL "$child" 2>/dev/null) & watchdog=$!; }
}
supervised() {
    local status child="" watchdog="" stopping=""
    trap stop TERM INT HUP
    echo "supervised: starte $*"
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
    if [ -n "$stopping" ]; then
        echo "gestoppt (exit status $status)"
        exit 143
    fi
    echo "supervised: $* beendet mit status $status"
    return "$status"
}

echo ""
echo "── SYSTEMOPTIMIERUNGEN ──────────────────────────────────────────"

cpu_governor_path=""
for candidate in \
    /sys/devices/system/cpu/cpufreq/policy0/scaling_governor \
    /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor; do
    if [ -w "$candidate" ]; then
        cpu_governor_path="$candidate"
        break
    fi
done

cpu_saved=""
if [ -n "$cpu_governor_path" ]; then
    cpu_saved=$(cat "$cpu_governor_path" 2>/dev/null)
    echo "CPU-Governor: $cpu_governor_path  $cpu_saved -> performance"
    echo performance > "$cpu_governor_path" 2>/dev/null
fi

for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
    [ -w "$cpu/cpufreq/scaling_governor" ] && echo performance > "$cpu/cpufreq/scaling_governor" 2>/dev/null
done

gpu_devfreq_path=""
for candidate in /sys/class/devfreq/ff400000.gpu /sys/class/devfreq/gpu; do
    if [ -d "$candidate" ]; then
        gpu_devfreq_path="$candidate"
        break
    fi
done

gpu_governor_saved=""
gpu_min_saved=""
if [ -n "$gpu_devfreq_path" ]; then
    [ -r "$gpu_devfreq_path/governor" ] && gpu_governor_saved=$(cat "$gpu_devfreq_path/governor" 2>/dev/null)
    echo "GPU-Governor: $gpu_devfreq_path  $gpu_governor_saved -> performance"
    [ -w "$gpu_devfreq_path/governor" ] && echo performance > "$gpu_devfreq_path/governor" 2>/dev/null
    if [ -r "$gpu_devfreq_path/available_frequencies" ] && [ -w "$gpu_devfreq_path/min_freq" ]; then
        gpu_min_saved=$(cat "$gpu_devfreq_path/min_freq" 2>/dev/null)
        max_freq=$(tr ' ' '\n' < "$gpu_devfreq_path/available_frequencies" | sort -n | tail -n 1)
        [ -n "$max_freq" ] && echo "$max_freq" > "$gpu_devfreq_path/min_freq" 2>/dev/null
    fi
fi

if swapon --show 2>/dev/null | grep -q zram; then
    echo "ZRAM bereits aktiv."
else
    modprobe zram 2>/dev/null
    if [ -e /dev/zram0 ]; then
        echo 512M > /sys/block/zram0/disksize 2>/dev/null
        mkswap /dev/zram0 >/dev/null 2>&1
        swapon /dev/zram0 2>/dev/null
        echo "ZRAM aktiviert."
    fi
fi

saved=/tmp/halo-clocks
printf '%s|%s|%s\n' "$cpu_saved" "$gpu_governor_saved" "$gpu_min_saved" > "$saved" 2>/dev/null || true

restore() {
    echo ""
    echo "── RESTORE ─────────────────────────────────────────────────────"
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
    echo "Restore abgeschlossen."
}
trap restore EXIT

mkdir -p /var/run/battery-saver 2>/dev/null && touch /var/run/battery-saver/halo.pause 2>/dev/null
echo "Battery-Saver-Pause gesetzt (falls möglich)."

# ── LAUFZEIT-BIBLIOTHEKEN DES PORTS ──────────────────────────────────────
LIBS_DIR="$GAMEDIR/libs.aarch64"
if [ -d "$LIBS_DIR" ]; then
    export LD_LIBRARY_PATH="$LIBS_DIR:$GAMEDIR:$LD_LIBRARY_PATH"
    echo "LIBS_DIR=$LIBS_DIR"
else
    echo "WARNUNG: $LIBS_DIR existiert nicht."
    export LD_LIBRARY_PATH="$GAMEDIR:$LD_LIBRARY_PATH"
fi
echo "LD_LIBRARY_PATH=$LD_LIBRARY_PATH"

if command -v ldd >/dev/null 2>&1; then
    echo "== ldd-Prüfung (nur 'not found'-Zeilen):"
    ldd ./halo 2>/dev/null | grep 'not found' || echo "   (alle Bibliotheken gefunden)"
fi

echo ""
echo "── MAPS ────────────────────────────────────────────────────────"
if [ ! -s maps/ui.map ]; then
    shopt -s nullglob
    images=({.,..}/*.{iso,ISO,xiso,XISO})
    shopt -u nullglob
    if [ "${#images[@]}" -eq 0 ]; then
        echo "FEHLER: Keine maps/ und kein Disc-Image in $GAMEDIR."
        supervised python3 halo_screen.py wait 60 "Halo needs your disc" \
            "Copy the disc image of Halo: Combat Evolved for the Xbox (an .iso file) into roms/ports/halo-ce on the SD card, then start Halo again. Press a button to go back."
        exit 1
    fi
    [ "${#images[@]}" -eq 1 ] || echo "${#images[@]} Disc-Images: das erste wird verwendet."
    echo "Kopiere maps/ aus ${images[0]}..."
    supervised python3 halo_extract.py --screen "${images[0]}" "$GAMEDIR" || exit 1
else
    echo "maps/ ist vorhanden."
fi

echo ""
echo "── CONFIG ──────────────────────────────────────────────────────"
if [ ! -f config.toml ]; then
    echo "Erstelle config.toml mit RK3326-Defaults..."
    if [ -e config.toml ] || [ -L config.toml ] || ! cat > config.toml.new <<'EOF' || ! mv -f config.toml.new config.toml; then
[display]
screen_width = 640
render_scale = 0.5
interpolation = true
fast_shaders = true
fast_textures = true
high_res_hud = false
model_detail = 0.4
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
        rm -f config.toml.new
        echo "FEHLER: config.toml konnte nicht geschrieben werden."
        supervised python3 halo_screen.py wait 60 "Halo could not start" \
            "Halo could not write its settings. Press a button to go back."
        exit 1
    fi
    echo "config.toml erstellt."
else
    echo "config.toml existiert bereits."
fi

echo ""
echo "── CONTROLLER ──────────────────────────────────────────────────"
if [ -f sdl_mapping.py ]; then
    SDL_GAMECONTROLLERCONFIG="$(python3 sdl_mapping.py 2>/dev/null)"
    export SDL_GAMECONTROLLERCONFIG
    echo "SDL_GAMECONTROLLERCONFIG: ${#SDL_GAMECONTROLLERCONFIG} Zeichen"
    [ -z "$SDL_GAMECONTROLLERCONFIG" ] && echo "   (leer – SDL3 nutzt seine eigene Gamepad-DB)"
fi

echo ""
echo "── SPIELSTART ──────────────────────────────────────────────────"
if [ ! -d save/z ]; then
    echo "Erster Start: Shader-Cache wird erstellt..."
    if [ -f halo_screen.py ]; then
        supervised python3 halo_screen.py wait 10 "Starting Halo" \
            "The first start takes about a minute more, with a black screen, while the game sets up its shader cache. Press a button to continue."
    fi
fi

echo "Starte ./halo ..."
if [ ! -x ./halo ]; then
    echo "FEHLER: ./halo fehlt oder ist nicht ausführbar."
    ls -la ./halo 2>/dev/null
    exit 1
fi

supervised ./halo
status=$?
echo "halo beendet mit status $status"
exit $status
