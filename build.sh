#!/bin/bash
# Halo: Combat Evolved – M9 Pro (RK3326 / Cortex-A35 + Mali-G31 MP2)
#
# PGO-Trainings-Modus:
#   LLVM_PROFILE_FILE wird gesetzt, das Spiel wird nach 10 Minuten per
#   SIGTERM beendet (sauberes Schreiben der .profraw), danach sync().

XDG_DATA_HOME=${XDG_DATA_HOME:-$HOME/.local/share}

# ── PFADE ────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
if [ -z "$SCRIPT_DIR" ]; then
    echo "FEHLER: Skript-Verzeichnis nicht ermittelbar." >&2
    exit 1
fi
GAMEDIR="$SCRIPT_DIR/halo-ce"
if [ ! -d "$GAMEDIR" ]; then
    echo "FEHLER: $GAMEDIR existiert nicht." >&2
    exit 1
fi
cd "$GAMEDIR" || exit 1

# ── SCHALTER ─────────────────────────────────────────────────────────
TRAINING_FLAG="${TRAINING:-1}"      # 1 = Trainingslauf, 0 = Spielen
HALO_DEBUG_LOGS="${HALO_DEBUG_LOGS:-1}"
HALO_EXIT_SECONDS="${HALO_EXIT_AFTER:-600}"

# ── LOGGING ──────────────────────────────────────────────────────────
if [ "$HALO_DEBUG_LOGS" = "1" ]; then
    LOG="$GAMEDIR/log.txt"
    if ! touch "$LOG" 2>/dev/null; then
        LOG="/tmp/halo-log.txt"
        touch "$LOG" 2>/dev/null || LOG="/dev/null"
    fi
    exec >> "$LOG" 2>&1
    LOG_OPEN=1
else
    LOG="/dev/null"
    exec >> "$LOG" 2>&1
    LOG_OPEN=""
fi

