#!/usr/bin/env python3
"""Loggt alle Input-Devices und ihre Events in den Launcher-Log.

Aufruf:
    halo_controls.py <sekunden>

Schreibt alles nach stdout (das Halo.sh in log.txt umleitet).
Nutzt nur die Standardbibliothek, damit es auf ArkOS ohne weitere
Pakete läuft.
"""

import glob
import os
import select
import signal
import struct
import sys
import time

EVENT = struct.Struct("llHHi")

KEY_NAMES = {
    1: "ESC", 2: "1", 3: "2", 4: "3", 5: "4", 6: "5", 7: "6", 8: "7",
    9: "8", 10: "9", 11: "0", 12: "MINUS", 13: "EQUAL", 14: "BACKSPACE",
    15: "TAB", 16: "Q", 17: "W", 18: "E", 19: "R", 20: "T", 21: "Y",
    22: "U", 23: "I", 24: "O", 25: "P", 26: "LEFTBRACE", 27: "RIGHTBRACE",
    28: "ENTER", 29: "LEFTCTRL", 30: "A", 31: "S", 32: "D", 33: "F",
    34: "G", 35: "H", 36: "J", 37: "K", 38: "L", 39: "SEMICOLON",
    40: "APOSTROPHE", 41: "GRAVE", 42: "LEFTSHIFT", 43: "BACKSLASH",
    44: "Z", 45: "X", 46: "C", 47: "V", 48: "B", 49: "N", 50: "M",
    51: "COMMA", 52: "DOT", 53: "SLASH", 54: "RIGHTSHIFT",
    55: "KPASTERISK", 56: "LEFTALT", 57: "SPACE", 58: "CAPSLOCK",
    59: "F1", 60: "F2", 61: "F3", 62: "F4", 63: "F5", 64: "F6",
    65: "F7", 66: "F8", 67: "F9", 68: "F10",
    102: "HOME", 103: "UP", 104: "PAGEUP", 105: "LEFT", 106: "RIGHT",
    107: "END", 108: "DOWN", 109: "PAGEDOWN", 110: "INSERT", 111: "DELETE",
    113: "MUTE", 114: "VOLUMEDOWN", 115: "VOLUMEUP", 116: "POWER",
    304: "BTN_SOUTH (A)", 305: "BTN_EAST (B)", 306: "BTN_C",
    307: "BTN_NORTH (X)", 308: "BTN_WEST (Y)", 309: "BTN_Z",
    310: "BTN_TL (L1)", 311: "BTN_TR (R1)",
    312: "BTN_TL2 (L2)", 313: "BTN_TR2 (R2)",
    314: "BTN_SELECT", 315: "BTN_START", 316: "BTN_MODE",
    317: "BTN_THUMBL", 318: "BTN_THUMBR",
    319: "BTN_DPAD_UP", 320: "BTN_DPAD_DOWN",
    321: "BTN_DPAD_LEFT", 322: "BTN_DPAD_RIGHT",
    544: "BTN_TRIGGER_HAPPY1", 545: "BTN_TRIGGER_HAPPY2",
    546: "BTN_TRIGGER_HAPPY3", 547: "BTN_TRIGGER_HAPPY4",
    548: "BTN_TRIGGER_HAPPY5", 549: "BTN_TRIGGER_HAPPY6",
    550: "BTN_TRIGGER_HAPPY7", 551: "BTN_TRIGGER_HAPPY8",
    552: "BTN_TRIGGER_HAPPY9", 553: "BTN_TRIGGER_HAPPY10",
    554: "BTN_TRIGGER_HAPPY11", 555: "BTN_TRIGGER_HAPPY12",
    556: "BTN_TRIGGER_HAPPY13", 557: "BTN_TRIGGER_HAPPY14",
    558: "BTN_TRIGGER_HAPPY15", 559: "BTN_TRIGGER_HAPPY16",
    560: "BTN_TRIGGER_HAPPY17", 561: "BTN_TRIGGER_HAPPY18",
    562: "BTN_TRIGGER_HAPPY19", 563: "BTN_TRIGGER_HAPPY20",
    564: "BTN_TRIGGER_HAPPY21", 565: "BTN_TRIGGER_HAPPY22",
    566: "BTN_TRIGGER_HAPPY23", 567: "BTN_TRIGGER_HAPPY24",
    568: "BTN_TRIGGER_HAPPY25", 569: "BTN_TRIGGER_HAPPY26",
    570: "BTN_TRIGGER_HAPPY27", 571: "BTN_TRIGGER_HAPPY28",
    572: "BTN_TRIGGER_HAPPY29", 573: "BTN_TRIGGER_HAPPY30",
    574: "BTN_TRIGGER_HAPPY31", 575: "BTN_TRIGGER_HAPPY32",
    576: "BTN_TRIGGER_HAPPY33", 577: "BTN_TRIGGER_HAPPY34",
    578: "BTN_TRIGGER_HAPPY35", 579: "BTN_TRIGGER_HAPPY36",
    580: "BTN_TRIGGER_HAPPY37", 581: "BTN_TRIGGER_HAPPY38",
    582: "BTN_TRIGGER_HAPPY39", 583: "BTN_TRIGGER_HAPPY40",
}

