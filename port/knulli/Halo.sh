#!/bin/bash
# Halo: Combat Evolved – M9 Pro (RK3326 / Cortex-A35 + Mali-G31 MP2)
#
# RELEASE-BUILD: PGO (use) + LTO, alle Port-Optimierungen aktiv.
# Kein Training, kein Auto-Exit, keine Debug-Logs.
#
# Tastenbelegung (ueber HALO_BUTTON_REMAP=1 in xinput_sdl.c):
#   A <-> B       Springen auf B, Nahkampf auf A
#   X <-> Y       Nachladen auf Y, Waffenwechsel auf X
#   LB (L1) <-> LT (L2)   Granate auf L1, Taschenlampe auf L2
#   RB (R1) <-> RT (R2)   Feuern auf R1, Granatenwechsel auf R2

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

# ── LOGGING (nur Launcher-Minimum) ───────────────────────────────────
LOG="$GAMEDIR/log.txt"
if ! touch "$LOG" 2>/dev/null; then
    LOG="/tmp/halo-log.txt"
    touch "$LOG" 2>/dev/null || LOG="/dev/null"
fi
exec >> "$LOG" 2>&1

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
log_section() {
    log ""
    log "========================================================="
    log "== $*"
    log "========================================================="
}

log_section "START"
log "SCRIPT_DIR=$SCRIPT_DIR"
log "GAMEDIR=$GAMEDIR"
log "Kernel=$(uname -r), Arch=$(uname -m)"
log "Datum=$(date)"

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
    source "$PM_CONTROLFOLDER/control.txt" 2>/dev/null || true
    if [ -n "${CFW_NAME:-}" ] && [ -f "$PM_CONTROLFOLDER/mod_${CFW_NAME}.txt" ]; then
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

# CPU-Governor auf performance
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

# GPU-Governor auf performance + min_freq = max_freq
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

# ZRAM
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

# tailscaled stoppen
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

# Restore-Handler
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
export SDL_VIDEODRIVER="${SDL_VIDEODRIVER:-kmsdrm}"
unset SDL_AUDIODRIVER
unset AUDIODEV

# ── HALO-PFADE ───────────────────────────────────────────────────────
log_section "HALO-PFADE"
export HALO_DATA_ROOT="$GAMEDIR"
export HALO_SAVE_ROOT="$GAMEDIR/save"
log "HALO_DATA_ROOT=$HALO_DATA_ROOT"
log "HALO_SAVE_ROOT=$HALO_SAVE_ROOT"

# ── HALO-EINSTELLUNGEN (Release) ─────────────────────────────────────
log_section "HALO-EINSTELLUNGEN"

# --- Bild ---
export HALO_RENDER_SCALE="${HALO_RENDER_SCALE:-1.0}"
# Dynamische Auflösung aus, damit render_scale garantiert konstant bleibt.
export HALO_DYNAMIC_RESOLUTION="${HALO_DYNAMIC_RESOLUTION:-0}"
export HALO_DYNAMIC_RESOLUTION_MIN="${HALO_DYNAMIC_RESOLUTION_MIN:-1.0}"
export HALO_MODEL_DETAIL="${HALO_MODEL_DETAIL:-0.35}"

# --- Mali-Beschleuniger ---
export HALO_FAST_SHADERS="${HALO_FAST_SHADERS:-1}"
export HALO_FAST_TEXTURES="${HALO_FAST_TEXTURES:-1}"

# --- Pacing und VSync ---
export HALO_INTERPOLATION="${HALO_INTERPOLATION:-1}"
# HALO_NO_VSYNC darf NICHT gesetzt werden (jeder Wert schaltet VSync ab).
unset HALO_NO_VSYNC
# Zusätzlicher Schutz: Swap-Interval hart auf 1 (VSync an)
export HALO_SWAP_INTERVAL=1
export HALO_FRAME_PACING="${HALO_FRAME_PACING:-1}"

# --- HUD und Text: aus (RAM-Ersparnis auf 1 GB) ---
export HALO_HIGH_RES_HUD=0
export HALO_HIGH_RES_TEXT=0

# --- Renderer-Features ---
export HALO_SORT_MODELS="${HALO_SORT_MODELS:-1}"
export HALO_INSTANCE_MODELS="${HALO_INSTANCE_MODELS:-1}"
export HALO_BATCH_QUADS="${HALO_BATCH_QUADS:-1}"
export HALO_ALPHA_TEST_ELISION="${HALO_ALPHA_TEST_ELISION:-1}"
export HALO_STABLE_STREAMS="${HALO_STABLE_STREAMS:-1}"

# --- Threading (async textures/shaders/programs) ---
export HALO_GL_THREAD="${HALO_GL_THREAD:-1}"
export HALO_GL_THREAD_FRAMES="${HALO_GL_THREAD_FRAMES:-1}"
export HALO_ASYNC_TEXTURES="${HALO_ASYNC_TEXTURES:-1}"
export HALO_ASYNC_SHADERS="${HALO_ASYNC_SHADERS:-1}"
export HALO_ASYNC_PROGRAMS="${HALO_ASYNC_PROGRAMS:-1}"

