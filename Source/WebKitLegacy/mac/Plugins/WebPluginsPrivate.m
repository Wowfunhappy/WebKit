// MAVERICKS_BACKPORT: This translation unit exists only in the 10.9 backport. PlatformMac.cmake
// lists mac/Plugins/WebPluginsPrivate.m as a WebKitLegacy source; this file provides that compiled
// unit. It carries no plugin code (#include "config.h" only), so the build's source list resolves
// without pulling in additional plugin sources on 10.9.
#include "config.h"
