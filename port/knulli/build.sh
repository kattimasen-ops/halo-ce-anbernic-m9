#!/bin/sh
# Builds the Knulli port into build/knulli:
#   halo            the aarch64 glibc host (the loader, SDL2, OpenGL ES)
#   halo_guest.elf  the game, the Android port's guest image
#   libs.aarch64/   the runtime libraries the device may not have
#
# Bewusst POSIX-sh-kompatibel (dash): set -eu statt set -euo pipefail.
#
# WICHTIG: libmali wird NICHT mitgeliefert und NICHT gelinkt. Auf dem
# M9 Pro kommt sie aus dem System (Halo.sh legt /tmp/halo-mali mit
# Symlinks auf /usr/local/lib/aarch64-linux-gnu/libmali-bifrost-g31-rxp0-gbm.so
# an und setzt diesen Pfad in LD_LIBRARY_PATH vor libs.aarch64). Damit
# brauchen wir weder eine gueltige libmali im Repo noch das -lmali-
# Flag beim Linken; die EGL/GLES-Symbole werden zur Laufzeit gefunden.
set -eu

folder() {
    resolved=$(cd "$1" && pwd) || { echo "build.sh: $1: no such folder" >&2; exit 1; }
    case "$resolved" in
        *" "*) echo "build.sh: $resolved: a path with spaces is not supported" >&2; exit 1 ;;
    esac
    echo "$resolved"
}

SDL2_INCLUDE=$(folder "${SDL2_INCLUDE:?the folder that holds SDL2/SDL.h}")
SYSROOT_LIB=$(folder "${SYSROOT_LIB:?the device libraries}")
NDK=$(folder "${ANDROID_NDK:?the Android NDK (for the OpenGL ES and EGL headers)}")

cd "$(dirname "$0")/../.."
ROOT=$(folder .)
CC=${CC:-aarch64-linux-gnu-gcc}
JOBS=${JOBS:-$(nproc)}
OUT=build/knulli
OBJ=$OUT/obj

ninja -j "$JOBS" build/android/halo_guest.elf build/android/host/host_import_table.c
mkdir -p "$OBJ" "$OUT/gl_include" "$OUT/lib" "$OUT/libs.aarch64"

KHRONOS=$NDK/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include
for name in EGL GLES2 GLES3 KHR; do
    ln -sfn "$KHRONOS/$name" "$OUT/gl_include/$name"
done

echo "== Inhalt von SYSROOT_LIB=$SYSROOT_LIB:"
ls -la "$SYSROOT_LIB" || true

echo "== Kopiere Laufzeitbibliotheken nach $OUT/libs.aarch64/"
copy_runtime_lib() {
    prefix=$1
    target=$2
    src=$(find "$SYSROOT_LIB" -maxdepth 1 -name "$prefix*" -type f 2>/dev/null | head -n 1)
    if [ -z "$src" ]; then
        src=$(find "$SYSROOT_LIB" -maxdepth 1 -name "$prefix*" 2>/dev/null | head -n 1)
    fi
    if [ -z "$src" ]; then
        echo "  WARNUNG: keine $prefix*-Datei in SYSROOT_LIB – $target wird nicht ausgeliefert"
        return 1
    fi
    cp -L "$src" "$OUT/libs.aarch64/$target"
    echo "  $target <- $(basename "$src") ($(stat -c%s "$OUT/libs.aarch64/$target") Bytes)"
    return 0
}

# libmali absichtlich NICHT kopieren (siehe Kommentar oben).
copy_runtime_lib "libSDL3"   "libSDL3.so.0"
copy_runtime_lib "libSDL2"   "libSDL2-2.0.so.0"
copy_runtime_lib "libdecor"  "libdecor-0.so.0"

