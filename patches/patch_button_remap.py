#!/usr/bin/env python3
"""
Button-Remap für Halo CE Universal (M9 Pro / RK3326).

Ändert port/linux/src/xinput_sdl.c so, dass die physischen SDL-Gamepad-
Buttons auf das vom Gast erwartete Xbox-Layout umgesetzt werden, mit den
vom Nutzer gewünschten Vertauschungen:

  A <-> B (Springen auf B, Nahkampf auf A)
  X <-> Y (Nachladen auf Y, Waffenwechsel auf X)
  LB (WHITE, Taschenlampe) <-> LT (LEFT_TRIGGER, Granate)
  RB (BLACK, Granatenwechsel) <-> RT (RIGHT_TRIGGER, Feuern)

Die Änderung wirkt nur mit HALO_BUTTON_REMAP=1 in der Umgebung; ohne
diese Variable bleibt das ursprüngliche Layout. Idempotent.
"""
import os
import sys


def patch_xinput_sdl(src_root):
    path = os.path.join(src_root, "port", "linux", "src", "xinput_sdl.c")
    if not os.path.exists(path):
        print(f"WARNUNG: {path} nicht gefunden – überspringe xinput_sdl.c-Patch")
        return False
    with open(path) as f:
        text = f.read()

    if "button_remap" in text:
        print("xinput_sdl.c: button_remap bereits vorhanden – überspringe.")
        return True

    old_fn = '''static void sdl_gamepad_state(SDL_Gamepad *gamepad, XINPUT_GAMEPAD *pad)
{
	static const struct
	{
		SDL_GamepadButton button;
		WORD mask;
	} digital[] ='''

    new_fn = '''/* HALO_BUTTON_REMAP=1: die physischen A und B vertauscht, X und Y
vertauscht, die Bumper (LB/RB) stehen fuer die Trigger (LT/RT) und die
Trigger fuer die Bumper. Angewendet am Ende von sdl_gamepad_state, damit
der Gast das Layout sieht, das der Spieler will. */
static void button_remap(XINPUT_GAMEPAD *pad)
{
	static int remap = -1;
	BYTE temp;

	if (remap < 0)
	{
		const char *setting = getenv("HALO_BUTTON_REMAP");
		remap = setting && *setting && *setting != '0';
	}
	if (!remap)
		return;

	/* A <-> B (Springen auf B, Nahkampf auf A) */
	temp = pad->bAnalogButtons[XINPUT_GAMEPAD_A];
	pad->bAnalogButtons[XINPUT_GAMEPAD_A] = pad->bAnalogButtons[XINPUT_GAMEPAD_B];
	pad->bAnalogButtons[XINPUT_GAMEPAD_B] = temp;

	/* X <-> Y (Nachladen auf Y, Waffenwechsel auf X) */
	temp = pad->bAnalogButtons[XINPUT_GAMEPAD_X];
	pad->bAnalogButtons[XINPUT_GAMEPAD_X] = pad->bAnalogButtons[XINPUT_GAMEPAD_Y];
	pad->bAnalogButtons[XINPUT_GAMEPAD_Y] = temp;

	/* LB (WHITE, Taschenlampe) <-> LT (LEFT_TRIGGER, Granate) */
	temp = pad->bAnalogButtons[XINPUT_GAMEPAD_WHITE];
	pad->bAnalogButtons[XINPUT_GAMEPAD_WHITE] = pad->bAnalogButtons[XINPUT_GAMEPAD_LEFT_TRIGGER];
	pad->bAnalogButtons[XINPUT_GAMEPAD_LEFT_TRIGGER] = temp;

	/* RB (BLACK, Granatenwechsel) <-> RT (RIGHT_TRIGGER, Feuern) */
	temp = pad->bAnalogButtons[XINPUT_GAMEPAD_BLACK];
	pad->bAnalogButtons[XINPUT_GAMEPAD_BLACK] = pad->bAnalogButtons[XINPUT_GAMEPAD_RIGHT_TRIGGER];
	pad->bAnalogButtons[XINPUT_GAMEPAD_RIGHT_TRIGGER] = temp;
}

static void sdl_gamepad_state(SDL_Gamepad *gamepad, XINPUT_GAMEPAD *pad)
{
	static const struct
	{
		SDL_GamepadButton button;
		WORD mask;
	} digital[] ='''

    if old_fn not in text:
        print("WARNUNG: sdl_gamepad_state-Marker in xinput_sdl.c nicht gefunden.")
        return False
    text = text.replace(old_fn, new_fn, 1)

    old_tail = '''	value = stick(SDL_GetGamepadAxis(gamepad, SDL_GAMEPAD_AXIS_RIGHTX), FALSE);
	if (abs(value) > abs(pad->sThumbRX)) pad->sThumbRX = value;
	value = stick(SDL_GetGamepadAxis(gamepad, SDL_GAMEPAD_AXIS_RIGHTY), TRUE);
	if (abs(value) > abs(pad->sThumbRY)) pad->sThumbRY = value;
}'''
    new_tail = '''	value = stick(SDL_GetGamepadAxis(gamepad, SDL_GAMEPAD_AXIS_RIGHTX), FALSE);
	if (abs(value) > abs(pad->sThumbRX)) pad->sThumbRX = value;
	value = stick(SDL_GetGamepadAxis(gamepad, SDL_GAMEPAD_AXIS_RIGHTY), TRUE);
	if (abs(value) > abs(pad->sThumbRY)) pad->sThumbRY = value;

	/* (das Tastenlayout des Spielers, HALO_BUTTON_REMAP) */
	button_remap(pad);
}'''
    if old_tail not in text:
        print("WARNUNG: Ende von sdl_gamepad_state in xinput_sdl.c nicht gefunden.")
        return False
    text = text.replace(old_tail, new_tail, 1)

    with open(path, "w") as f:
        f.write(text)
    print("xinput_sdl.c: button_remap eingebaut.")
    return True


def apply_patch(src_root):
    print("== Patch 7: Button-Remap (M9 Pro) ==")
    if not patch_xinput_sdl(src_root):
        print("FEHLER: xinput_sdl.c konnte nicht gepatcht werden.")
        sys.exit(1)


if __name__ == "__main__":
    apply_patch(sys.argv[1])
