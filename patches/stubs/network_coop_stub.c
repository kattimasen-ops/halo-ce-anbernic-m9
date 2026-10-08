/*
NETWORK_COOP_STUB.C

port: Halo CE Universal — Coop ist in diesem Build deaktiviert.
Die Funktion tut nichts und sagt immer FALSE. Der Menue-Code (aus OpenCE)
kompiliert damit sauber, bietet aber kein Coop an.
*/

#include "cseries/cseries.h"
#include "network_coop.h"

boolean network_coop_active(void)
{
	return FALSE;
}