log() { [ -n "$LOG_OPEN" ] && printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
log_section() {
    if [ -n "$LOG_OPEN" ]; then
        log ""
        log "========================================================="
        log "== $*"
        log "========================================================="
    fi
}

log_section "START"
log "SCRIPT_DIR=$SCRIPT_DIR"
log "GAMEDIR=$GAMEDIR"
log "Kernel=$(uname -r), Arch=$(uname -m)"
log "Datum=$(date)"
log "TRAINING=$TRAINING_FLAG, HALO_DEBUG_LOGS=$HALO_DEBUG_LOGS, EXIT=$HALO_EXIT_SECONDS"

# ── LOCK ─────────────────────────────────────────────────────────────
exec 9> /tmp/halo-lock 2>/dev/null || true
if [ -e /proc/self/fd/9 ]; then
    if ! { flock -n 9 || python3 -c 'import fcntl; fcntl.flock(9, fcntl.LOCK_EX | fcntl.LOCK_NB)' 2>/dev/null; } 2>/dev/null; then
        log "Halo laeuft bereits"
        exit 1
    fi
fi

# ── PORTMASTER-CONTROLS ──────────────────────────────────────────────
PM_CONTROLFOLDER=""
for candidate in \
    "/opt/system/Tools/PortMaster" \
    "/opt/tools/PortMaster" \
    "$XDG_DATA_HOME/PortMaster" \
    "/roms/ports/PortMaster"; do
    if [ -d "$candidate" ]; then
        PM_CONTROLFOLDER="$candidate"
        break
    fi
done

if [ -n "$PM_CONTROLFOLDER" ] && [ -f "$PM_CONTROLFOLDER/control.txt" ]; then
    # shellcheck source=/dev/null
    source "$PM_CONTROLFOLDER/control.txt" 2>/dev/null || true
    if [ -n "${CFW_NAME:-}" ] && [ -f "$PM_CONTROLFOLDER/mod_${CFW_NAME}.txt" ]; then
        # shellcheck source=/dev/null
        source "$PM_CONTROLFOLDER/mod_${CFW_NAME}.txt" 2>/dev/null || true
    fi
    if command -v get_controls >/dev/null 2>&1; then
        get_controls 2>/dev/null || true
    fi
fi

if [ -n "${sdl_controllerconfig:-}" ]; then
    export SDL_GAMECONTROLLERCONFIG="$sdl_controllerconfig"
    log "SDL_GAMECONTROLLERCONFIG aus PortMaster gesetzt."
elif [ -f "$GAMEDIR/sdl_mapping.py" ]; then
    SDL_MAP="$(cd "$GAMEDIR" && python3 sdl_mapping.py 2>/dev/null)"
    if [ -n "$SDL_MAP" ]; then
        export SDL_GAMECONTROLLERCONFIG="$SDL_MAP"
        log "SDL_GAMECONTROLLERCONFIG aus sdl_mapping.py gesetzt."
    fi
fi

# ── SYSTEMOPTIMIERUNG ────────────────────────────────────────────────
log_section "SYSTEMOPTIMIERUNG"

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
    log "CPU-Governor: $cpu_saved -> performance"
    echo performance > "$cpu_governor_path" 2>/dev/null || true
fi
for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
    [ -w "$cpu/cpufreq/scaling_governor" ] && \
        echo performance > "$cpu/cpufreq/scaling_governor" 2>/dev/null || true
done

gpu_devfreq_path=""
for candidate in /sys/class/devfreq/ff400000.gpu /sys/class/devfreq/gpu; do
    if [ -d "$candidate" ]; then
        gpu_devfreq_path="$candidate"
        break
    fi
done
gpu_governor_saved=""; gpu_min_saved=""
if [ -n "$gpu_devfreq_path" ]; then
    [ -r "$gpu_devfreq_path/governor" ] && gpu_governor_saved=$(cat "$gpu_devfreq_path/governor" 2>/dev/null)
    log "GPU-Governor: $gpu_governor_saved -> performance"
    [ -w "$gpu_devfreq_path/governor" ] && \
        echo performance > "$gpu_devfreq_path/governor" 2>/dev/null || true
    if [ -r "$gpu_devfreq_path/available_frequencies" ] && [ -w "$gpu_devfreq_path/min_freq" ]; then
        gpu_min_saved=$(cat "$gpu_devfreq_path/min_freq" 2>/dev/null)
        max_freq=$(tr ' ' '\n' < "$gpu_devfreq_path/available_frequencies" | sort -n | tail -n 1)
        [ -n "$max_freq" ] && echo "$max_freq" > "$gpu_devfreq_path/min_freq" 2>/dev/null || true
    fi
fi

if swapon --show 2>/dev/null | grep -q zram; then
    log "ZRAM bereits aktiv."
else
    modprobe zram 2>/dev/null || true
    if [ -e /dev/zram0 ]; then
        echo 512M > /sys/block/zram0/disksize 2>/dev/null || true
        mkswap /dev/zram0 >/dev/null 2>&1 || true
        swapon /dev/zram0 2>/dev/null || true
        log "ZRAM aktiviert."
    fi
fi

HALO_SERVICE_STATE="/tmp/halo-ce-services.$$"
HALO_SERVICES_RESTORED=0

stop_service_if_active() {
    service="$1"
    if command -v systemctl >/dev/null 2>&1 && \
       systemctl is-active --quiet "$service" 2>/dev/null; then
        echo "$service" >> "$HALO_SERVICE_STATE" 2>/dev/null || true
        log "stopping $service"
        command -v sudo >/dev/null 2>&1 && sudo -n systemctl stop "$service" 2>/dev/null || true
    fi
}

restore_services() {
    [ "$HALO_SERVICES_RESTORED" = "0" ] || return 0
    HALO_SERVICES_RESTORED=1
    if [ -f "$HALO_SERVICE_STATE" ]; then
        while IFS= read -r service; do
            [ -n "$service" ] || continue
            log "restoring $service"
            command -v sudo >/dev/null 2>&1 && sudo -n systemctl start "$service" 2>/dev/null || true
        done < "$HALO_SERVICE_STATE"
        rm -f "$HALO_SERVICE_STATE" 2>/dev/null || true
    fi
}

: > "$HALO_SERVICE_STATE" 2>/dev/null || true
stop_service_if_active tailscaled.service

saved=/tmp/halo-clocks
printf '%s|%s|%s\n' "$cpu_saved" "$gpu_governor_saved" "$gpu_min_saved" > "$saved" 2>/dev/null || true

restore() {
    log_section "RESTORE"
    if [ -f "$saved" ]; then
        IFS='|' read -r cpu_gov gpu_gov gpu_min < "$saved"
        [ -n "$cpu_gov" ] && [ -n "$cpu_governor_path" ] && [ -w "$cpu_governor_path" ] && \
            echo "$cpu_gov" > "$cpu_governor_path" 2>/dev/null || true
        if [ -n "$gpu_devfreq_path" ]; then
            [ -n "$gpu_gov" ] && [ -w "$gpu_devfreq_path/governor" ] && \
                echo "$gpu_gov" > "$gpu_devfreq_path/governor" 2>/dev/null || true
            [ -n "$gpu_min" ] && [ -w "$gpu_devfreq_path/min_freq" ] && \
                echo "$gpu_min" > "$gpu_devfreq_path/min_freq" 2>/dev/null || true
        fi
        rm -f "$saved"
    fi
    restore_services
    rm -f /var/run/battery-saver/halo.pause 2>/dev/null || true
    log "Restore abgeschlossen."
}
trap restore EXIT

mkdir -p /var/run/battery-saver 2>/dev/null && \
    touch /var/run/battery-saver/halo.pause 2>/dev/null || true

# ── SAVE-VERZEICHNISSE ───────────────────────────────────────────────
mkdir -p "$GAMEDIR/save" \
         "$GAMEDIR/save/z" \
         "$GAMEDIR/save/saved" \
         "$GAMEDIR/save/saved/player_profiles" \
         "$GAMEDIR/save/saved/player_profiles/default_profile" \
         "$GAMEDIR/save/saved/playlists" \
         "$GAMEDIR/save/saved/playlists/default_playlist" \
         "$GAMEDIR/save/saved/recordings" \
         "$GAMEDIR/save/saved/recordings/last_recording" 2>/dev/null || true

# ── DRI-RECHTE ───────────────────────────────────────────────────────
for node in /dev/dri/card0 /dev/dri/renderD128 /dev/fb0; do
    if [ -e "$node" ] && { [ ! -r "$node" ] || [ ! -w "$node" ]; }; then
        sudo -n chmod 666 "$node" 2>/dev/null || true
    fi
done

# ── MALI-SYMLINKS ────────────────────────────────────────────────────
SYSTEM_MALI="/usr/local/lib/aarch64-linux-gnu/libmali-bifrost-g31-rxp0-gbm.so"
if [ -f "$SYSTEM_MALI" ]; then
    rm -rf /tmp/halo-mali
    mkdir -p /tmp/halo-mali
    for name in libmali.so.0 libmali.so.1 libmali.so libgbm.so.1 libgbm.so.1.0.0 libgbm.so; do
        ln -sf "$SYSTEM_MALI" "/tmp/halo-mali/$name"
    done
fi
export LD_LIBRARY_PATH="/tmp/halo-mali:$GAMEDIR/libs.aarch64:$GAMEDIR"

# ── ALSA (RK817) ─────────────────────────────────────────────────────
if command -v amixer >/dev/null 2>&1; then
    for ctrl in Playback Master PCM Speaker Headphone DAC; do
        amixer -c 0 sset "$ctrl" 100% unmute >/dev/null 2>&1 || true
    done
    amixer -c 0 cset numid=1 1 >/dev/null 2>&1 || true
fi
ASOUNDRC="$HOME/.asoundrc"
if [ ! -f "$ASOUNDRC" ]; then
    cat > "$ASOUNDRC" << 'ASOUNDEOF'
pcm.!default { type hw; card 0; device 0 }
ctl.!default { type hw; card 0 }
ASOUNDEOF
fi

# ── SDL-UMGEBUNG ─────────────────────────────────────────────────────
# WICHTIG: SDL_VIDEO_DOUBLE_BUFFER wird NICHT gesetzt. Auf dem Mali-KMSDRM-
# Treiber des RK3326 führt sie zu "Could not queue pageflip: -22" und einem
# schwarzen Bildschirm nach einigen Sekunden.
export SDL_VIDEODRIVER="${SDL_VIDEODRIVER:-kmsdrm}"
unset SDL_AUDIODRIVER
unset AUDIODEV

# ── HALO-PFADE ───────────────────────────────────────────────────────
log_section "HALO-PFADE"
export HALO_DATA_ROOT="$GAMEDIR"
export HALO_SAVE_ROOT="$GAMEDIR/save"
log "HALO_DATA_ROOT=$HALO_DATA_ROOT"
log "HALO_SAVE_ROOT=$HALO_SAVE_ROOT"

# ── HALO-EINSTELLUNGEN ───────────────────────────────────────────────
log_section "HALO-EINSTELLUNGEN"
export HALO_RENDER_SCALE="${HALO_RENDER_SCALE:-1.0}"
export HALO_DYNAMIC_RESOLUTION="${HALO_DYNAMIC_RESOLUTION:-1}"
export HALO_DYNAMIC_RESOLUTION_MIN="${HALO_DYNAMIC_RESOLUTION_MIN:-1.0}"
export HALO_MODEL_DETAIL="${HALO_MODEL_DETAIL:-0.35}"
export HALO_FAST_SHADERS="${HALO_FAST_SHADERS:-1}"
export HALO_FAST_TEXTURES="${HALO_FAST_TEXTURES:-1}"
export HALO_INTERPOLATION="${HALO_INTERPOLATION:-1}"
export HALO_NO_VSYNC="${HALO_NO_VSYNC:-0}"
export HALO_FRAME_PACING="${HALO_FRAME_PACING:-1}"
export HALO_HIGH_RES_HUD=0
export HALO_HIGH_RES_TEXT=0
export HALO_SORT_MODELS="${HALO_SORT_MODELS:-1}"
export HALO_INSTANCE_MODELS="${HALO_INSTANCE_MODELS:-1}"
export HALO_BATCH_QUADS="${HALO_BATCH_QUADS:-1}"
export HALO_ALPHA_TEST_ELISION="${HALO_ALPHA_TEST_ELISION:-1}"
export HALO_STABLE_STREAMS="${HALO_STABLE_STREAMS:-1}"
export HALO_GL_THREAD="${HALO_GL_THREAD:-1}"
export HALO_ASYNC_TEXTURES="${HALO_ASYNC_TEXTURES:-1}"
export HALO_ASYNC_SHADERS="${HALO_ASYNC_SHADERS:-1}"
export HALO_ASYNC_PROGRAMS="${HALO_ASYNC_PROGRAMS:-1}"
export HALO_PERF_LOG=1
export HALO_GPU_STATS=1
export HALO_MEMORY_STATS=1

log "render_scale=$HALO_RENDER_SCALE, model_detail=$HALO_MODEL_DETAIL"
log "dynamic_resolution=$HALO_DYNAMIC_RESOLUTION (min $HALO_DYNAMIC_RESOLUTION_MIN)"
log "fast_shaders=$HALO_FAST_SHADERS, fast_textures=$HALO_FAST_TEXTURES"
log "interpolation=$HALO_INTERPOLATION, frame_pacing=$HALO_FRAME_PACING"
log "high_res_hud=$HALO_HIGH_RES_HUD, high_res_text=$HALO_HIGH_RES_TEXT"

# ── PGO-TRAINING ─────────────────────────────────────────────────────
if [ "$TRAINING_FLAG" = "1" ]; then
    export LLVM_PROFILE_FILE="$GAMEDIR/halo-%p-%m.profraw"
    rm -f "$GAMEDIR"/halo-*.profraw 2>/dev/null || true

    log_section "PGO-TRAINING AKTIV"
    log "HALO_EXIT_AFTER=$HALO_EXIT_SECONDS s (SIGTERM nach Ablauf)"
    log "LLVM_PROFILE_FILE=$LLVM_PROFILE_FILE"
    log "Bitte mehrere Level spielen (a30, b30, c10)."

    echo ""
    echo "════════════════════════════════════════════════════════════"
    echo " PGO-Training läuft"
    echo " Das Spiel beendet sich nach $HALO_EXIT_SECONDS Sekunden selbst."
    echo " NICHT den Hotkey benutzen – das würde die .profraw abschneiden."
    echo "════════════════════════════════════════════════════════════"
fi

# ── MAPS-CHECK ───────────────────────────────────────────────────────
if [ ! -s "$GAMEDIR/maps/ui.map" ]; then
    log "FEHLER: $GAMEDIR/maps/ui.map fehlt."
    echo "FEHLER: maps/ui.map fehlt." >&2
    exit 1
fi

# ── SPIELSTART ───────────────────────────────────────────────────────
log_section "SPIELSTART"

if [ ! -x ./halo ]; then
    echo "FEHLER: ./halo fehlt." >&2
    exit 1
fi

HALO_STDOUT="$GAMEDIR/halo-stdout.txt"
HALO_STDERR="$GAMEDIR/halo-stderr.txt"
: > "$HALO_STDOUT"
: > "$HALO_STDERR"

# gptokeyb, falls verfügbar
GPTOKEYB_PID=""
if [ -n "$PM_CONTROLFOLDER" ] && command -v gptokeyb >/dev/null 2>&1; then
    gptokeyb "./halo" >/dev/null 2>&1 &
    GPTOKEYB_PID=$!
fi
cleanup_gptokeyb() {
    [ -n "$GPTOKEYB_PID" ] && kill -0 "$GPTOKEYB_PID" 2>/dev/null && \
        kill -TERM "$GPTOKEYB_PID" 2>/dev/null || true
}
trap cleanup_gptokeyb EXIT

# timeout: SIGTERM nach Ablauf (sauberes .profraw), SIGKILL nach +30 s
if [ "$TRAINING_FLAG" = "1" ]; then
    log "Starte: timeout --signal=TERM --kill-after=30 $HALO_EXIT_SECONDS ./halo"
    timeout --signal=TERM --kill-after=30 "$HALO_EXIT_SECONDS" \
        ./halo > "$HALO_STDOUT" 2> "$HALO_STDERR" &
    HALO_PID=$!
else
    log "Starte: ./halo"
    ./halo > "$HALO_STDOUT" 2> "$HALO_STDERR" &
    HALO_PID=$!
fi
log "PID=$HALO_PID"

forward_signal() {
    [ -n "$HALO_PID" ] && kill -0 "$HALO_PID" 2>/dev/null && \
        kill -TERM "$HALO_PID" 2>/dev/null || true
}
trap forward_signal TERM INT HUP

HALO_STATUS=0
while kill -0 "$HALO_PID" 2>/dev/null; do
    wait "$HALO_PID"
    HALO_STATUS=$?
done

[ -n "$GPTOKEYB_PID" ] && kill -0 "$GPTOKEYB_PID" 2>/dev/null && {
    kill -TERM "$GPTOKEYB_PID" 2>/dev/null || true
    wait "$GPTOKEYB_PID" 2>/dev/null || true
}

log "halo beendet mit Status $HALO_STATUS"

# ── PGO-TRAINING: DATEN SICHERN ──────────────────────────────────────
if [ "$TRAINING_FLAG" = "1" ]; then
    log_section "PGO-TRAINING: SICHERN"
    echo ""
    echo "════════════════════════════════════════════════════════════"
    echo " PGO-Training beendet (Status $HALO_STATUS)"
    echo "════════════════════════════════════════════════════════════"
    echo "== Warte auf vollständiges Schreiben der SD-Karte ..."
    sync
    sleep 5
    sync
    sleep 2

    PROFRAW_FILES=$(ls -1 "$GAMEDIR"/halo-*.profraw 2>/dev/null)
    PROFRAW_COUNT=$(printf '%s\n' "$PROFRAW_FILES" | grep -c . || true)

    if [ "$PROFRAW_COUNT" -gt 0 ]; then
        log "$PROFRAW_COUNT Profil-Datei(en): $PROFRAW_FILES"
        echo "== $PROFRAW_COUNT Profil-Datei(en):"
        ls -la "$GAMEDIR"/halo-*.profraw
        echo ""
        echo "== Nächste Schritte auf dem Build-Rechner:"
        echo "   1. .profraw-Dateien von der SD-Karte kopieren"
        echo "   2. llvm-profdata merge -output=pgo/halo_android.profdata halo-*.profraw"
        echo "   3. PGO_MODE=use ./build.sh"
    else
        log "FEHLER: keine .profraw-Dateien gefunden!"
        echo "== FEHLER: keine .profraw-Dateien gefunden!"
        echo "== Prüfe, ob halo_guest.elf der Trainings-Build ist (12-15 MB)."
    fi
    echo "════════════════════════════════════════════════════════════"
    echo ""
fi

[ "$HALO_STATUS" -ge 0 ] && exit "$HALO_STATUS" || exit 1
