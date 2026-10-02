#!/bin/bash
# Halo: Combat Evolved – angepasst für M9 Pro (RK3326, ArkOS 4)
#
# Liegt in /roms/ports, Spiel in halo-ce daneben.
# Log: halo-ce/log.txt, Einstellungen: halo-ce/config.toml.
#
# Beim ersten Start (Marker save/.diag-done fehlt) läuft eine
# 40-Sekunden-Eingabe-Diagnose: alle Tasten drücken, beide Sticks
# bewegen. Das Ergebnis landet im Log.
# Diagnose wiederholen: einfach save/.diag-done löschen.

log() {
    if [ -n "$LOG_OPEN" ]; then
        printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
    else
        printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
    fi
}
log_raw() {
    if [ -n "$LOG_OPEN" ]; then cat; else cat >&2; fi
}
log_section() {
    log ""
    log "========================================================="
    log "== $*"
    log "========================================================="
}

LOG_OPEN=""
echo "Halo.sh gestartet: $(date), USER=$(id -un), PID=$$" > /tmp/halo-start.log 2>&1 || true

SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
if [ -z "$SCRIPT_DIR" ]; then
    echo "FEHLER: Skript-Verzeichnis konnte nicht ermittelt werden." >> /tmp/halo-start.log
    exit 1
fi
GAMEDIR="$SCRIPT_DIR/halo-ce"

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
LOG_OPEN=1

log_section "START"
log "SCRIPT_DIR=$SCRIPT_DIR"
log "GAMEDIR=$GAMEDIR"
log "USER=$(id -un), UID=$(id -u)"
log "Kernel: $(uname -r), Arch: $(uname -m)"
log "Shell: $BASH_VERSION"
log "Datum: $(date)"

cd "$GAMEDIR" || { log "FEHLER: cd $GAMEDIR fehlgeschlagen"; exit 1; }

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
    if [ -n "$stopping" ]; then
        log "gestoppt (exit status $status)"
        exit 143
    fi
    log "supervised: $* beendet mit status $status"
    return "$status"
}

log_section "SYSTEMOPTIMIERUNGEN"

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
    log "CPU-Governor: $cpu_governor_path  $cpu_saved -> performance"
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
    log "GPU-Governor: $gpu_devfreq_path  $gpu_governor_saved -> performance"
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
log "Battery-Saver-Pause gesetzt (falls möglich)."

# ── Save-Verzeichnisse anlegen (behebt z:\saved-Fehler) ────────────────
log_section "SAVE DIRECTORIES"
mkdir -p save 2>/dev/null
mkdir -p save/z 2>/dev/null
mkdir -p save/saved 2>/dev/null
mkdir -p save/saved/player_profiles 2>/dev/null
mkdir -p save/saved/player_profiles/default_profile 2>/dev/null
mkdir -p save/saved/playlists 2>/dev/null
mkdir -p save/saved/playlists/default_playlist 2>/dev/null
mkdir -p save/saved/recordings 2>/dev/null
mkdir -p save/saved/recordings/last_recording 2>/dev/null

if touch save/saved/.write_test 2>/dev/null; then
    log "save/saved/ ist beschreibbar."
    rm -f save/saved/.write_test
else
    log "WARNUNG: save/saved/ ist NICHT beschreibbar!"
fi

log "Struktur:"
ls -la save/ save/saved/ 2>/dev/null | log_raw

# ── Runtime-Bibliotheken ───────────────────────────────────────────────
log_section "RUNTIME-BIBLIOTHEKEN"
LIBS_DIR="$GAMEDIR/libs.aarch64"
if [ -d "$LIBS_DIR" ]; then
    export LD_LIBRARY_PATH="$LIBS_DIR:$GAMEDIR:$LD_LIBRARY_PATH"
    log "LIBS_DIR=$LIBS_DIR"
else
    log "WARNUNG: $LIBS_DIR existiert nicht."
    export LD_LIBRARY_PATH="$GAMEDIR:$LD_LIBRARY_PATH"
fi
log "LD_LIBRARY_PATH=$LD_LIBRARY_PATH"

log "Inhalt von libs.aarch64:"
ls -la "$LIBS_DIR" 2>/dev/null | log_raw

if command -v ldd >/dev/null 2>&1; then
    log "ldd-Prüfung (nur 'not found'-Zeilen):"
    ldd ./halo 2>/dev/null | grep 'not found' | log_raw || log "   (alle Bibliotheken gefunden)"
fi