link_library() {
    pattern=$1
    linkname=$2
    library=$(find "$SYSROOT_LIB" -maxdepth 1 -name "$pattern" -type f 2>/dev/null | head -n 1)
    if [ -z "$library" ]; then
        library=$(find "$SYSROOT_LIB" -maxdepth 1 -name "$pattern" 2>/dev/null | head -n 1)
    fi
    if [ -z "$library" ]; then
        echo "build.sh: no $pattern in SYSROOT_LIB=$SYSROOT_LIB" >&2
        return 1
    fi
    rm -f "$OUT/lib/$linkname" "$OUT/lib/$linkname.0" "$OUT/lib/$linkname.tmp"
    if ! ln "$library" "$OUT/lib/$linkname" 2>/dev/null; then
        cp -L "$library" "$OUT/lib/$linkname" || {
            echo "build.sh: cp fehlgeschlagen fuer $linkname" >&2
            return 1
        }
    fi
    size=$(stat -c%s "$OUT/lib/$linkname" 2>/dev/null || echo 0)
    if [ "$size" -lt 1024 ]; then
        echo "build.sh: $OUT/lib/$linkname ist nur $size Bytes gross" >&2
        ls -la "$OUT/lib/" >&2
        return 1
    fi
    echo "  copied $linkname <- $(basename "$library") ($size Bytes)"
    return 0
}

# libmali absichtlich NICHT linken.
link_library "libSDL2*"  "libSDL2.so"    || exit 1
link_library "libSDL3*"  "libSDL3.so"    || exit 1
link_library "libdecor*" "libdecor.so"   || exit 1

CFLAGS="-O3 -mcpu=cortex-a35 -mtune=cortex-a35 -fPIC -Wall -Wno-unused-function \
        -D_GNU_SOURCE -DEGL_NO_X11 -DMESA_EGL_NO_X11_HEADERS \
        -DHALO_ANDROID \
        -flto -fomit-frame-pointer -ffunction-sections -fdata-sections \
        -fno-plt -fno-semantic-interposition"

CFLAGS="$CFLAGS -ffile-prefix-map=$ROOT=. -ffile-prefix-map=$SDL2_INCLUDE=sdl2"
INCLUDES="-Iport/knulli/compat -Iport/knulli/host -Iport/android/include \
          -Iport/android/host -Iport/linux/src -Iport/third_party/tomlc17 \
          -I$OUT/gl_include -I$SDL2_INCLUDE"
MINIUPNPC="-Iport/third_party/miniupnpc/include -Iport/third_party/miniupnpc/src \
           -DMINIUPNP_STATICLIB -DMINIUPNPC_SET_SOCKET_TIMEOUT -DMINIUPNPC_GET_SRC_ADDR \
           -D_BSD_SOURCE -D_DEFAULT_SOURCE -w"

FLAGS=$OUT/flags
printf '%s\n' "$CC $CFLAGS $INCLUDES $MINIUPNPC" > "$FLAGS.new"
cmp -s "$FLAGS.new" "$FLAGS" || mv "$FLAGS.new" "$FLAGS"
rm -f "$FLAGS.new"

objects=""
stale() {
    object=$1
    [ ! -f "$object" ] || [ ! -f "$object.d" ] || [ "$0" -nt "$object" ] || [ "$FLAGS" -nt "$object" ] && return 0
    dependencies=$(sed -e 's/^[^:]*://' -e 's/\\$//' "$object.d") || return 0
    for dependency in $dependencies; do
        [ -f "$dependency" ] || return 0
        [ "$dependency" -nt "$object" ] && return 0
    done
    return 1
}

compile() {
    source=$1
    shift
    object=$OBJ/$(echo "$source" | tr / _).o
    if stale "$object"; then
        echo "CC $source"
        $CC $CFLAGS $INCLUDES "$@" -MMD -MF "$object.d" -c "$source" -o "$object"
    fi
    objects="$objects $object"
}

for source in host_debug host_gl host_loader host_memory host_syscall host_thread; do
    compile port/android/host/$source.c
done
compile port/knulli/host/host_main.c
compile port/knulli/host/host_sdl2.c
compile port/knulli/host/host_profile.c
compile port/knulli/host/host_gl_timing.c
compile port/knulli/host/host_gl_timing.S