# --- Tastenbelegung (in port/linux/src/xinput_sdl.c ausgewertet) ---
# A <-> B (Springen auf B, Nahkampf auf A)
# X <-> Y (Nachladen auf Y, Waffenwechsel auf X)
# LB (L1) <-> LT (L2) (Granate auf L1, Taschenlampe auf L2)
# RB (R1) <-> RT (R2) (Feuern auf R1, Granatenwechsel auf R2)
export HALO_BUTTON_REMAP=1

# --- PS Vita Port-Optimierungen ---
# Sound-Occlusion nur jeden 3. Tick berechnen
export HALO_SOUND_OBSTRUCTION_TICKS=3
# Objekte unter 8 Pixeln Durchmesser überspringen
export HALO_MIN_OBJECT_PIXELS=8
# Statische Objektbeleuchtung nur jeden 2. Tick neu berechnen
export HALO_LIGHTING_REFRESH_DIVISOR=2

# ══════════════════════════════════════════════════════════════════════
# KEINE DEBUG- ODER STATISTIK-AUSGABEN IM RELEASE
# ══════════════════════════════════════════════════════════════════════
unset HALO_DEBUG_LOGS 2>/dev/null || true
unset HALO_GPU_STATS 2>/dev/null || true
unset HALO_GL_TIMING 2>/dev/null || true
unset HALO_HITCH_LOG 2>/dev/null || true
unset HALO_FPS_LOG 2>/dev/null || true
unset HALO_PERF_LOG 2>/dev/null || true
unset HALO_MEMORY_STATS 2>/dev/null || true
unset HALO_SAMPLE 2>/dev/null || true
unset HALO_DEBUG_DRAW_CALLERS 2>/dev/null || true
unset HALO_DEBUG_FREEZE 2>/dev/null || true
unset HALO_DEBUG_LOD_BIAS 2>/dev/null || true
unset HALO_GL_FRAME_LOG 2>/dev/null || true
unset HALO_PACING_LOG 2>/dev/null || true
unset HALO_GPU_PASS_TIMING 2>/dev/null || true
unset HALO_GPU_TRACE_PASSES_AT 2>/dev/null || true
unset HALO_GPU_TRACE_PASSES_FRAMES 2>/dev/null || true
unset HALO_DEBUG_SKIP_GL 2>/dev/null || true

log "render_scale=$HALO_RENDER_SCALE, model_detail=$HALO_MODEL_DETAIL"
log "distant_objects=$HALO_MIN_OBJECT_PIXELS px"
log "dynamic_resolution=$HALO_DYNAMIC_RESOLUTION (min $HALO_DYNAMIC_RESOLUTION_MIN)"
log "fast_shaders=$HALO_FAST_SHADERS, fast_textures=$HALO_FAST_TEXTURES"
log "interpolation=$HALO_INTERPOLATION, swap_interval=$HALO_SWAP_INTERVAL, frame_pacing=$HALO_FRAME_PACING"
log "high_res_hud=$HALO_HIGH_RES_HUD, high_res_text=$HALO_HIGH_RES_TEXT"
log "button_remap=$HALO_BUTTON_REMAP (A<->B, X<->Y, LB<->LT, RB<->RT)"
log "sound_occlusion_ticks=$HALO_SOUND_OBSTRUCTION_TICKS, lighting_refresh_divisor=$HALO_LIGHTING_REFRESH_DIVISOR"
log "Release: keine Debug- und Statistik-Ausgaben."

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

if [ -f ./halo_guest.elf ]; then
    GUEST_SIZE=$(stat -c%s ./halo_guest.elf)
    GUEST_SIZE_MB=$((GUEST_SIZE / 1048576))
    log "halo_guest.elf: $GUEST_SIZE Bytes (~${GUEST_SIZE_MB} MB)"
fi

HALO_STDOUT="$GAMEDIR/halo-stdout.txt"
HALO_STDERR="$GAMEDIR/halo-stderr.txt"
: > "$HALO_STDOUT"
: > "$HALO_STDERR"

# gptokeyb falls verfügbar
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

log "Starte: ./halo"
./halo > "$HALO_STDOUT" 2> "$HALO_STDERR" &
HALO_PID=$!
log "PID=$HALO_PID"

forward_signal() {
    [ -n "$HALO_PID" ] && kill -0 "$HALO_PID" 2>/dev/null && \
        kill -TERM "$HALO_PID" 2>/dev/null || true
}
trap forward_signal TERM INT HUP

wait "$HALO_PID"
HALO_STATUS=$?

[ -n "$GPTOKEYB_PID" ] && kill -0 "$GPTOKEYB_PID" 2>/dev/null && {
    kill -TERM "$GPTOKEYB_PID" 2>/dev/null || true
    wait "$GPTOKEYB_PID" 2>/dev/null || true
}

log "halo beendet mit Status $HALO_STATUS"

log_section "ENDE"
sync
exit "$HALO_STATUS"