ABS_NAMES = {
    0x00: "ABS_X", 0x01: "ABS_Y", 0x02: "ABS_Z",
    0x03: "ABS_RX", 0x04: "ABS_RY", 0x05: "ABS_RZ",
    0x06: "ABS_THROTTLE", 0x07: "ABS_RUDDER", 0x08: "ABS_WHEEL",
    0x09: "ABS_GAS", 0x0a: "ABS_BRAKE",
    0x10: "ABS_HAT0X", 0x11: "ABS_HAT0Y",
    0x12: "ABS_HAT1X", 0x13: "ABS_HAT1Y",
    0x14: "ABS_HAT2X", 0x15: "ABS_HAT2Y",
    0x16: "ABS_HAT3X", 0x17: "ABS_HAT3Y",
    0x18: "ABS_PRESSURE", 0x19: "ABS_DISTANCE",
    0x1a: "ABS_TILT_X", 0x1b: "ABS_TILT_Y",
    0x1c: "ABS_TOOL_WIDTH",
    0x20: "ABS_VOLUME",
    0x28: "ABS_MISC",
    0x2f: "ABS_MT_SLOT", 0x30: "ABS_MT_TOUCH_MAJOR",
    0x31: "ABS_MT_TOUCH_MINOR", 0x32: "ABS_MT_WIDTH_MAJOR",
    0x33: "ABS_MT_WIDTH_MINOR", 0x34: "ABS_MT_ORIENTATION",
    0x35: "ABS_MT_POSITION_X", 0x36: "ABS_MT_POSITION_Y",
    0x37: "ABS_MT_TOOL_TYPE", 0x38: "ABS_MT_BLOB_ID",
    0x39: "ABS_MT_TRACKING_ID", 0x3a: "ABS_MT_PRESSURE",
    0x3b: "ABS_MT_DISTANCE",
}


def dump_proc_devices():
    print("=========================================================", flush=True)
    print("== /proc/bus/input/devices", flush=True)
    print("=========================================================", flush=True)
    try:
        with open("/proc/bus/input/devices") as f:
            sys.stdout.write(f.read())
        sys.stdout.flush()
    except OSError as e:
        print(f"  konnte /proc/bus/input/devices nicht lesen: {e}", flush=True)


def dump_dev_input():
    print("=========================================================", flush=True)
    print("== /dev/input", flush=True)
    print("=========================================================", flush=True)
    for path in sorted(glob.glob("/dev/input/*")):
        try:
            st = os.lstat(path)
            kind = "link" if os.path.islink(path) else "file"
            print(f"  {path}  ({kind}, mode={oct(st.st_mode)})", flush=True)
        except OSError as e:
            print(f"  {path}  Fehler: {e}", flush=True)


