/*
CUSTOM_EDITION_STUB.C — port: Halo Custom Edition Maps sind in diesem
Build nicht aktiviert. menu_functions.c und menu_tags.c fragen nach CE-Maps;
ohne CE-Support ist die Antwort immer leer. Später kann diese Datei durch
die echten custom_edition_maps.c / custom_edition_cache.c aus OpenCE ersetzt
werden.
*/
#include "cseries.h"
#include "custom_edition_maps.h"

boolean custom_edition_level_name(char const *name) { (void)name; return FALSE; }
short custom_edition_maps_count(boolean campaign) { (void)campaign; return 0; }
short custom_edition_maps_display_index(char const *name) { (void)name; return NONE; }
short custom_edition_maps_display_index_of(boolean campaign, short map) { (void)campaign; (void)map; return NONE; }
boolean custom_edition_maps_level_campaign(char const *name) { (void)name; return FALSE; }
char const *custom_edition_maps_level_name(short display_index) { (void)display_index; return NULL; }
void custom_edition_maps_look_again(void) {}
char const *custom_edition_maps_name(short display_index) { (void)display_index; return NULL; }
struct bitmap_data *custom_edition_maps_picture(long bitmap_index, short *frame_index)
{
	(void)bitmap_index;
	if (frame_index) *frame_index = 0;
	return NULL;
}
short custom_edition_maps_campaign_level(short display_index) { (void)display_index; return NONE; }
char **custom_edition_maps_level_list(char **xbox_levels, short xbox_level_count, short *level_count)
{
	if (level_count) *level_count = xbox_level_count;
	return xbox_levels;
}