python3 port/knulli/glthread_gen.py build/android/guest/gen/gl_imports.list \
    "$KHRONOS/GLES3/gl32.h" \
    "$OUT/host_glthread_gen.c.new"
cmp -s "$OUT/host_glthread_gen.c.new" "$OUT/host_glthread_gen.c" || \
    mv "$OUT/host_glthread_gen.c.new" "$OUT/host_glthread_gen.c"
rm -f "$OUT/host_glthread_gen.c.new"

compile port/knulli/host/host_glthread.c
compile "$OUT/host_glthread_gen.c"
compile port/knulli/host/host_sdl3_events.c -Ibuild/android/third_party/SDL3/include
compile port/linux/src/posix_files.c
compile port/linux/src/posix_net.c
compile port/linux/src/posix_upnp.c $MINIUPNPC
for source in port/third_party/miniupnpc/src/*.c; do
    compile "$source" $MINIUPNPC
done
compile port/third_party/tomlc17/tomlc17.c -w
compile build/android/host/host_import_table.c

echo "LINK $OUT/halo"
# KEIN -lmali: die EGL/GLES-Symbole, die host_gl.c und host_glthread_gen.c
# referenzieren, werden zur Laufzeit aus der System-Mali aufgeloest
# (Halo.sh: LD_LIBRARY_PATH=/tmp/halo-mali:... vor libs.aarch64).
# --unresolved-symbols=ignore-all laesst sie beim Linken offen; sie landen
# als normale undefinierte Symbole in der dynamischen Symboltabelle und
# werden beim Start vom Loader ueber LD_LIBRARY_PATH und die DT_NEEDED-
# Eintraege aufgeloest. Die anschliessende Verifikation listet ALLE offenen
# Symbole auf, damit auf dem Geraet keine Ueberraschung passiert.
$CC -o "$OUT/halo" $objects \
    -L"$OUT/lib" \
    -Wl,-rpath-link,"$OUT/lib" \
    -Wl,--allow-shlib-undefined \
    -Wl,--unresolved-symbols=ignore-all \
    -Wl,-O1 -Wl,--as-needed -Wl,--gc-sections \
    -flto \
    -lSDL2 -lpthread -ldl -lm

# ══════════════════════════════════════════════════════════════════════
# Verifikation: welche Symbole braucht der Loader zur Laufzeit?
# Erwartet: EGL/GLES (System-Mali), SDL2, libc, libpthread, libdl, libm.
# Alles andere wird als WARNUNG ausgegeben, damit auf dem Geraet keine
# Ueberraschung passiert.
# ══════════════════════════════════════════════════════════════════════
echo "== Pruefe unaufgeloeste Symbole in $OUT/halo ..."
if command -v nm > /dev/null 2>&1; then
    UNDEFINED=$(nm -D --undefined-only "$OUT/halo" 2>/dev/null | awk '{print $NF}' | sort -u)
else
    UNDEFINED=""
    echo "  (nm fehlt, ueberspringe Verifikation)"
fi

if [ -n "$UNDEFINED" ]; then
    TOTAL=0
    EXPECTED=0
    UNKNOWN=""
    for sym in $UNDEFINED; do
        TOTAL=$((TOTAL + 1))
        case "$sym" in
            # EGL / GLES — System-Mali zur Laufzeit
            egl*|gl[A-Z]*|glGet*|glBind*|glTex*|glDraw*|glEnable*|glDisable*|\
            glClear*|glVertex*|glColor*|glDepth*|glStencil*|glBlend*|glCull*|\
            glFront*|glPolygon*|glPixel*|glRead*|glViewport*|glScissor*|\
            glFinish|glFlush|glActive*|glAttach*|glCompile*|glCreate*|glDelete*|\
            glDetach*|glFramebuffer*|glGen*|glGet*|glIs*|glLink*|glProgram*|\
            glRenderbuffer*|glShader*|glUniform*|glUse*|glVertexAttrib*|\
            glBuffer*|glMap*|glUnmap*|glInvalidate*|glFence*|glWait*|glClient*|\
            glGetError|glGetString|glGetIntegerv|glGetFloatv|glGetBooleanv)
                EXPECTED=$((EXPECTED + 1))
                ;;
            # SDL2
            SDL_*)
                EXPECTED=$((EXPECTED + 1))
                ;;
            # libc / libm / libpthread / libdl — Standard
            memcpy|memmove|memset|memcmp|memchr|strlen|strcpy|strncpy|strcat|\
            strncat|strcmp|strncmp|strchr|strrchr|strstr|strtol|strtoul|strtod|\
            strtof|strtoll|strtoull|atoi|atof|atol|malloc|calloc|realloc|free|\
            printf|fprintf|sprintf|snprintf|vprintf|vfprintf|vsnprintf|puts|\
            fputs|putchar|fputc|fopen|fclose|fread|fwrite|fseek|ftell|fflush|\
            feof|ferror|perror|exit|abort|atexit|qsort|bsearch|rand|srand|\
            getenv|setenv|unsetenv|time|clock|gettimeofday|clock_gettime|\
            nanosleep|usleep|sleep|__errno_location|__assert_fail|__stack_chk_fail|\
            __cxa_atexit|__cxa_finalize|\
            pthread_*|dlopen|dlsym|dlclose|dlerror|\
            open|open64|close|read|write|lseek|lseek64|fstat|stat|stat64|\
            mkdir|rmdir|unlink|rename|opendir|readdir|closedir|select|poll|\
            pipe|fork|exec*|wait*|waitpid|kill|raise|signal|sigaction|\
            getpid|getppid|getuid|geteuid|getgid|getegid|getpwuid|\
            mmap|mmap64|munmap|mprotect|ioctl|fcntl|fcntl64|access|chdir|\
            getcwd|realpath|truncate|ftruncate|\
            sqrt|sqrtf|pow|powf|sin|sinf|cos|cosf|tan|tanf|atan|atan2|\
            exp|expf|log|logf|log10|log2|floor|floorf|ceil|ceilf|\
            fabs|fabsf|round|roundf|trunc|truncf|copysign|copysignf|\
            fmod|fmodf|ldexp|ldexpf|frexp|frexpf|isnan|isinf|finite|\
            atan2f|asinf|acosf|sinhf|coshf|tanhf|exp2|exp2f|log1p|log1pf|\
            hypot|hypotf|cbrt|cbrtf|erf|erff|tgamma|tgammaf|lgamma|lgammaf|\
            __*|_*)
                EXPECTED=$((EXPECTED + 1))
                ;;
            # Versionssymbole (GLIBC_2.17 usw.)
            *@*)
                EXPECTED=$((EXPECTED + 1))
                ;;
            # Leerzeilen
            "")
                ;;
            *)
                UNKNOWN="$UNKNOWN $sym"
                ;;
        esac
    done
    echo "  Symbole insgesamt:       $TOTAL"
    echo "  davon erwartet:          $EXPECTED"
    if [ -n "$UNKNOWN" ]; then
        echo "  UNERWARTET:"
        for sym in $UNKNOWN; do
            echo "    $sym"
        done
        echo ""
        echo "  Diese Symbole werden zur Laufzeit auf dem Geraet fehlen,"
        echo "  wenn keine zusaetzliche Bibliothek sie bereitstellt. Bitte"
        echo "  pruefen, ob eine weitere -l-Option oder eine System-.so noetig"
        echo "  ist, und ob sie in Halo.sh auf dem LD_LIBRARY_PATH liegt."
    else
        echo "  OK: alle offenen Symbole gehoeren zur erwarteten Familie"
        echo "      (EGL/GLES, SDL2, libc/libm/libpthread/libdl)."
    fi
else
    echo "  (keine dynamisch unaufgeloesten Symbole)"
fi

cp build/android/halo_guest.elf "$OUT/halo_guest.elf"

echo "== Inhalt von $OUT/libs.aarch64/:"
ls -la "$OUT/libs.aarch64/"
echo "== $OUT/halo und $OUT/halo_guest.elf:"
ls -l "$OUT/halo" "$OUT/halo_guest.elf"