# ── Maps prüfen ────────────────────────────────────────────────────────
log_section "MAPS"
if [ ! -s maps/ui.map ]; then
    shopt -s nullglob
    images=({.,..}/*.{iso,ISO,xiso,XISO})
    shopt -u nullglob
    if [ "${#images[@]}" -eq 0 ]; then
        log "FEHLER: Keine maps/ und kein Disc-Image in $GAMEDIR."
        exit 1
    fi
    [ "${#images[@]}" -eq 1 ] || log "${#images[@]} Disc-Images: das erste wird verwendet."
    log "Kopiere maps/ aus ${images[0]}..."
    ( sleep 600; kill -KILL $$ ) &
    supervised python3 halo_extract.py --screen "${images[0]}" "$GAMEDIR"
    extract_status=$?
    kill %1 2>/dev/null
    if [ "$extract_status" -ne 0 ]; then
        log "FEHLER: halo_extract.py beendet mit status $extract_status"
        exit 1
    fi
else
    log "maps/ ist vorhanden."
fi

# ── config.toml ────────────────────────────────────────────────────────
log_section "CONFIG"
if [ ! -f config.toml ]; then
    log "Erstelle config.toml..."
    if [ -e config.toml ] || [ -L config.toml ] || ! cat > config.toml.new <<'EOF' || ! mv -f config.toml.new config.toml; then
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
        rm -f config.toml.new
        log "FEHLER: config.toml konnte nicht geschrieben werden."
        exit 1
    fi
    log "config.toml erstellt."
else
    log "config.toml existiert bereits."
fi
log "Inhalt von config.toml:"
cat config.toml 2>/dev/null | log_raw

# ── Controller-Mapping (nur Info) ──────────────────────────────────────
log_section "CONTROLLER-MAPPING"
if [ -f sdl_mapping.py ]; then
    log "sdl_mapping.py Rohausgabe:"
    python3 sdl_mapping.py 2>&1 | log_raw
    SDL_GAMECONTROLLERCONFIG="$(python3 sdl_mapping.py 2>/dev/null)"
    export SDL_GAMECONTROLLERCONFIG
    log "SDL_GAMECONTROLLERCONFIG-Länge: ${#SDL_GAMECONTROLLERCONFIG} Zeichen"
    log "Inhalt:"
    printf '%s\n' "$SDL_GAMECONTROLLERCONFIG" | log_raw
else
    log "sdl_mapping.py nicht vorhanden."
fi

# ── INPUT-DIAGNOSE (läuft, wenn Marker fehlt) ──────────────────────────
if [ ! -f save/.diag-done ]; then
    log_section "INPUT-DIAGNOSE"
    log "Erster Start mit neuer Skriptversion. 40-Sekunden-Aufzeichnung."
    log "Bitte jetzt jede Taste drücken und beide Sticks bewegen."

    if [ -f "$SCRIPT_DIR/halo_controls.py" ]; then
        # Kein halo_screen.py mehr davor – der Bildschirm bleibt schwarz,
        # damit nichts die Diagnose blockiert.
        ( sleep 45; kill -KILL $(cat /tmp/halo-diag.pid 2>/dev/null) 2>/dev/null ) &
        WATCHDOG=$!
        python3 "$SCRIPT_DIR/halo_controls.py" 40 > /tmp/halo-diag.out 2>&1 &
        DIAG_PID=$!
        echo "$DIAG_PID" > /tmp/halo-diag.pid
        wait "$DIAG_PID" 2>/dev/null
        DIAG_STATUS=$?
        kill "$WATCHDOG" 2>/dev/null

        log "Diagnose beendet mit Status $DIAG_STATUS"
        log "Diagnose-Ausgabe:"
        cat /tmp/halo-diag.out 2>/dev/null | log_raw

        touch save/.diag-done 2>/dev/null
        log "Marker save/.diag-done angelegt."
    else
        log "halo_controls.py nicht gefunden – Diagnose übersprungen."
    fi
else
    log_section "INPUT-DIAGNOSE"
    log "Bereits durchgeführt (save/.diag-done vorhanden)."
    log "Wiederholen: Datei save/.diag-done löschen."
fi

# ── Spielstart ─────────────────────────────────────────────────────────
log_section "SPIELSTART"
log "Starte ./halo ..."
if [ ! -x ./halo ]; then
    log "FEHLER: ./halo fehlt oder ist nicht ausführbar."
    ls -la ./halo 2>/dev/null | log_raw
    exit 1
fi

supervised ./halo
status=$?
log "halo beendet mit status $status"

log_section "ENDE"
exit $status
