#ifndef WK_FONT_CATALOG_H
#define WK_FONT_CATALOG_H

#include <stdbool.h>

// Whether a stock macOS Tahoe installation makes this family available (ASCII case-insensitive).
bool wk_font_family_ships_with_tahoe(const char *family);

// The installed family that stands in for a Tahoe family this system does not ship, or NULL.
const char *wk_font_family_stand_in(const char *family);

#endif