def capture(window):
    print("=========================================================", flush=True)
    print(f"== Input-Capture für {window} Sekunden", flush=True)
    print("=========================================================", flush=True)

    print(f"  Ausführender User: UID={os.getuid()}, GID={os.getgid()}", flush=True)
    try:
        import pwd, grp
        print(f"  Username: {pwd.getpwuid(os.getuid()).pw_name}", flush=True)
        groups = [grp.getgrgid(g).gr_name for g in os.getgroups()]
        print(f"  Gruppen: {', '.join(groups)}", flush=True)
    except Exception as e:
        print(f"  konnte User/Gruppen nicht ermitteln: {e}", flush=True)

    # Harter Timeout per SIGALRM, damit die Funktion garantiert endet.
    def on_alarm(signum, frame):
        raise TimeoutError()

    old_handler = signal.signal(signal.SIGALRM, on_alarm)
    signal.alarm(max(1, int(window)))

    devices = []
    try:
        candidates = sorted(glob.glob("/dev/input/event*"))
        print(f"  gefundene Devices: {len(candidates)}", flush=True)
        for path in candidates:
            try:
                st = os.stat(path)
                import pwd, grp
                try:
                    owner = pwd.getpwuid(st.st_uid).pw_name
                except KeyError:
                    owner = str(st.st_uid)
                try:
                    group = grp.getgrgid(st.st_gid).gr_name
                except KeyError:
                    group = str(st.st_gid)
                print(f"  {path}  owner={owner}:{group}  mode={oct(st.st_mode)}", flush=True)
            except OSError as e:
                print(f"  {path}  stat Fehler: {e}", flush=True)

        for path in candidates:
            try:
                fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
                devices.append((path, fd))
                print(f"  geöffnet: {path}", flush=True)
            except OSError as e:
                print(f"  konnte {path} nicht öffnen: {e}", flush=True)

        if not devices:
            print("  KEINE Input-Devices zum Auslesen gefunden!", flush=True)
            print("  -> der ausführende User hat wahrscheinlich keine", flush=True)
            print("     Berechtigung auf /dev/input/event*", flush=True)
            return

        start = time.monotonic()
        deadline = start + window
        fds = [fd for _, fd in devices]
        names = {fd: name for name, fd in devices}

        last_axis = {}
        last_key = {}
        events_seen = 0

        while time.monotonic() < deadline:
            left = deadline - time.monotonic()
            if left <= 0:
                break
            try:
                ready, _, _ = select.select(fds, [], [], min(left, 0.5))
            except OSError as e:
                print(f"  select() Fehler: {e}", flush=True)
                break
            for fd in ready:
                try:
                    data = os.read(fd, EVENT.size * 64)
                except OSError:
                    continue
                usable = len(data) - len(data) % EVENT.size
                for sec, usec, kind, code, value in EVENT.iter_unpack(data[:usable]):
                    events_seen += 1
                    t = (sec + usec / 1e6) - start
                    if kind == 1:
                        if value == 2:
                            continue
                        name = KEY_NAMES.get(code, f"KEY_0x{code:x}")
                        prev = last_key.get((fd, code), -1)
                        if value != prev:
                            last_key[(fd, code)] = value
                            state = "PRESS  " if value == 1 else "RELEASE"
                            print(f"  {t:6.2f}s  {os.path.basename(names[fd])}  {state}  "
                                  f"code={code:4d}  {name}", flush=True)
                    elif kind == 3:
                        name = ABS_NAMES.get(code, f"ABS_0x{code:x}")
                        prev = last_axis.get((fd, code))
                        if prev is None or abs(value - prev) > 4096:
                            last_axis[(fd, code)] = value
                            print(f"  {t:6.2f}s  {os.path.basename(names[fd])}  AXIS     "
                                  f"code={code:4d}  {name} = {value}", flush=True)
        print(f"  insgesamt gesehene Events: {events_seen}", flush=True)
    except TimeoutError:
        print("  Timeout erreicht.", flush=True)
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, old_handler)
        for _, fd in devices:
            try:
                os.close(fd)
            except OSError:
                pass
        print("=========================================================", flush=True)
        print("== Ende Input-Capture", flush=True)
        print("=========================================================", flush=True)


def main():
    window = 40
    if len(sys.argv) > 1:
        try:
            window = int(sys.argv[1])
        except ValueError:
            pass

    print("", flush=True)
    print("#########################################################", flush=True)
    print("# HALO INPUT-DIAGNOSE", flush=True)
    print(f"# {time.strftime('%Y-%m-%d %H:%M:%S')}", flush=True)
    print("#########################################################", flush=True)

    dump_proc_devices()
    dump_dev_input()
    capture(window)


if __name__ == "__main__":
    main()
