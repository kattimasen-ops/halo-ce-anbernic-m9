/*
NETWORK_COOP.H

port: Halo CE Universal — Coop ist in diesem Build deaktiviert.
menu_functions.c, ui_widget.c und andere Stellen rufen network_coop_active()
auf, um zu entscheiden, ob ein Netzwerkspiel kooperativ ist. Ohne Coop ist
die Antwort immer FALSE.

Spaeter (falls Coop nachgeruestet wird): durch die echte network_coop.c/h
aus OpenCE ersetzen (port/linux/game/network_coop.c, ~106 KB).
*/

#ifndef __NETWORK_COOP_H
#define __NETWORK_COOP_H

#include "cseries/cseries.h"

/* port: TRUE, wenn das laufende Netzwerkspiel kooperativ ist */
boolean network_coop_active(void);

#endif /* __NETWORK_COOP_H */
