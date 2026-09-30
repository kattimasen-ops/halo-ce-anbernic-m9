#!/usr/bin/env python3
"""Prints SDL_GAMECONTROLLERCONFIG lines for the handheld's own controls,
from EmulationStation's controller configuration (port/knulli/README.md).

SDL2's built-in database takes the H700 handhelds' controls (all of them
report the same generic GUID) for an ODROID-GO 2 pad, with the wrong
buttons. EmulationStation knows each device's controls by name; this turns
the entry of every connected device into an SDL mapping, as Batocera's
emulator launcher does: EmulationStation's buttons are named by the
Nintendo layout (a on the right, b at the bottom), SDL's by the Xbox layout
(a at the bottom).
"""

import re
import xml.etree.ElementTree as ElementTree

CONFIGS = [
    "/userdata/system/configs/emulationstation/es_input.cfg",
    "/usr/share/emulationstation/es_input.cfg",
]
# EmulationStation's name -> SDL's
NAMES = {
    "b": "a", "a": "b", "y": "x", "x": "y",
    "select": "back", "start": "start", "hotkey": "guide",
    "pageup": "leftshoulder", "pagedown": "rightshoulder",
    "l2": "lefttrigger", "r2": "righttrigger", "l3": "leftstick", "r3": "rightstick",
    "up": "dpup", "down": "dpdown", "left": "dpleft", "right": "dpright",
    "joystick1left": "leftx", "joystick1up": "lefty", "joystick2left": "rightx", "joystick2up": "righty",
}


def connected_names():
    names = set()
    try:
        with open("/proc/bus/input/devices", encoding="utf-8", errors="replace") as devices:
            for line in devices:
                found = re.match(r'N: Name="(.*)"', line)
                if found:
                    names.add(found.group(1))
    except OSError:
        pass
    return names


def element(entry):
    kind, identifier, value = entry.get("type"), entry.get("id"), entry.get("value")
    if kind == "button":
        return f"b{identifier}"
    if kind == "hat":
        return f"h{identifier}.{value}"
    if kind == "axis":
        return f"a{identifier}"
    return None


def main():
    names = connected_names()
    done = set()
    for path in CONFIGS:
        try:
            root = ElementTree.parse(path).getroot()
        except (OSError, ElementTree.ParseError):
            continue
        for config in root.iter("inputConfig"):
            name, guid = config.get("deviceName"), config.get("deviceGUID")
            if config.get("type") != "joystick" or name not in names or not guid or guid in done:
                continue
            parts = [guid, name]
            for entry in config.iter("input"):
                sdl_name = NAMES.get(entry.get("name"))
                value = element(entry)
                if sdl_name and value:
                    parts.append(f"{sdl_name}:{value}")
            parts.append("platform:Linux")
            print(",".join(parts) + ",")
            done.add(guid)


if __name__ == "__main__":
    main()
