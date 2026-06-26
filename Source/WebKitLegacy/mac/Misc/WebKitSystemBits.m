// MAVERICKS_BACKPORT: PlatformMac.cmake lists mac/Misc/WebKitSystemBits.m in WebKitLegacy_SOURCES,
// but the original source was lost and its functions are not needed by this build. This empty
// translation unit (just config.h) exists so the build's source-list entry resolves to a real file.
#include "config.h"
